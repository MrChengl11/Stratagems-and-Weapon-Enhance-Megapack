# -*- coding: utf-8 -*-
"""Build the all-in-one Megapack and standalone packages for HD2 mods.

Completely self-contained builder using local tools/ and src/.
Generates:
1. dist/DSH-Mods-Megapack.zip (Multi-option pack for HD2MM/Arsenal)
2. dist/*.zip (Individual standalone packages for each mod)
"""
import os
import sys
import json
import uuid
import zipfile

WORKSPACE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.join(WORKSPACE, "tools")
SRC_DIR = os.path.join(WORKSPACE, "src")
DIST_DIR = os.path.join(WORKSPACE, "dist")
BUILT_DIR = os.path.join(WORKSPACE, "built_mods")

sys.path.insert(0, TOOLS_DIR)
import hd2_archive as A
import build_addon as B

# Format entry source
def get_source(name, filename):
    filepath = os.path.join(SRC_DIR, filename)
    with open(filepath, "rb") as f:
        content = f.read()
    return B.entry_source(name, content)

MOD_DEFS = {
    "laser": {
        "id": "mods/dsh/orbital_laser_free",
        "file": "orbital_laser_free.lua",
        "title": "Orbital Laser Free",
        "guid": "c1f74a9b-8e2d-4f11-9a3b-2c4e6f8a0d1e",
        "desc": "Orbital Laser has unlimited uses and cooldown reduced from 300s to 180s.",
        "zip_name": "Orbital-Laser-Free.zip",
        "cn_zip_name": "轨道激光无限次使用（修复间歇性掉帧）.zip"
    },
    "barrage": {
        "id": "mods/dsh/double_barrage",
        "file": "double_barrage.lua",
        "title": "Double 380mm Barrage",
        "guid": "d4e21a8c-7f3b-4b22-8c1d-9e5a7b3f2c4a",
        "desc": "Doubles the number of shells in the 380mm Orbital HE Barrage within the same duration.",
        "zip_name": "Double-380mm-Barrage.zip",
        "cn_zip_name": "380火力网翻倍（修复间歇性掉帧）.zip"
    },
    "leveller": {
        "id": "mods/dsh/double_leveller",
        "file": "double_leveller.lua",
        "title": "Double Leveller",
        "guid": "b26f4557-25b6-1aeb-91c4-8a7e3d1b5c9f",
        "desc": "EAT-411 Leveller hellpod drops two launchers per call instead of one.",
        "zip_name": "Double-Leveller.zip",
        "cn_zip_name": "双倍荡平者（修复间歇性掉帧）.zip"
    },
    "carpet": {
        "id": "mods/dsh/eagle_carpet_bomb",
        "file": "eagle_carpet_bomb.lua",
        "title": "Eagle Carpet Bomb",
        "guid": "e5b82c19-6d4a-4f33-9b7e-1a2c3d4e5f6a",
        "desc": "Restores the unreleased Eagle Carpet Bomb stratagem (hijacks Eagle 110mm Rocket Pods slot).",
        "zip_name": "Eagle-Carpet-Bomb.zip",
        "cn_zip_name": "地毯式轰炸（修复间歇性掉帧）轰炸.zip"
    },
    "eruptor": {
        "id": "mods/dsh/dominator_eruptor",
        "file": "dominator_eruptor.lua",
        "title": "Dominator - R-36 Eruptor Round",
        "guid": "a8c91d2e-3f4b-5a6c-7d8e-9f0a1b2c3d4e",
        "desc": "JAR-5 Dominator fires R-36 Eruptor explosive armor-piercing rounds.",
        "zip_name": "Dominator-Eruptor-Round.zip",
        "cn_zip_name": "主宰发射爆裂铳（修复间歇性掉帧）.zip"
    },
    "bolt_pistol": {
        "id": "mods/dsh/dominator_bolt_pistol",
        "file": "dominator_bolt_pistol.lua",
        "title": "Dominator - GP-31 Bolt Pistol Round",
        "guid": "f3b2a1c0-9d8e-7f6a-5b4c-3d2e1a0f9e8d",
        "desc": "JAR-5 Dominator fires GP-31 Bolt Pistol rounds.",
        "zip_name": "Dominator-Bolt-Pistol-Round.zip",
        "cn_zip_name": "主宰发射爆弹（修复间歇性掉帧）.zip"
    },
}

source_bytes = {}
for k, info in MOD_DEFS.items():
    source_bytes[k] = (info["id"], get_source(info["id"], info["file"]))

