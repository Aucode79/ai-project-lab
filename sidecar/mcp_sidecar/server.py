"""stdio MCP server：内置 agent（mini codex）与世界共用的工具面（spec §7.2 / docs/10-契约/mini-codex.md §三）。

暴露 17 个工具：
  文件   fs.read / fs.write / fs.list      —— sidecar 本地执行，作用域 = workspace
  执行   run.python / run.tests            —— sidecar 本地子进程，超时杀
  世界   world.* 12 个                     —— 经 TCP 桥转发给 Godot（世界计价）
studio.* 制作工具**不暴露**（spec §7.2：不暴露给学员与 agent）。

每次 tools/call 都带 usage：{ops, mode, priced_by}——
world.* 由 Godot 侧计价随响应带回；fs.*/run.* 由本侧计价（同口径 20/1/20）。
fs.*/run.* 执行后经桥的 record_external 端点回写进步记录（世界是步记录的唯一权威）。

启动：.venv/bin/python -m mcp_sidecar.server   （stdio 传输）
配置：GODOT_BRIDGE_HOST / GODOT_BRIDGE_PORT / SIDECAR_WORKSPACE
"""

from __future__ import annotations

import sys
import time
from typing import Any

try:  # mcp >= 2：FastMCP 更名 MCPServer
    from mcp.server.mcpserver import MCPServer as _McpServer
except ImportError:  # mcp 1.x
    from mcp.server.fastmcp import FastMCP as _McpServer

from . import cost
from .bridge import BridgeError, GodotBridgeClient
from .fs_tools import FsError, ScopedFs
from .run_tools import Runner

mcp = _McpServer("ai-lab-sidecar")

_bridge: GodotBridgeClient | None = None
_fs: ScopedFs | None = None
_runner: Runner | None = None


def bridge() -> GodotBridgeClient:
    global _bridge
    if _bridge is None:
        _bridge = GodotBridgeClient()
    return _bridge


def fs() -> ScopedFs:
    global _fs
    if _fs is None:
        _fs = ScopedFs()
    return _fs


def runner() -> Runner:
    global _runner
    if _runner is None:
        _runner = Runner(fs())
    return _runner


def _err(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "error": {"code": code, "message": message}}


def _usage(tool: str, ok: bool, priced_by: str = "sidecar") -> dict[str, Any]:
    return {
        "ops": cost.ops_for(tool, ok),
        "mode": cost.mode_of_tool(tool),
        "priced_by": priced_by,
    }


# ---------- world.*：经桥转发，Godot 计价 ----------

def _world_call(tool: str, args: dict[str, Any]) -> dict[str, Any]:
    """转发 + 响应整形：桥返回什么就带什么（含 step/ops/usage）。"""
    try:
        resp = bridge().call_world_tool(tool, args)
    except BridgeError as exc:
        return _err(exc.code, exc.message)
    out: dict[str, Any] = {
        "ok": bool(resp.get("ok", False)),
        "result": resp.get("result"),
        "step": resp.get("step"),
        "usage": resp.get("usage") or _usage(tool, bool(resp.get("ok", False)), "godot"),
    }
    if not out["ok"]:
        out["error"] = resp.get("error") or {"code": "tool_failed", "message": ""}
    return out


# ---------- fs.* / run.*：本地执行 + record_external 回写 ----------

def _record_external(tool: str, args: dict[str, Any], ok: bool,
                     summary: dict[str, Any], ops: int, cost_ms: float) -> bool:
    """尽力回写：桥不在（世界没开）时不吞掉本地结果，只标记 recorded=false。"""
    try:
        resp = bridge().record_external(tool, args, ok, summary, ops, cost_ms)
        return bool(resp.get("ok", False))
    except BridgeError:
        return False


def _local_call(tool: str, args: dict[str, Any], fn) -> dict[str, Any]:
    """fs.*/run.* 的公共骨架：执行 -> 计价 -> 回写 -> 整形。"""
    t0 = time.perf_counter()
    try:
        result = fn()
        ok = True
    except FsError as exc:
        result = _err(exc.code, exc.message)
        ok = False
    result["usage"] = _usage(tool, ok)
    result["recorded"] = _record_external(
        tool, args, ok, _summary(tool, result), result["usage"]["ops"],
        (time.perf_counter() - t0) * 1000.0,
    )
    return result


def _summary(tool: str, result: dict[str, Any]) -> dict[str, Any]:
    """回写进步记录的 result 摘要（不搬全文，文件内容不属于步记录）。"""
    if not result.get("ok", False):
        return {"error": result.get("error", {})}
    if tool == "fs.read":
        return {"bytes": result.get("bytes", 0)}
    if tool == "fs.write":
        return {"bytes_written": result.get("bytes_written", 0),
                "touched_paths": result.get("touched_paths", [])}
    if tool == "fs.list":
        return {"count": len(result.get("entries", []))}
    if tool in ("run.python", "run.tests"):
        return {"exit_code": result.get("exit_code"),
                "timed_out": result.get("timed_out", False),
                "duration_ms": result.get("duration_ms", 0)}
    return {}


