# McpBridge 桥协议（sidecar ↔ Godot）

> 定稿 2026-09-14。实现：Godot 侧 `game/scripts/core/mcp_bridge_core.gd`（autoload
> `McpBridge`），sidecar 侧 `mcp_sidecar/bridge.py`。spec §7.2 / §8.4 落位裁决：
> **MCP 客户端在 sidecar（Python 侧），Godot 不碰 MCP**。桥只承载 sidecar ↔ Godot
> 的这条内部小协议。

## 1. 传输

| 项 | 值 |
|---|---|
| 传输 | TCP，**只监听回环** `127.0.0.1:7310`（被占自动退 `7395`） |
| 帧 | **行分隔 JSON**：一条消息一行 UTF-8 JSON，以 `\n` 结尾，消息内不允许裸换行 |
| 模型 | 请求-响应，按序回答；`id` 由客户端给（int 或 string），响应原样带回 |
| 并发 | 桥在 Godot 主线程 `_process` 里 poll（非阻塞）；同一连接串行处理 |
| 生命周期 | 连接可长期复用；断开后 sidecar 重建重试一次 |

## 2. 请求

```json
{"id": 1, "tool": "world.place", "args": {"assetId": "conc_batch_belt", "pos": [2, 0, 1]}}
```

`tool` 取值只有 13 个：`world.*` 12 个工具 + `record_external` 端点。其余一律
`unknown_tool` 拒绝（**studio.\* 制作工具永不转发**，spec §7.2）。

## 3. 响应

成功：

```json
{"id": 1, "ok": true, "result": {"entityId": "conc_batch_belt#1", "bound": true},
 "step": 0, "ops": 20,
 "usage": {"ops": 20, "mode": "write", "priced_by": "godot"}}
```

失败（工具失败也带 step——失败也进步记录）：

```json
{"id": 1, "ok": false, "error": {"code": "unknown_asset", "message": "资产不存在：ghost"},
 "step": 3}
```

| 字段 | 含义 |
|---|---|
| `step` | 本次调用在步记录里的步号（`record_external` 回写成功时同样带） |
| `ops` | 本步 ops；`usage.priced_by` 标明计价方 |
| `error.code` | 结构化错误码：`unknown_tool` / `bad_args` / `unknown_asset` / `unknown_entity` / `entity_not_bound` / `bad_request` / `not_recording` … |

协议级错误（行不是 JSON、缺 `tool` 字段）回 `{"id": null, "ok": false,
"error": {"code": "bad_request", ...}}`，**不进步记录**——协议错误不是世界事件。

## 4. world.\* 的 12 个工具

与 `WorldToolsCore` 一一对应，参数原样透传：

| 工具 | args | 计价 |
|---|---|---|
| `world.place` | `{assetId, pos}` | write 20 |
| `world.connect` | `{from, to}`（portRef） | write 20 |
| `world.set_param` | `{entityId, key, value}` | write 20 |
| `world.run` | `{duration?}` | exec 20 |
| `world.step` | `{}` | exec 20 |
| `world.inspect` | `{entityId}` | read 1 |
| `world.snapshot` | `{}` | read 1 |
| `world.read` | `{ref}` | read 1 |
| `world.trace` | `{ref}` | read 1 |
| `world.watch` | `{ref}` | read 1 |
| `world.diff` | `{fromStep?, toStep?}` | read 1 |
| `world.export_netlist` | `{}` | read 1 |

桥收到请求后经 `WorldToolsCore.call_tool(tool, args, {"actor": "codex"})` 执行：
**步记录、计价、failures 全部由 Godot 侧产生**（spec §6：世界是步记录的唯一权威）。
ops 从落账的那一步读出，随响应带回，sidecar 不重复计价。

## 5. record_external 端点（fs.\* / run.\* 回写）

fs.\* / run.\* 在 sidecar 本地执行（文件世界在 `sidecar/workspace/`），不经 Godot；
但**每执行一次（无论成败）都回写一条**给桥，进步记录：

```json
{"id": 2, "tool": "record_external", "args": {
  "tool": "fs.read",            // 只收 fs.*/run.* 五个名字
  "args": {"path": "notes/a.txt"},   // 完整参数（spec §6）
  "ok": true,
  "result": {"bytes": 12},      // 结果摘要（不搬文件全文）
  "ops": 1,                     // sidecar 计价（同口径，见 §6）
  "costMs": 0.4
}}
```

桥按动作性质归类 phase（`fs.write`→`build`，`fs.read`/`fs.list`→`observe`，
`run.*`→`run`），actor 固定 `codex`，落账后回 `{"ok": true, "result":
{"recorded": true, "step": i}}`。非 fs.\*/run.\* 的工具名回 `bad_request`。

桥不可达时 sidecar 仍完成本地执行，结果带 `"recorded": false`（世界没开不算文件
操作的失败；任务要求世界开着时这条路径不会出现）。

## 6. 成本口径（两侧同价，spec §7.2）

| 档 | 单价 | 谁计价 |
|---|---|---|
| write（`fs.write`、`world.place/connect/set_param`） | 20 ops | 各自计价 |
| exec（`run.python/run.tests`、`world.run/step`） | 20 ops | 各自计价 |
| read（`fs.read/list`、其余 world.\*） | 1 op | 各自计价 |
| 失败调用 | 0 ops | — |

Godot 侧权威是 `CostModelCore`；sidecar 侧镜像在 `mcp_sidecar/cost.py`
（`tests/test_cost.py` 与 `game/tests/mcp/run_mcp_tests.gd` 双侧互相校验口径）。

## 7. run 的自动开启

桥收到第一条请求时，若步记录器不在 `recording` 状态（比如刚启动的 headless
实例），自动 `begin_run(kind=explore)`。agent 的代做运行不参与判定
（docs/10-契约/mini-codex.md §四），判定只属于学员自己的 `task` 运行。

## 8. Godot 侧实现注记

- `godot -s`（ScriptRunner）模式下 autoload 的 `_ready` 延迟到退出阶段才触发，
  此时抢端口只会打架：该模式下 autoload **不自动监听**，由游戏运行时
  （正常启动 / `--headless`）或测试自建实例负责。
- 读取用 `StreamPeerTCP.get_partial_data`；`get_data` 在该 API 上实测不可靠
  （只回 2 个零字节）。
