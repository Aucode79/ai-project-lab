# MCP Sidecar（Python 侧）

spec §7.2 / §8.4 落位裁决：**MCP 客户端在 sidecar，Godot 不碰 MCP**。
内置 agent（mini codex）通过这里接入世界，与学员共用同一套工具面——它的每次
操作都经桥落进世界的步记录（spec §6：步记录是过程的内核）。

```
MCP 客户端(codex/学员) --stdio MCP--> mcp_sidecar.server --TCP 7310--> Godot McpBridge
                                         |                                   |
                                         +-- fs.*/run.* 本地执行              +-- world.* 12 个
                                            (workspace/ 作用域沙箱)            (WorldTools 内核)
                                         +-- 回写 record_external -----------> 步记录(唯一权威)
```

桥协议定稿见 [PROTOCOL.md](PROTOCOL.md)。

## 快速开始（WSL）

```bash
cd sidecar
python3 -m venv .venv
./.venv/bin/python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt

# 测试
./.venv/bin/python -m pytest tests/ -q

# 端到端冒烟（自动起 headless Godot -> MCP 握手 -> fs.write + world.* 调用 -> 收结果）
bash smoke_e2e.sh
```

## 跑 MCP server（stdio）

Godot 侧先跑起来（autoload `McpBridge` 会监听 `127.0.0.1:7310`）：

```bash
"$GODOT" --headless --path game      # 或正常打开游戏
```

然后把本 server 挂到任何 MCP 客户端（codex CLI、Claude Desktop 等）：

```json
{"command": "D:/ai-project-lab/sidecar/.venv-win/Scripts/python.exe",
 "args": ["-m", "mcp_sidecar.server"], "cwd": "D:/ai-project-lab/sidecar"}
```

裸 JSON-RPC 冒烟客户端：`python smoke_client.py --server-python <装了 mcp 的 python> --cwd <sidecar 目录> --workspace <作用域目录>`。

## 工具清单（17 个，studio.\* 不暴露）

| 工具 | 干什么 | 在哪执行 | ops |
|---|---|---|---|
| `fs.read path` | 读 workspace 内文本文件（读不留物） | sidecar 本地 | 1 |
| `fs.write path content` | 写文件（写留物，`touched_paths` 带落笔） | sidecar 本地 | 20 |
| `fs.list path` | 列目录 | sidecar 本地 | 1 |
| `run.python code [timeout]` | 子进程跑 Python，默认 10s 超时杀 | sidecar 本地 | 20 |
| `run.tests path [timeout]` | 跑 pytest，退出码语义解析 | sidecar 本地 | 20 |
| `world.place assetId pos` | 放置资产实例 | 经桥 → Godot | 20 |
| `world.connect from to` | 连线两个 portRef | 经桥 → Godot | 20 |
| `world.set_param entityId key value` | 改参数 | 经桥 → Godot | 20 |
| `world.run [duration]` | 推进世界 | 经桥 → Godot | 20 |
| `world.step` | 世界走一步 | 经桥 → Godot | 20 |
| `world.inspect entityId` | 实体摘要 | 经桥 → Godot | 1 |
| `world.snapshot` | 逻辑快照（只取状态层） | 经桥 → Godot | 1 |
| `world.read ref` | 读实体/端口值 | 经桥 → Godot | 1 |
| `world.trace ref` | 端口值历史 | 经桥 → Godot | 1 |
| `world.watch ref` | 订阅变化 | 经桥 → Godot | 1 |
| `world.diff [fromStep toStep]` | 两步间差异 | 经桥 → Godot | 1 |
| `world.export_netlist` | 连接图文本 | 经桥 → Godot | 1 |

每次 `tools/call` 的返回都带 `usage: {ops, mode, priced_by}`：
world.\* 由 **Godot 侧计价**随响应带回，fs.\*/run.\* 由 **sidecar 计价**（同口径）。
失败调用 ops=0（它什么都没改变）。

## 成本口径

写 20 / 读 1 / exec 20（demo 取 20:1，改造自《编程农场》200:1，spec §7.2）。
Godot 权威在 `game/scripts/core/cost_model_core.gd`，sidecar 镜像在
`mcp_sidecar/cost.py`，两侧测试互相校验。

## 配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GODOT_BRIDGE_HOST` | `127.0.0.1` | 桥地址 |
| `GODOT_BRIDGE_PORT` | `7310` | 桥端口（被占时 Godot 退 `7395`，对齐即可） |
| `SIDECAR_WORKSPACE` | `<sidecar>/workspace` | fs.\*/run.\* 的作用域沙箱根 |

## 沙箱与安全

- 路径先 resolve 再校验：绝对路径、`..` 逃逸、符号链接逃逸一律
  `path_out_of_scope` 拒绝；文件世界永远出不了 `workspace/`
- `run.*` 子进程 cwd 固定在 workspace，默认 10s（上限 60s）超时杀掉
- 桥只监听回环；studio.\* 制作工具不在任何一侧的工具清单里

## 目录

```
sidecar/
  mcp_sidecar/          # Python 包
    bridge.py           # 桥客户端（行分隔 JSON over TCP）
    cost.py             # 成本口径（镜像 Godot CostModelCore）
    fs_tools.py         # fs.* 作用域沙箱
    run_tools.py        # run.* 执行器
    server.py           # stdio MCP server（官方 mcp 包，1.x/2.x 兼容）
  tests/                # pytest：沙箱/超时/mock 桥/MCP 握手
  smoke_e2e.sh          # 端到端冒烟（WSL 内跑）
  smoke_client.py       # 裸 JSON-RPC 冒烟客户端（stdlib only）
  PROTOCOL.md           # 桥协议定稿
  .venv/                # WSL venv（gitignored）
  .venv-win/            # Windows venv（WSL->Windows TCP 被 NAT 防火墙拦时的兜底）
```

## 已知坑位

- **WSL2 NAT 模式**下 WSL → Windows 的 127.0.0.1 入站被防火墙拦（Windows → WSL
  方向不受影响）。`smoke_e2e.sh` 会探测：直连可行走 WSL venv；不行则整套 python
  链路（客户端 + server）退到 `.venv-win` 在 Windows 侧跑，TCP 走 Windows 本机
  回环。mirrored 网络的机器两种都会选 WSL 路径。
- mcp 包 1.x/2.x 均支持（2.x 的 `FastMCP` 更名 `MCPServer`，server.py 做了双导入）。