# ---------- 工具注册（名字与 spec §7.2 工具面一一对应） ----------

@mcp.tool(name="fs.read", description="读作用域（workspace）内一个文本文件。读不留物：touched_paths 恒为空。ops 1。")
def fs_read(path: str) -> dict[str, Any]:
    return _local_call("fs.read", {"path": path}, lambda: fs().read(path))


@mcp.tool(name="fs.write", description="写作用域（workspace）内一个文本文件（覆盖）。写留物：touched_paths 带落笔路径。ops 20。")
def fs_write(path: str, content: str) -> dict[str, Any]:
    # 回写进步记录的 args 走完整参数（spec §6：action 含工具名与完整参数）
    return _local_call("fs.write", {"path": path, "content": content},
                       lambda: fs().write(path, content))


@mcp.tool(name="fs.list", description="列作用域（workspace）内一个目录（或单文件）。ops 1。")
def fs_list(path: str = ".") -> dict[str, Any]:
    return _local_call("fs.list", {"path": path}, lambda: fs().list(path))


@mcp.tool(name="run.python", description="在 workspace 里跑一段 Python（子进程，默认 10s 超时杀）。返回 stdout/stderr/exit_code。ops 20。")
def run_python(code: str, timeout: float | None = None) -> dict[str, Any]:
    return _local_call("run.python", {"code": code, "timeout": timeout},
                       lambda: runner().run_python(code, timeout))


@mcp.tool(name="run.tests", description="在 workspace 里跑 pytest（默认 10s 超时杀），退出码按 pytest 语义解析。ops 20。")
def run_tests(path: str = ".", timeout: float | None = None) -> dict[str, Any]:
    return _local_call("run.tests", {"path": path, "timeout": timeout},
                       lambda: runner().run_tests(path, timeout))


@mcp.tool(name="world.place", description="放置一个资产实例（经 Godot 桥，进步记录 actor=codex）。ops 20。")
def world_place(assetId: str, pos: list[float]) -> dict[str, Any]:
    return _world_call("world.place", {"assetId": assetId, "pos": pos})


@mcp.tool(name="world.connect", description="连线两个端口实例 portRef={entityId}:{portId}（经桥）。ops 20。")
def world_connect(from_ref: str, to_ref: str) -> dict[str, Any]:
    return _world_call("world.connect", {"from": from_ref, "to": to_ref})


@mcp.tool(name="world.set_param", description="改一个实体的参数（经桥）。ops 20。")
def world_set_param(entityId: str, key: str, value: Any) -> dict[str, Any]:
    return _world_call("world.set_param", {"entityId": entityId, "key": key, "value": value})


@mcp.tool(name="world.run", description="推进世界演化 duration 秒（经桥）。ops 20。")
def world_run(duration: float = 1.0) -> dict[str, Any]:
    return _world_call("world.run", {"duration": duration})


@mcp.tool(name="world.step", description="世界走一步（经桥）。ops 20。")
def world_step() -> dict[str, Any]:
    return _world_call("world.step", {})


@mcp.tool(name="world.inspect", description="查一个实体的状态摘要（经桥）。ops 1。")
def world_inspect(entityId: str) -> dict[str, Any]:
    return _world_call("world.inspect", {"entityId": entityId})


@mcp.tool(name="world.snapshot", description="取世界逻辑快照（只取状态层，经桥）。ops 1。")
def world_snapshot() -> dict[str, Any]:
    return _world_call("world.snapshot", {})


@mcp.tool(name="world.read", description="读一个实体或端口实例的值（经桥）。ops 1。")
def world_read(ref: str) -> dict[str, Any]:
    return _world_call("world.read", {"ref": ref})


@mcp.tool(name="world.trace", description="回溯一个端口实例的值历史（经桥）。ops 1。")
def world_trace(ref: str) -> dict[str, Any]:
    return _world_call("world.trace", {"ref": ref})


@mcp.tool(name="world.watch", description="订阅一个 ref 的变化（经桥）。ops 1。")
def world_watch(ref: str) -> dict[str, Any]:
    return _world_call("world.watch", {"ref": ref})


@mcp.tool(name="world.diff", description="对比两步之间的世界差异（经桥）。ops 1。")
def world_diff(fromStep: int | None = None, toStep: int | None = None) -> dict[str, Any]:
    args: dict[str, Any] = {}
    if fromStep is not None:
        args["fromStep"] = fromStep
    if toStep is not None:
        args["toStep"] = toStep
    return _world_call("world.diff", args)


@mcp.tool(name="world.export_netlist", description="导出世界连接图文本（经桥）。ops 1。")
def world_export_netlist() -> dict[str, Any]:
    return _world_call("world.export_netlist", {})


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    sys.exit(main())
