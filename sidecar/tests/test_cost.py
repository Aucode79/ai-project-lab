"""成本口径：与 Godot 侧 CostModelCore 同价（写 20 读 1 exec 20，失败 0）。"""

from __future__ import annotations

from mcp_sidecar import cost


def test_prices() -> None:
    assert cost.price_of(cost.MODE_WRITE) == 20
    assert cost.price_of(cost.MODE_READ) == 1
    assert cost.price_of(cost.MODE_EXEC) == 20
    assert cost.price_of("nonsense") == 0


def test_mode_mapping() -> None:
    assert cost.mode_of_tool("fs.write") == cost.MODE_WRITE
    assert cost.mode_of_tool("fs.read") == cost.MODE_READ
    assert cost.mode_of_tool("fs.list") == cost.MODE_READ
    assert cost.mode_of_tool("run.python") == cost.MODE_EXEC
    assert cost.mode_of_tool("run.tests") == cost.MODE_EXEC
    # world.* 的档位镜像 Godot 侧（place 写 / run 演 / inspect 读）
    assert cost.mode_of_tool("world.place") == cost.MODE_WRITE
    assert cost.mode_of_tool("world.run") == cost.MODE_EXEC
    assert cost.mode_of_tool("world.inspect") == cost.MODE_READ


def test_failed_calls_free() -> None:
    assert cost.ops_for("fs.write", ok=False) == 0
    assert cost.ops_for("run.python", ok=True) == 20
    assert cost.ops_for("fs.read", ok=True) == 1
