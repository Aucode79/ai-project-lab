"""共享测试设施：mock Godot 桥（线程化 TCP 行协议）+ 独立 workspace。"""

from __future__ import annotations

import json
import socket
import sys
import threading
from pathlib import Path
from typing import Any, Callable

import pytest

SIDECAR_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SIDECAR_ROOT))


class MockBridge:
    """假 Godot 桥：收行分隔 JSON 请求，按注册的应答器回话，并记录一切请求。"""

    def __init__(self) -> None:
        self.requests: list[dict[str, Any]] = []
        self.responders: dict[str, Callable[[dict], dict] | dict] = {}
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self.port = self._srv.getsockname()[1]
        self._srv.listen(4)
        self._conns: list[socket.socket] = []
        self._stop = threading.Event()
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    # ---------- 服务循环 ----------

    def _accept_loop(self) -> None:
        self._srv.settimeout(0.2)
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except (socket.timeout, OSError):
                continue
            self._conns.append(conn)
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        conn.settimeout(30.0)
        f = conn.makefile("r", encoding="utf-8")
        try:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line)
                except json.JSONDecodeError:
                    conn.sendall(b'{"id": null, "ok": false, "error": {"code": "bad_request"}}\n')
                    continue
                self.requests.append(req)
                conn.sendall((json.dumps(self._respond(req)) + "\n").encode("utf-8"))
        except OSError:
            pass
        finally:
            try:
                f.close()
                conn.close()
            except OSError:
                pass

    def _respond(self, req: dict[str, Any]) -> dict[str, Any]:
        tool = str(req.get("tool", ""))
        handler = self.responders.get(tool)
        if callable(handler):
            resp = handler(req)
        elif isinstance(handler, dict):
            resp = dict(handler)
        else:
            resp = {"ok": False, "error": {"code": "unknown_tool", "message": tool}}
        resp["id"] = req.get("id")
        return resp

    # ---------- 查询 / 清理 ----------

    def tools_called(self) -> list[str]:
        return [str(r.get("tool", "")) for r in self.requests]

    def find(self, tool: str) -> dict[str, Any] | None:
        for r in self.requests:
            if r.get("tool") == tool:
                return r
        return None

    def close(self) -> None:
        self._stop.set()
        for c in self._conns:
            try:
                c.close()
            except OSError:
                pass
        try:
            self._srv.close()
        except OSError:
            pass


@pytest.fixture()
def mock_bridge() -> MockBridge:
    bridge = MockBridge()
    yield bridge
    bridge.close()


@pytest.fixture()
def workspace(tmp_path, monkeypatch) -> Path:
    """独立 workspace：环境变量指向临时目录，并重置 server 的惰性单例。"""
    ws = tmp_path / "workspace"
    ws.mkdir()
    monkeypatch.setenv("SIDECAR_WORKSPACE", str(ws))
    import mcp_sidecar.server as server_mod
    server_mod._fs = None
    server_mod._runner = None
    server_mod._bridge = None
    yield ws
    server_mod._fs = None
    server_mod._runner = None
    server_mod._bridge = None
