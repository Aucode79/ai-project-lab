"""端到端冒烟客户端：纯 stdlib 裸 JSON-RPC 走 MCP stdio（不加 mcp 依赖）。

链路：本进程 --stdio--> mcp_sidecar.server --TCP桥--> Godot McpBridge
动作：initialize / tools/list / tools/call(fs.write) / tools/call(world.inspect)

用法（WSL 或 Windows python 均可）：
  python smoke_client.py --server-python <py> --cwd <sidecar dir> \
      --workspace <dir> [--host 127.0.0.1] [--port 7310]

server-python 需装好 mcp 包（sidecar/.venv 或 .venv-win）。
退出码 0 = 冒烟通过。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any

PROTOCOL_VERSION = "2025-06-18"


class McpStdioClient:
    def __init__(self, cmd: list[str], cwd: str, env: dict[str, str]) -> None:
        self.proc = subprocess.Popen(
            cmd, cwd=cwd, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
        )
        self._id = 0

    def _send(self, obj: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self._id += 1
        req: dict[str, Any] = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            req["params"] = params
        self._send(req)
        while True:
            assert self.proc.stdout is not None
            line = self.proc.stdout.readline()
            if not line:
                err = ""
                if self.proc.stderr is not None:
                    err = self.proc.stderr.read()[:800]
                raise RuntimeError(f"server 提前退出：{err}")
            msg = json.loads(line)
            if msg.get("id") == self._id:
                if "error" in msg:
                    raise RuntimeError(f"MCP 错误响应：{msg['error']}")
                return msg.get("result", {})
            # 通知 / 日志行：忽略

    def notify(self, method: str) -> None:
        self._send({"jsonrpc": "2.0", "method": method})

    def close(self) -> None:
        try:
            self.proc.stdin.close()  # type: ignore[union-attr]
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        if self.proc.stderr is not None:
            tail = self.proc.stderr.read()[-1500:]
            if tail.strip():
                print(f"[server stderr 尾部]\n{tail}", file=sys.stderr)


def tool_data(result: dict[str, Any]) -> dict[str, Any]:
    """CallToolResult -> 我们的 {ok, ...} dict。"""
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        return structured
    for block in result.get("content", []):
        if block.get("type") == "text":
            return json.loads(block["text"])
    raise AssertionError(f"无可解析工具结果：{json.dumps(result)[:300]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server-python", required=True,
                    help="装了 mcp 包的 python（.venv/bin/python 或 .venv-win/Scripts/python.exe）")
    ap.add_argument("--cwd", required=True, help="sidecar 目录（-m mcp_sidecar.server 的运行目录）")
    ap.add_argument("--workspace", required=True, help="fs.* 作用域目录（绝对路径）")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7310)
    ap.add_argument("--timeout", type=float, default=30.0)
    args = ap.parse_args()

    env = dict(os.environ)
    env["SIDECAR_WORKSPACE"] = args.workspace
    env["GODOT_BRIDGE_HOST"] = args.host
    env["GODOT_BRIDGE_PORT"] = str(args.port)
    env["PYTHONUNBUFFERED"] = "1"

    client = McpStdioClient([args.server_python, "-m", "mcp_sidecar.server"],
                            cwd=args.cwd, env=env)
    try:
        t0 = time.time()
        init = client.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "smoke-client", "version": "0.1"},
        })
        print(f"initialize: server={init.get('serverInfo', init.get('server_info', {}))}"
              f" protocol={init.get('protocolVersion')}")
        client.notify("notifications/initialized")

        listed = client.request("tools/list", {})
        names = sorted(t["name"] for t in listed.get("tools", []))
        print(f"tools/list: {len(names)} 个工具 -> {', '.join(names)}")
        assert len(names) == 17, f"期望 17 个工具，得到 {len(names)}"
        assert not any(n.startswith("studio.") for n in names), "studio.* 不得暴露"

        # 1) fs.write：sidecar 本地执行 + record_external 回写进世界步记录
        content = f"smoke {time.strftime('%Y-%m-%d %H:%M:%S')}"
        r1 = tool_data(client.request("tools/call", {
            "name": "fs.write",
            "arguments": {"path": "smoke.txt", "content": content},
        }))
        print(f"fs.write: ok={r1.get('ok')} usage={r1.get('usage')} "
              f"touched={r1.get('touched_paths')} recorded={r1.get('recorded')}")
        assert r1.get("ok") is True, r1
        assert r1["usage"] == {"ops": 20, "mode": "write", "priced_by": "sidecar"}, r1["usage"]
        assert r1.get("recorded") is True, "record_external 没有被世界接受"
        # 文件真的落在作用域里（读它一眼再留证据给日志）
        import pathlib
        smoke_file = pathlib.Path(args.workspace) / "smoke.txt"
        assert smoke_file.read_text(encoding="utf-8") == content, "workspace 里的文件内容对不上"

        # 2) world.inspect：经桥到 Godot 再回来（空世界里是结构化 unknown_entity，
        #    但 step 与错误码只能来自 Godot —— 证明整条链路活了）
        r2 = tool_data(client.request("tools/call", {
            "name": "world.inspect",
            "arguments": {"entityId": "conc_batch_belt#1"},
        }))
        print(f"world.inspect: ok={r2.get('ok')} step={r2.get('step')} "
              f"error={r2.get('error')} usage={r2.get('usage')}")
        assert r2.get("ok") is False, "空世界里 inspect 不该成功"
        assert r2.get("error", {}).get("code") == "unknown_entity", r2
        assert isinstance(r2.get("step"), int) and r2["step"] >= 0, "Godot 应记录这条失败步"
        assert r2.get("usage", {}).get("priced_by") == "godot", r2

        # 顺带把世界读价也走一遍：snapshot 恒成功
        r3 = tool_data(client.request("tools/call", {
            "name": "world.snapshot", "arguments": {},
        }))
        print(f"world.snapshot: ok={r3.get('ok')} step={r3.get('step')} "
              f"usage={r3.get('usage')}")
        assert r3.get("ok") is True and r3["usage"]["ops"] == 1, r3

        print(f"SMOKE OK ({time.time() - t0:.1f}s)：fs.write 与 world.* 两条链路都通了")
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
