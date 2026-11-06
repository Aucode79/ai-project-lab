extends RefCounted

## 跨关共用的世界实体 id（学员工位上的两件固定装置）。
## 五关流程驱动器都按这两个 id 取实体，收在这里防各关写歪。
## 用法：const LevelAssets := preload("res://scripts/levels/level_assets.gd")

const ASSET_SCREEN := "player_screen"   # 播放器幕布（各关同款）
const ASSET_CODEX := "agent_codex"      # codex 小车本体
