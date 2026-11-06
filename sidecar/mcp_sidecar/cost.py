"""成本口径：与 Godot 侧 CostModelCore 同价（spec §7.2，改造自《编程农场》200:1，demo 取 20:1）。

分工：
  * world.* —— 由 Godot 侧计价，ops 随桥响应带回（sidecar 不重复计价）
  * fs.* / run.* —— 由 sidecar 本地计价，随 record_external 回写进世界步记录
失败调用不计费（FAILED_OPS = 0）：它什么都没改变。
"""

from __future__ import annotations

MODE_WRITE = "write"
MODE_READ = "read"
MODE_EXEC = "exec"

WRITE_OPS = 20
READ_OPS = 1
EXEC_OPS = 20
FAILED_OPS = 0


def price_of(mode: str) -> int:
    """各档单价（学员代码可读：让"贵在哪"成为可推理的事实）。"""
    if mode == MODE_WRITE:
        return WRITE_OPS
    if mode == MODE_READ:
        return READ_OPS
    if mode == MODE_EXEC:
        return EXEC_OPS
    return FAILED_OPS


def mode_of_tool(tool: str) -> str:
    """工具名 -> 计价档。world.* 的档位定义在这里只做镜像，
    权威在 Godot 侧 CostModelCore；两边必须保持一致（测试互查）。"""
    if tool in ("fs.write", "world.place", "world.connect", "world.set_param"):
        return MODE_WRITE
    if tool in ("run.python", "run.tests", "world.run", "world.step"):
        return MODE_EXEC
    if tool.startswith("fs.") or tool.startswith("world."):
        return MODE_READ
    return ""


def ops_for(tool: str, ok: bool) -> int:
    """一次工具调用的 ops：失败 0，成功按档计价。"""
    if not ok:
        return FAILED_OPS
    return price_of(mode_of_tool(tool))
