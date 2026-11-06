"""MCP sidecar（spec §7.2 / §8.4：MCP 客户端在 sidecar，Godot 不碰 MCP）。

包结构：
  cost.py      成本口径（与 Godot 侧 CostModelCore 同价：写 20 读 1 exec 20）
  bridge.py    Godot 桥 TCP 客户端（行分隔 JSON，见 PROTOCOL.md）
  fs_tools.py  fs.read / fs.write / fs.list（作用域 = sidecar/workspace）
  run_tools.py run.python / run.tests（子进程 + 超时杀）
  server.py    stdio MCP server（官方 mcp 包），暴露 fs.* / run.* / world.* 共 17 个工具
"""

__version__ = "0.1.0"
