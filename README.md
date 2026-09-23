# Helldivers 2 - Stratagems and Weapon Enhance Megapack
### 绝地潜兵 2 - 战备与武器强化整合包 (掉帧彻底修复版)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Requires: Bingus Shared Loader v15+](https://img.shields.io/badge/Loader-Bingus%20Shared%20Loader%20v15%2B-blue.svg)](https://github.com/CowboyBingus/BingusSharedLoader/releases/latest)
[![Performance: Zero FPS Drop](https://img.shields.io/badge/Performance-Zero%20FPS%20Drop%20Verified-brightgreen.svg)](#performance--anti-stutter-architecture)
[![Game Version: 1.8.45850+](https://img.shields.io/badge/Game%20Build-1.8.45850%2B-orange.svg)](#)

[中文说明 (README in Chinese)](#-中文说明--chinese-documentation) | [English Documentation](#-english-documentation)

---

## 📖 English Documentation

### Overview
**Stratagems and Weapon Enhance Megapack** is a curated, high-performance compilation of quality-of-life and firepower enhancement Lua mods for *Helldivers 2*. 

Built for use with **Bingus Shared Loader (v15+)**, this megapack provides both **1-click all-in-one presets** and **modular individual options** compatible with **HD2 Mod Manager (HD2MM)** and **Arsenal**.

> ⚡ **Performance Guaranteed**: Earlier versions of HD2 Lua mods frequently suffered from an intermittent issue where FPS would suddenly drop by half every 10 minutes for ~40 seconds. This repository incorporates the complete **v1.7.0 lifecycle governance architecture**—eliminating memory scan storms, enforcing a 2ms CPU deadline budget, and safeguarding downstream mod hooks.

---

### Included Mods

| Mod | In-Game Effect | Key Details |
|---|---|---|
| 🛰️ **Orbital Laser Free** | Unlimited uses + 180s Cooldown | Removes the 3-use mission limit; reduces cooldown from 300s to 180s. |
| 💥 **Double 380mm Barrage** | 2x Artillery Saturation | Doubles the total shells fired during the 380mm HE barrage within the same duration. |
| 🚀 **Double Leveller** | 2x EAT-411 Hellpod Drop | Hellpod drops two Leveller launchers instead of one. |
| 🦅 **Eagle Carpet Bomb** | Heavy Carpet Bomb Restored | Restores the hidden Eagle Carpet Bomb stratagem (hijacks the eagle smoke  slot). |
| 🎯 **Dominator - Eruptor Round** | R-36 Explosive Shrapnel | Equips the JAR-5 Dominator with R-36 Eruptor explosive armor-piercing projectile. |
| 🔫 **Dominator - Bolt Pistol Round** | GP-31 Explosive Round | Equips the JAR-5 Dominator with high-rate-of-fire GP-31 explosive bolt projectile. |

*(Note: The two Dominator variants are mutually exclusive—choose one or neither in the Mod Manager options).*

---

### Performance & Anti-Stutter Architecture

This megapack was completely re-engineered according to the `hd2-lua-mod` v1.7.0 guidelines:

1. **Elimination of 10-Minute Rescan Storms (`deep_seconds = 0`)**:
   - *Previous bug*: Every 10 minutes (36,000 frames), the mod re-traversed ~30,000 memory regions across 2,500 frames, consuming 4ms–16ms CPU per frame and cutting FPS from 60 to 30.
   - *Fix*: Once validated and patched, the mod enters permanent steady-state sleep. Full rescans are only permitted if all patched memory copies are destroyed (`alive == 0`).
2. **Hard CPU Deadline Budget (`os.clock() + 0.002`)**:
   - Maintenance scans are capped at a strict 2ms limit per frame, preventing frame-drop spikes.
3. **Guarded Update Unhooking**:
   - `_G.update` hook wrapping preserves all downstream mod update chains, preventing conflicts when running alongside other mod packs.
4. **Quiet Steady-State I/O**:
   - Unconditional periodic disk writes to `STATUS.txt` are disabled; status writes occur only on real state transitions.

---

### Installation Guide

#### Method 1: Using HD2 Mod Manager (HD2MM) or Arsenal (Recommended)

1. Download and install [**Bingus Shared Loader v15+**](https://github.com/CowboyBingus/BingusSharedLoader/releases/latest).
2. Download [**`DSH-Mods-Megapack.zip`**](dist/DSH-Mods-Megapack.zip) from the `dist/` folder or Releases.
3. Drag and drop `DSH-Mods-Megapack.zip` into HD2 Mod Manager or Arsenal.
4. In the mod **Options** configuration dialog, select your desired preset or options:
   - **Preset A**: `【全套整合】战备全套 + 主宰改爆裂铳 (All Stratagems + Eruptor)`
   - **Preset B**: `【全套整合】战备全套 + 主宰改爆弹枪 (All Stratagems + Bolt Pistol)`
   - **Preset C**: `【战备整合】仅战备全套 (All Stratagems Only - 不修改武器)`
   - Or individually toggle specific mods under `【独立可选】`.
5. Click **Purge**, then **Deploy**. Start the game!

#### Method 2: Manual Installation
If you prefer not to use a mod manager, download any standalone ZIP from the [`dist/`](dist/) folder, extract the `9ba626afa44a3aa3.patch_0` file from inside `Addon/`, and place it in your game's `data/` folder:
`<SteamLibrary>/steamapps/common/Helldivers 2/data/`

---

### Building from Source

To build all packages from source:
```bash
python build_megapack.py
```
To verify integrity and round-trip parsing:
```bash
python verify_pack.py
```

---

## 🇨🇳 中文说明 / Chinese Documentation

### 简介
**战备与武器强化整合包 (Stratagems and Weapon Enhance Megapack)** 是专为《绝地潜兵 2》(Helldivers 2) 打造的高性能 Lua 内存注入型模组整合包。

基于 **Bingus Shared Loader (v15+)** 运行时构建，完美兼容 **HD2 Mod Manager (HD2MM)** 与 **Arsenal** 模组管理器。提供多套“一键全套预设”与“独立单选复选框”，方便玩家自由定制。

### 核心亮点：彻底消灭“间歇性掉帧”
原版 Lua Mod 普遍存在**每 10 分钟游戏帧率突然减半并持续 40 秒**的严重性能隐患。本整合包采用 `hd2-lua-mod` v1.7.0 生命周期收敛模型，彻底根除了该问题：
- **禁用 10 分钟全内存重扫**：补丁生效后即刻休眠，稳态下每 5 秒仅进行一次微秒级直读复查，不再暴力遍历 30,000 个内存块。
- **2ms 硬时钟预算**：扫描循环引入 `os.clock() + 0.002` 上限，杜绝任何单帧卡顿。
- **安全退钩保护**：保护后续挂载的其他 Mod 的更新链，不破坏其他模组逻辑。
- **静默运行**：取消高频向磁盘写 `STATUS.txt`。

---

### 整合包内置功能一览

1. **🛰️ 轨道激光无限次使用 (Orbital Laser Free)**
   - 解除每场任务仅限 3 次的呼叫限制，可无限次呼叫。
   - 冷却时间从 300 秒大幅缩短至 180 秒。
2. **💥 380mm 轨道火力网数量翻倍 (Double 380mm Barrage)**
   - 在原版相同的呼叫持续时间内，投掷的 380mm 高爆弹丸数量直接翻倍，形成毁灭性火力覆盖。
3. **🚀 双倍荡平者空投 (Double Leveller)**
   - 呼叫 EAT-411 荡平者空投舱时，一次性掉落两根发射器（原版为 1 根）。
4. **🦅 飞鹰地毯式空袭 (Eagle Carpet Bomb)**
   - 完美恢复游戏未发布的重型飞鹰地毯空袭（借壳飞鹰烟雾槽位）。
5. **🎯 主宰发射爆裂铳弹药 (Dominator - R-36 Eruptor Round)**
   - 为 JAR-5 主宰装备 R-36 爆裂铳的强力爆炸穿甲破片弹头。
6. **🔫 主宰发射爆弹枪弹药 (Dominator - GP-31 Bolt Pistol Round)**
   - 为 JAR-5 主宰装备 GP-31 爆弹手枪的微型爆炸高射速弹药。

*(提示：两款主宰弹药模组在模组管理器中为二选一，请勿同时勾选两者)*

---

### 安装教程

#### 推荐方式：使用 HD2 Mod Manager 或 Arsenal

1. 确保已安装 [**Bingus Shared Loader v15 或更新版本**](https://github.com/CowboyBingus/BingusSharedLoader/releases/latest)。
2. 下载 [`dist/DSH-Mods-Megapack.zip`](dist/DSH-Mods-Megapack.zip)。
3. 直接将该 ZIP 拖入 HD2 Mod Manager 或 Arsenal 窗口进行导入。
4. 打开该 Mod 的 **Options (选项)** 弹窗：
   - 如果想一键开启所有战备 + 主宰武器，勾选【全套整合】预设之一即可；
   - 如果只想开启战备，勾选【战备整合】预设；
   - 或者自由勾选下方的【独立可选】模组组合。
5. 点击 **Purge**，然后点击 **Deploy**，启动游戏即可畅玩！

#### 独立单模组安装包
在 [`dist/`](dist/) 目录中提供了 6 款模组的独立安装包，可按需单独下载导入：
- `Orbital-Laser-Free.zip` (轨道激光无限次)
- `Double-380mm-Barrage.zip` (380mm火力网翻倍)
- `Double-Leveller.zip` (双倍荡平者空投)
- `Eagle-Carpet-Bomb.zip` (飞鹰地毯式空袭)
- `Dominator-Eruptor-Round.zip` (主宰改爆裂铳)
- `Dominator-Bolt-Pistol-Round.zip` (主宰改爆弹枪)

---

### 本地编译与校验

如需从源码构建整合包及单包：
```bash
python build_megapack.py
```
如需运行自动化结构校验：
```bash
python verify_pack.py
```

---

## 📜 License
This project is licensed under the [MIT License](LICENSE).
Helldivers 2 is a trademark of Sony Interactive Entertainment LLC and Arrowhead Game Studios AB. This project is an unofficial community mod and is not affiliated with or endorsed by Sony or Arrowhead.
