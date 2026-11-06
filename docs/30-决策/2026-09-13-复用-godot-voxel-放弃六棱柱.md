# 2026-09-13 · 复用 godot_voxel，放弃六棱柱

> 重大决策记录。背景 / 备选 / 选择 / 后果。

## 背景

用户要求「先到 GitHub 上翻一翻，有没有那种类似我的世界的沙盒项目」。调研结果让选择变得清楚：

**方块体素沙盒极其成熟。** [Zylann/godot_voxel](https://github.com/Zylann/godot_voxel) 3,894★，v1.7 于 2026-08-20 发布并**提供 GDExtension 包**（丢进工程即可，不用编译引擎），最近提交 2026-09-10。它的能力清单正好覆盖本项目当前缺的四样：区块网格、无限地形分页、实时编辑、LOD/AO。

**六棱柱沙盒几乎没有先例。** 穷举 `hex voxel` / `hexagonal minecraft` / `hexcraft` / `hexagonal sandbox` 后，最高星的相关项目是 20★ 的 Bevy 六边形地图编辑器；有一个 [eisbaerBorealis/hex-voxels](https://github.com/eisbaerBorealis/hex-voxels) 描述直接写着「copying Minecraft but with hexagons」，**2025-05-20 建库、05-22 停更，只剩一个 index.html**。Godot 侧的六边形库都是平面/策略向（坐标与寻路），不含体素基建。

## 备选

**A. 继续自研六棱柱。** 保住独特身份。代价：区块、网格生成、剔除、LOD、存档全部自写，且无先例可参考。
**B. 改用立方体，复用 godot_voxel。** 立刻拿到成熟基建，形状回到方块。
**C. 借坐标数学、不借体素引擎。** 折中，但区块与流式加载仍要自造。

## 选择

**B。** 用户原话：「那就不用六棱柱，就用正方形，反正我们这一块先复用开源的项目」。

判断依据是优先级：用户明确把「开放游戏」放在第一位、「线条明晰」第二、「画质光影」第三。而区块与流式加载是「开放游戏」的地基——自己造它是几个月，`godot_voxel` 是一天。

## 后果

**已验证（关键事实）**

`GodotVoxelExtension.zip`（v1.7x，51MB）解压到 `game/addons/zylann.voxel/` 后，在 **Godot 4.7.2 上加载成功**。`voxel.gdextension` 声明 `compatibility_minimum = "4.4.1"`，实测通过。

探针枚举出扩展注册的核心类，方块沙盒需要的全部在内：

| 能力 | 类 |
|---|---|
| 地形节点 | `VoxelTerrain` / `VoxelLodTerrain` |
| 观察者（决定加载哪块） | `VoxelViewer` |
| 方块风格网格化 | `VoxelMesherBlocky` / `VoxelBlockyLibrary` / `VoxelBlockyModel` |
| 运行时编辑（挖/填） | `VoxelTool` / `VoxelToolTerrain` / `VoxelToolLodTerrain` |
| 射线拾取（选中格子） | `VoxelRaycastResult` |
| 存档 | `VoxelStreamSQLite` / `VoxelStreamRegionFiles` / `VoxelStreamMemory` |
| 修改器 | `VoxelModifierSphere` / `VoxelModifierMesh` |
| 多人同步 | `VoxelTerrainMultiplayerSynchronizer` |
| 噪声 | `ZN_FastNoiseLite` / `ZN_FastNoiseLiteGradient` |

**踩到一个坑，必须记下来**

装完扩展**不能立刻用 `--script` 直跑**——Godot 只在编辑器扫描时才把 `.gdextension` 登记进 `.godot/extension_list.cfg`，而 `--script` 模式不会触发扫描。第一次探针 12 个类全部报缺失，看起来像"4.7 不兼容"，实际原因是没有登记。

正确顺序：

```bash
tools/install_voxel.sh                     # 下载并解压
... --headless --path game --import        # 让编辑器登记一次（必须）
... --headless --path game --script res://scripts/probe_voxel.gd   # 再探针
```

**需要承担**

- 六棱柱这条路线作废，`game/scripts/main.gd` 里那套单元字典与蜂窝排布将被 `VoxelTerrain` 场景取代。已经跑通的"可寻址单元模型"经验仍然有效——`godot_voxel` 的世界同样是可寻址体素，只是它替你做了区块与流式加载。
- 「避免与《我的世界》撞脸」这条约束没有消失，但它从此**落在美术、镜头、玩法上，而不是几何形状上**。这一点需要后续用画面验证。
- 51MB 二进制不入库，改为 `tools/install_voxel.sh` 获取。

**未解决**

- 尚未用 `VoxelTerrain` 搭出可跑的场景，探针只证明"类能加载"，不证明"地形能生成"。
- 方块沙盒的观感方案未定：如何在方块几何上做出与 MC 明显不同的视觉识别度。

---

## 附录 · 落地过程中踩的坑（2026-09-13 夜）

第一次跑 `VoxelTerrain` 时，自检报告"网格块 = 0"，看起来像地形根本没生成。为此连续排查了六轮，最后发现**前五轮都在追一个假症状**。

**假症状的来源**：判据写的是 `_terrain.get_statistics()` 里一个叫 `mesh_blocks` 的键。这个键**不存在**——`VoxelTerrain.get_statistics()` 返回的是逐帧统计（`time_detect_required_blocks`、`time_request_blocks_to_load`、`updated_blocks` 等），没有网格块计数。按键不存在去数，永远得到 0。

**真相**：地形一直在正常工作。改成直接问地形 `has_data_block(voxel_to_data_block(...))` 之后，第一次等待就通过，并且统计里 `time_request_blocks_to_update` 显示 **2512** 个块被请求网格化。

**教训**：**判据要问对对象**。拿一个自己假设存在的数据结构当验收标准，会把"测错了"误判成"坏了"，而且症状会伪装成环境问题（headless、线程、bounds、stream），引诱人去改那些本来没坏的东西。

排查途中被改掉、事后确认**都不是**根因的东西：

| 改动 | 实际影响 |
|---|---|
| 把 `VoxelViewer` 从相机下挪到世界中心 | 无影响（但语义上确实更对，保留） |
| 去掉 `VoxelStreamMemory` 与 `bounds` | 无影响（保留，减少变量） |
| 加 `VoxelEngineUpdater` 节点 | 未能证明必要，先留着 |
| 换用内置 `VoxelGeneratorNoise2D` | 无影响，已换回自写的分层生成器 |

真正有价值的三条经验仍然成立，且与上述无关：

1. `set_material_override` 是 2 个槽，不是 6 个面
2. `TINT_RAW_COLOR` 需要体素颜色通道的深度配置，否则网格化直接报错卡死
3. 高度要量化成台阶，否则地形读成灯芯绒且看不到分层