def make_archive_for_mods(keys):
    resources = {}
    for k in keys:
        mod_id, body = source_bytes[k]
        resources[mod_id] = A.envelope(body)
    return A.make_archive(resources)

MEGAPACK_OPTIONS = [
    {
        "folder": "AllInOneEruptor",
        "name": "【全套整合】战备全套 + 主宰改爆裂铳 (All Stratagems + Eruptor)",
        "description": "一键启用全部战备模组（轨道激光无限、380翻倍、双倍荡平者、地毯空袭）及主宰发射爆裂铳弹药。",
        "mods": ["laser", "barrage", "leveller", "carpet", "eruptor"]
    },
    {
        "folder": "AllInOneBoltPistol",
        "name": "【全套整合】战备全套 + 主宰改爆弹枪 (All Stratagems + Bolt Pistol)",
        "description": "一键启用全部战备模组（轨道激光无限、380翻倍、双倍荡平者、地毯空袭）及主宰发射爆弹枪弹药。",
        "mods": ["laser", "barrage", "leveller", "carpet", "bolt_pistol"]
    },
    {
        "folder": "AllStratagems",
        "name": "【战备整合】仅战备全套 (All Stratagems Only - 不修改武器)",
        "description": "一键启用全部4款战备模组（轨道激光无限、380翻倍、双倍荡平者、地毯空袭），完全不修改主宰枪械属性。",
        "mods": ["laser", "barrage", "leveller", "carpet"]
    },
    {
        "folder": "OrbitalLaserFree",
        "name": "【独立可选】轨道激光无限次使用 (Orbital Laser Free)",
        "description": "轨道激光战备取消3次使用次数限制，冷却时间从300秒缩短至180秒。",
        "mods": ["laser"]
    },
    {
        "folder": "Double380mmBarrage",
        "name": "【独立可选】380mm火力网翻倍 (Double 380mm Barrage)",
        "description": "380mm轨道火力网齐射数量翻倍，单次呼叫释放双倍弹幕压制。",
        "mods": ["barrage"]
    },
    {
        "folder": "DoubleLeveller",
        "name": "【独立可选】双倍荡平者空投 (Double Leveller)",
        "description": "EAT-411 荡平者呼叫空投舱时一次性掉落两根发射器（原版为1根）。",
        "mods": ["leveller"]
    },
    {
        "folder": "EagleCarpetBomb",
        "name": "【独立可选】飞鹰地毯式空袭 (Eagle Carpet Bomb)",
        "description": "恢复未发布的飞鹰地毯式空袭战备（借壳飞鹰110mm火箭巢槽位）。",
        "mods": ["carpet"]
    },
    {
        "folder": "DominatorEruptorRound",
        "name": "【独立可选】主宰发射爆裂铳 (Dominator - R-36 Eruptor Round)",
        "description": "JAR-5 主宰发射 R-36 爆裂铳爆炸穿甲弹丸。【注意: 与爆弹枪二选一，请勿同时勾选】",
        "mods": ["eruptor"]
    },
    {
        "folder": "DominatorBoltPistolRound",
        "name": "【独立可选】主宰发射爆弹枪 (Dominator - GP-31 Bolt Pistol Round)",
        "description": "JAR-5 主宰发射 GP-31 爆弹手枪弹药。【注意: 与爆裂铳二选一，请勿同时勾选】",
        "mods": ["bolt_pistol"]
    },
]

def build_standalone_mods():
    print("Building standalone mod packages...")
    for k, info in MOD_DEFS.items():
        archive = make_archive_for_mods([k])
        manifest = {
            "Version": 1,
            "Guid": info["guid"],
            "Name": info["title"],
            "Description": info["desc"] + " (Requires Bingus Shared Loader v15+)",
            "Options": [{"Name": info["title"], "Description": info["desc"], "Include": ["Addon"]}]
        }
        files = {
            "manifest.json": (json.dumps(manifest, indent=2) + "\n").encode("utf-8"),
            "Addon/" + A.ARCHIVE_NAME: archive,
            "Addon/" + A.ARCHIVE_NAME + ".stream": b"",
            "Addon/" + A.ARCHIVE_NAME + ".gpu_resources": b"",
        }
        
        # Write to dist/ and built_mods/ and root
        out_paths = [
            os.path.join(DIST_DIR, info["zip_name"]),
            os.path.join(BUILT_DIR, info["zip_name"]),
            os.path.join(BUILT_DIR, info["cn_zip_name"]),
            os.path.join(WORKSPACE, info["zip_name"]),
        ]
        for out in out_paths:
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as z:
                for path, data in sorted(files.items()):
                    item = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
                    item.compress_type = zipfile.ZIP_DEFLATED
                    item.external_attr = 0o100644 << 16
                    z.writestr(item, data)
        print("  -> Built %s (%d bytes)" % (info["zip_name"], len(archive)))

