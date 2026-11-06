extends McpBridgeCore

## McpBridge autoload 薄壳。实现全在 core/mcp_bridge_core.gd。
## _ready 里开始监听 127.0.0.1:7310（被占则退备用口），_process 每帧 pump；
## 依赖（WorldTools 及其状态/记录/成本）懒解析：注入优先，autoload 次之。
