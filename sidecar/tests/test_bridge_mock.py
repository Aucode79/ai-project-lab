"""桥客户端对 mock 桥：world.* 转发、record_external 回写、错误传递。"""

from __future__ import annotations

import pytest

from mcp_sidecar.bridge import BridgeError, GodotBridgeClient
from tests.conftest import MockBridge


def test_world_tool_roundtrip(mock_bridge: MockBridge) -> None:
    mock_bridge.responders["world.place"] = {
        "ok": True, "result": {"entityId": "conc_batch_belt#1"},
        "step": 0, "ops": 20, "usage": {"ops": 20, "mode": "write", "priced_by": "godot"},
    }
    client = GodotBridgeClient(port=mock_bridge.port)
    resp = client.call_world_tool("world.place", {"assetId": "conc_batch_belt", "pos": [1, 0, 0]})
    assert resp["ok"] and resp["result"]["entityId"] == "conc_batch_belt#1"
    assert resp["usage"]["priced_by"] == "godot"
    # 桥收到的请求原样带 tool 与完整 args
    req = mock_bridge.find("world.place")
    assert req is not None and req["args"] == {"assetId": "conc_batch_belt", "pos": [1, 0, 0]}
    assert isinstance(req["id"], int)
    client.close()


def test_record_external(mock_bridge: MockBridge) -> None:
    mock_bridge.responders["record_external"] = {
        "ok": True, "result": {"recorded": True, "step": 3},
    }
    client = GodotBridgeClient(port=mock_bridge.port)
    resp = client.record_external(
        "fs.read", {"path": "a.txt"}, ok=True, result={"bytes": 5}, ops=1, cost_ms=0.3)
    assert resp["ok"] and resp["result"]["step"] == 3
    req = mock_bridge.find("record_external")
    assert req["args"] == {
        "tool": "fs.read", "args": {"path": "a.txt"}, "ok": True,
        "result": {"bytes": 5}, "ops": 1, "costMs": 0.3,
    }
    client.close()


def test_tool_error_passthrough(mock_bridge: MockBridge) -> None:
    mock_bridge.responders["world.place"] = {
        "ok": False, "error": {"code": "unknown_asset", "message": "资产不存在"},
    }
    client = GodotBridgeClient(port=mock_bridge.port)
    resp = client.call_world_tool("world.place", {"assetId": "ghost", "pos": [0, 0, 0]})
    assert not resp["ok"]
    assert resp["error"]["code"] == "unknown_asset"
    client.close()


def test_unreachable_bridge_is_structured() -> None:
    client = GodotBridgeClient(port=1)  # 1 号口没有桥
    with pytest.raises(BridgeError) as ei:
        client.call_world_tool("world.snapshot", {})
    assert ei.value.code == "bridge_unreachable"


def test_connection_reuse_and_reconnect(mock_bridge: MockBridge) -> None:
    calls = {"n": 0}

    def handler(req: dict) -> dict:
        calls["n"] += 1
        return {"ok": True, "result": {"n": calls["n"]}, "step": calls["n"], "ops": 1,
                "usage": {"ops": 1, "mode": "read", "priced_by": "godot"}}

    mock_bridge.responders["world.snapshot"] = handler
    client = GodotBridgeClient(port=mock_bridge.port)
    assert client.request("world.snapshot")["result"]["n"] == 1
    # 服务端断开连接后，下一次调用自动重连
    for c in list(mock_bridge._conns):
        try:
            c.close()
        except OSError:
            pass
    assert client.request("world.snapshot")["result"]["n"] == 2
    client.close()