def build_megapack():
    print("\nBuilding Megapack packages...")
    megapack_guid = "7d2e85a1-4321-4b89-a5e2-63b7f1984210"
    manifest = {
        "Version": 1,
        "Guid": megapack_guid,
        "Name": "Stratagems & Weapon Enhance Megapack",
        "Description": (
            "DSH Stratagems & Weapon Enhance Megapack for Helldivers 2.\n"
            "Intermittent FPS halving and scanning lag 100% FIXED.\n"
            "Includes Orbital Laser Free, Double 380mm, Double Leveller, Eagle Carpet Bomb, and Dominator custom rounds.\n"
            "Requires Bingus Shared Loader v15 or newer."
        ),
        "Options": []
    }

    readme_text = """========================================================================
   Helldivers 2 - Stratagems & Weapon Enhance Megapack (FPS Fixed)
   绝地潜兵 2 - 战备与武器强化整合包 (掉帧彻底修复版)
========================================================================

【Included Mods / 包含模组】
1. Orbital Laser Free (轨道激光无限次使用 + 冷却缩短至180秒)
2. Double 380mm Barrage (380mm 轨道火力网数量翻倍)
3. Double Leveller (EAT-411 荡平者一次空投两根发射器)
4. Eagle Carpet Bomb (飞鹰地毯式空袭，借壳飞鹰110mm槽位)
5. Dominator Eruptor Round (JAR-5 主宰发射 R-36 爆裂铳弹丸)
6. Dominator Bolt Pistol Round (JAR-5 主宰发射 GP-31 爆弹手枪弹药)

【Key Performance Fixes / 性能与掉帧修复亮点】
- 彻底消除了原版每 10 分钟触发的 2,500 帧全量内存暴力重扫 (消灭帧率骤降一半持续40秒的元凶)。
- 维护扫描添加 2ms 硬时钟预算 (os.clock deadline)，杜绝单帧微卡顿。
- 安全退钩守卫 (Guarded Update Unhook)，不截断后续挂载的其他模组的 update 链。
- 稳态静默运行，取消频繁写盘。

【Installation Guide / 安装方法】
使用 HD2 Mod Manager (HD2MM) 或 Arsenal (推荐):
1. 确保已安装 Bingus Shared Loader v15 或更高版本。
2. 将本 ZIP 导入 HD2MM 或 Arsenal。
3. 在模组选项 (Options) 中勾选所需功能：
   - 勾选【全套整合】预设可一键开启全套战备 + 主宰武器；
   - 勾选【战备整合】预设可仅开启4款战备，不修改武器；
   - 或自由勾选【独立可选】条目进行组合搭配。
4. 点击 Purge，然后点击 Deploy，启动游戏即可。
========================================================================
"""

    zip_entries = {}
    zip_entries["README.txt"] = readme_text.encode("utf-8")

    for opt in MEGAPACK_OPTIONS:
        manifest["Options"].append({
            "Name": opt["name"],
            "Description": opt["description"],
            "Include": ["options/" + opt["folder"]]
        })
        archive_data = make_archive_for_mods(opt["mods"])
        prefix = "options/" + opt["folder"] + "/"
        zip_entries[prefix + A.ARCHIVE_NAME] = archive_data
        zip_entries[prefix + A.ARCHIVE_NAME + ".stream"] = b""
        zip_entries[prefix + A.ARCHIVE_NAME + ".gpu_resources"] = b""

    zip_entries["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")

    targets = [
        os.path.join(DIST_DIR, "DSH-Mods-Megapack.zip"),
        os.path.join(BUILT_DIR, "DSH-Mods-Megapack.zip"),
        os.path.join(BUILT_DIR, "绝地潜兵2-自研模组全整合包（修复间歇性掉帧）.zip"),
        os.path.join(WORKSPACE, "DSH-Mods-Megapack.zip"),
    ]

    for target in targets:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for path, data in sorted(zip_entries.items()):
                info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                z.writestr(info, data)
        print("  -> Built %s (%d bytes, %d files)" % (os.path.basename(target), os.path.getsize(target), len(zip_entries)))

if __name__ == "__main__":
    build_standalone_mods()
    build_megapack()
    print("\nALL BUILDS FINISHED SUCCESSFULLY!")
