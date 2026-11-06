"""MCP 握手端到端：起 server 子进程，用官方 mcp 客户端库走
initialize / tools/list / tools/call，覆盖 fs.*（本地）与 world.*（经 mock 桥转发）。
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

from tests.conftest import SIDECAR_ROOT, MockBridge

pytest.importorskip("mcp")

from mcp import ClientSession, StdioServerParameters  # noqa: E402
from mcp.client.stdio import stdio_client  # noqa: E402


def _tool_result_data(result) -> dict:
    """MCP CallToolResult -> dict（优先 structuredContent，回退解析文本块）。"""
    if getattr(result, "structuredContent", None):
        return dict(result.structuredContent)
    for block in result.content:
        if getattr(block, "type", "") == "text":
            return json.loads(block.text)
    raise AssertionError(f"工具结果里没有可解析内容：{result!r}")


def _server_params(mock_bridge: MockBridge, workspace: Path) -> StdioServerParameters:
    env = dict(os.environ)
    env["GODOT_BRIDGE_PORT"] = str(mock_bridge.port)
    env["GODOT_BRIDGE_HOST"] = "127.0.0.1"
    env["SIDECAR_WORKSPACE"] = str(workspace)
    return StdioServerParameters(
        command=sys.executable,
        args=["-m", "mcp_sidecar.server"],
        cwd=str(SIDECAR_ROOT),
        env=env,
    )


def test_mcp_handshake_and_calls(mock_bridge, workspace) -> None:
    mock_bridge.responders["world.read"] = {
        "ok": True, "result": {"ref": "belt#1", "value": 4.0},
        "step": 7, "ops": 1, "usage": {"ops": 1, "mode": "read", "priced_by": "godot"},
    }
    mock_bridge.responders["record_external"] = {
        "ok": True, "result": {"recorded": True, "step": 8},
    }

    async def scenario() -> None:
        async with stdio_client(_server_params(mock_bridge, workspace)) as (read, write):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                server_info = getattr(init, "server_info", None) or init.serverInfo
                assert server_info.name == "ai-lab-sidecar"

                listed = await session.list_tools()
                names = {t.name for t in listed.tools}
                # 17 个工具：3 fs + 2 run + 12 world；studio.* 一个都不许有
                assert len(names) == 17, sorted(names)
                assert {"fs.read", "fs.write", "fs.list", "run.python", "run.tests"} <= names
                assert sum(1 for n in names if n.startswith("world.")) == 12
                assert not any(n.startswith("studio.") for n in names)

                # fs.write：本地执行 + sidecar 计价 + record_external 回写
                res = await session.call_tool(
                    "fs.write", {"path": "hello.txt", "content": "hello sidecar"})
                data = _tool_result_data(res)
                assert data["ok"], data
                assert data["usage"] == {"ops": 20, "mode": "write", "priced_by": "sidecar"}
                assert data["touched_paths"] == ["hello.txt"]
                assert data["recorded"] is True
                assert (workspace / "hello.txt").read_text(encoding="utf-8") == "hello sidecar"

                # fs.read：读价 1，读不留物
                res = await session.call_tool("fs.read", {"path": "hello.txt"})
                data = _tool_result_data(res)
                assert data["ok"] and data["content"] == "hello sidecar"
                assert data["usage"]["ops"] == 1 and data["touched_paths"] == []

                # world.read：经桥转发，Godot 计价随响应带回
                res = await session.call_tool("world.read", {"ref": "belt#1"})
                data = _tool_result_data(res)
                assert data["ok"] and data["result"]["value"] == 4.0
                assert data["usage"]["priced_by"] == "godot" and data["step"] == 7

                # run.python：结构化 stdout/exit_code
                res = await session.call_tool(
                    "run.python", {"code": "print('from sidecar')"})
                data = _tool_result_data(res)
                assert data["ok"] and data["exit_code"] == 0
                assert "from sidecar" in data["stdout"]
                assert data["usage"]["ops"] == 20

    import asyncio
    asyncio.run(scenario())

    # 桥收到了它该收到的：fs.write / fs.read / run.python 的回写 + world.read 转发
    assert mock_bridge.find("world.read") is not None
    req = mock_bridge.find("record_external")
    assert req is not None and req["args"]["tool"] == "fs.write"
    assert req["args"]["ok"] is True and req["args"]["ops"] == 20
    tools = mock_bridge.tools_called()
    # 三个本地工具各回写一条：fs.write / fs.read / run.python
    assert tools.count("record_external") == 3


def test_world_tool_bridge_down_is_structured(mock_bridge, workspace) -> None:
    """桥不可达时 world.* 返回结构化错误，而不是把 MCP 会话砸了。"""

    async def scenario() -> None:
        params = StdioServerParameters(
            command=sys.executable,
            args=["-m", "mcp_sidecar.server"],
            cwd=str(SIDECAR_ROOT),
            env={**os.environ, "GODOT_BRIDGE_PORT": "1",
                 "SIDECAR_WORKSPACE": str(workspace)},
        )
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                res = await session.call_tool("world.snapshot", {})
                data = _tool_result_data(res)
                assert not data["ok"]
                assert data["error"]["code"] == "bridge_unreachable"

    import asyncio
    asyncio.run(scenario())
