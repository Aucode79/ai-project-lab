"""Godot 桥客户端：127.0.0.1:7310 上的行分隔 JSON 小协议（见 PROTOCOL.md）。

请求：{"id": <int>, "tool": ..., "args": {...}}\\n
响应：{"id": <同值>, "ok": true, "result": ..., "step": i, "ops": n, "usage": {...}}\\n
      {"id": <同值>, "ok": false, "error": {"code": ..., "message": ...}}\\n

线程安全：FastMCP 的同步 handler 跑在线程池里，这里用锁串行化一条连接。
"""

from __future__ import annotations

import itertools
import json
import os
import socket
import threading
from typing import Any

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 7310


class BridgeError(Exception):
    """桥协议层错误（连不上 / 响应坏了 / id 对不上）。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


class GodotBridgeClient:
    """一条懒建立的 TCP 连接；断线后下一次调用重连。"""

    def __init__(self, host: str | None = None, port: int | None = None,
                 timeout: float = 5.0) -> None:
        self.host = host or os.environ.get("GODOT_BRIDGE_HOST", DEFAULT_HOST)
        self.port = port if port is not None else _env_int("GODOT_BRIDGE_PORT", DEFAULT_PORT)
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._rfile = None
        self._lock = threading.Lock()
        self._ids = itertools.count(1)

    # ---------- 连接管理 ----------

    def _connect(self) -> tuple[socket.socket, Any]:
        if self._sock is not None:
            return self._sock, self._rfile  # type: ignore[return-value]
        try:
            sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        except OSError as exc:
            raise BridgeError(
                "bridge_unreachable",
                f"连不上 Godot 桥 {self.host}:{self.port}（先启动 Godot，"
                f"McpBridge autoload 会监听该端口）：{exc}",
            ) from exc
        sock.settimeout(self.timeout)
        self._sock = sock
        # makefile 需要 blocking socket；readline 一次一行，超时由 socket timeout 兜底
        self._rfile = sock.makefile("r", encoding="utf-8", newline="\n")
        return sock, self._rfile

    def close(self) -> None:
        with self._lock:
            self._teardown()

    def _teardown(self) -> None:
        if self._rfile is not None:
            try:
                self._rfile.close()
            except OSError:
                pass
            self._rfile = None
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    # ---------- 协议 ----------

    def request(self, tool: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
        """发一条请求，收一条响应（dict 原样返回，不抛业务错误）。"""
        with self._lock:
            req_id = next(self._ids)
            line = json.dumps({"id": req_id, "tool": tool, "args": args or {}},
                              ensure_ascii=False)
            raw = ""
            for attempt in (1, 2):
                try:
                    sock, rfile = self._connect()
                    sock.sendall((line + "\n").encode("utf-8"))
                    raw = rfile.readline()
                    break
                except BridgeError:
                    raise
                except OSError as exc:
                    # 长连接被 Godot 侧回收是正常现象：断线重建后再试一次
                    self._teardown()
                    if attempt == 2:
                        raise BridgeError("bridge_io_error", str(exc)) from exc
            if not raw:
                self._teardown()
                raise BridgeError("bridge_closed", "桥关闭了连接（Godot 退出？）")
            try:
                resp = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise BridgeError("bad_response", f"桥响应不是 JSON：{raw[:120]!r}") from exc
            if not isinstance(resp, dict) or resp.get("id") != req_id:
                raise BridgeError("id_mismatch", f"桥响应 id 对不上：{raw[:120]!r}")
            return resp

    # ---------- 便捷入口 ----------

    def call_world_tool(self, tool: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
        """转发 world.*（12 个之一）。返回桥的完整响应 dict。"""
        return self.request(tool, args)

    def record_external(self, tool: str, args: dict[str, Any], ok: bool,
                        result: Any, ops: int, cost_ms: float = 0.0) -> dict[str, Any]:
        """把 sidecar 本地执行的 fs.*/run.* 回写进世界步记录（世界是唯一权威）。"""
        return self.request("record_external", {
            "tool": tool,
            "args": args,
            "ok": ok,
            "result": result,
            "ops": int(ops),
            "costMs": round(float(cost_ms), 3),
        })
