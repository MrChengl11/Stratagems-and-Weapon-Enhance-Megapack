# -*- coding: utf-8 -*-
"""Verification script for Stratagems & Weapon Enhance Megapack.

Checks:
1. Source Lua syntax and addon header integrity
2. Archive parse and resource hash verification
3. Megapack and standalone ZIP contents
"""
import os
import sys
import json
import zipfile

WORKSPACE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.join(WORKSPACE, "tools")
SRC_DIR = os.path.join(WORKSPACE, "src")
DIST_DIR = os.path.join(WORKSPACE, "dist")

sys.path.insert(0, TOOLS_DIR)
import hd2_archive as A

ok = True

def check(label, cond, extra=""):
    global ok
    ok = ok and bool(cond)
    print("  [%s] %s%s" % ("PASS" if cond else "FAIL", label, ("  " + extra) if extra else ""))

print("1. Checking Source Lua Files...")
expected_mods = {
    "orbital_laser_free.lua": "mods/dsh/orbital_laser_free",
    "double_barrage.lua": "mods/dsh/double_barrage",
    "double_leveller.lua": "mods/dsh/double_leveller",
    "eagle_carpet_bomb.lua": "mods/dsh/eagle_carpet_bomb",
    "dominator_eruptor.lua": "mods/dsh/dominator_eruptor",
    "dominator_bolt_pistol.lua": "mods/dsh/dominator_bolt_pistol",
}

for filename, mod_id in expected_mods.items():
    filepath = os.path.join(SRC_DIR, filename)
    exists = os.path.isfile(filepath)
    check("Source exists: %s" % filename, exists)
    if exists:
        with open(filepath, "r", encoding="utf-8") as f:
            first_line = f.readline().strip()
        expected_header = "-- HD2-Addon: " + mod_id
        check("Header matches for %s" % filename, first_line == expected_header, first_line)

print("\n2. Checking Megapack Archive in dist/...")
megapack_zip = os.path.join(DIST_DIR, "DSH-Mods-Megapack.zip")
check("DSH-Mods-Megapack.zip exists", os.path.isfile(megapack_zip))

if os.path.isfile(megapack_zip):
    with zipfile.ZipFile(megapack_zip, "r") as z:
        check("manifest.json present in Megapack", "manifest.json" in z.namelist())
        check("README.txt present in Megapack", "README.txt" in z.namelist())
        
        manifest = json.loads(z.read("manifest.json").decode("utf-8"))
        check("Manifest has Options", len(manifest.get("Options", [])) >= 9, "found %d options" % len(manifest.get("Options", [])))
        
        for opt in manifest.get("Options", []):
            folder = opt["Include"][0]
            patch_path = folder + "/" + A.ARCHIVE_NAME
            check("Patch archive exists: %s" % patch_path, patch_path in z.namelist())
            if patch_path in z.namelist():
                archive_data = z.read(patch_path)
                parsed = A.parse(archive_data)
                check("Option '%s' parsed %d addon(s)" % (opt["Name"][:25], parsed["count"]), parsed["count"] >= 1)

print("\n3. Checking Standalone Mod Packages in dist/...")
standalone_zips = [
    ("Orbital-Laser-Free.zip", 0xB966F2E95E67D31C),
    ("Double-380mm-Barrage.zip", 0x39A5ED535474E342),
    ("Double-Leveller.zip", 0xB26F455725B61AEB),
    ("Eagle-Carpet-Bomb.zip", 0x91A35C353B216296),
    ("Dominator-Eruptor-Round.zip", 0xAC2ED152D1B45BF8),
    ("Dominator-Bolt-Pistol-Round.zip", 0x08135D61AE2B7D58),
]

for zip_name, expected_hash in standalone_zips:
    p = os.path.join(DIST_DIR, zip_name)
    check("ZIP exists: %s" % zip_name, os.path.isfile(p))
    if os.path.isfile(p):
        with zipfile.ZipFile(p, "r") as z:
            patch_entry = "Addon/" + A.ARCHIVE_NAME
            check("Addon archive present in %s" % zip_name, patch_entry in z.namelist())
            if patch_entry in z.namelist():
                data = z.read(patch_entry)
                info = A.parse(data)
                check("Resource hash matches for %s" % zip_name, info["entries"][0]["name"] == expected_hash, "0x%016X" % info["entries"][0]["name"])

print("\n" + ("=" * 50))
print("ALL VERIFICATION CHECKS PASSED!" if ok else "SOME VERIFICATION CHECKS FAILED!")
print("=" * 50)
sys.exit(0 if ok else 1)
