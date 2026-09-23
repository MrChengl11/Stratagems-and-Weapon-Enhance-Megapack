-- HD2-Addon: mods/dsh/dominator_bolt_pistol
-- Gives the JAR-5 Dominator the P/40-K Bolt Pistol's projectile (balanced variant).
--
-- How it works
--   The game memory-maps generated_projectile_settings.dl_bin. Each projectile is a
--   272-byte record whose first field is a unique ProjectileType id. A weapon's
--   ProjectileWeaponComponent names the type it fires, so swapping one record's payload
--   changes what that weapon shoots.
--
--   The Dominator, the R-36 Eruptor and the P/40-K Bolt Pistol all fire the same 15x100mm
--   shell - identical mass (100 g), drag (0%), gravity (30%) and penetration slowdown
--   (25%). They differ only in warhead and explosion, so this addon copies the chosen
--   combat round's projectile record over the Dominator's, keeping the Dominator's own
--   type id so the table stays consistent.
--
-- Everything is validated before a single byte is written, and the result is read back.

local state = rawget(_G, "DominatorBoltPistolRound")
if state then return end

local REVISION = "dbp-v1"

state = {
    revision = REVISION,
    frames = 0,
    applied = false,
    status = "starting",
}
rawset(_G, "DominatorBoltPistolRound", state)

-- ------------------------------------------------------------------ config --
-- Build-drift policy (2026-09-22: game 1.8.45317.0 -> 1.8.45850.0).
-- The old gate "block size must be 93312 and count must be 343" refused the entire
-- table once the update added 7 more projectiles (the block is 95216 / 350 now).
-- REC_SIZE is still the record stride, but it is now DERIVED from the block's own
-- array descriptor at runtime and this value is only the initial hint.
local REC_SIZE          = 272            -- hint; overwritten by the derived stride
local MIN_REC_SIZE      = 64
local MAX_REC_SIZE      = 4096
local MIN_REC_COUNT     = 32
local MAX_REC_COUNT     = 65536
local TYPE_PROJECTILES  = 0xBD4042C2     -- DLHash("ProjectileSettings")
local DOMINATOR_TYPE    = 177            -- JAR-5 Dominator's ProjectileType

-- The warhead record to copy, identified against the wiki's published "Detailed Weapon
-- Statistics" for the P/40-K Bolt Pistol:
--   projectile  100 g, 350 m/s, drag 0%, gravity 30%, pen slowdown 25%,
--               damage 325 / durable 115, Heavy penetration      -> DamageInfoType 151
--   explosion   175 damage, Medium penetration, demo 10, stagger 35, push 5,
--               inner 1 m / outer 3.5 m, no shrapnel             -> ExplosionType 379
-- All 13 of those published values match record 256 exactly.
--
-- The Dominator, the R-36 Eruptor and the Bolt Pistol all share the same 15x100mm shell
-- family (identical mass, drag, gravity and penetration slowdown), so a warhead swap is a
-- straight record copy.
--
-- A punchier alternative is the R-36 Eruptor's warhead: ProjectileType 40 -> 230/115
-- Heavy with explosion 155 (225 damage, 30 shrapnel, 4-7 m). Set "source=40" in the
-- config file to use that instead.
local SOURCE_TYPE       = 201
-- Optional backup projectile id if the primary is missing (-1 disables the fallback).
local FALLBACK_TYPE     = -1

-- Explosion forced onto the round. These are ExplosionType *enum values* (the game
-- matches them against the entry's own type field, not the array index).
--
-- Picked by elimination: the Eruptor's explosion comes from its weapon-side
-- explosive component, so it is referenced by NO projectile in the table. Among the
-- explosions that spawn the ESTILHAÇO shrapnel projectile (type 200) exactly three
-- are referenced by no projectile at all: 253, 194 and 115.
--   253 -> damage 500, armour pen 3, demolition 20, 35 shrapnel, radius 4..10 m
--   194 -> damage 150, armour pen 5, demolition 30, 30 shrapnel, radius 1.6..5 m
--   115 -> damage 1000, armour pen 5, demolition 30, 35 shrapnel, radius 2..8 m
-- 253 is the best fit for a primary-weapon explosive round. Swap the constant below
-- to try the others.
-- -1 means "keep whatever the source record carries". The Eruptor's own record
-- already points at explosion 155 on both impact and expiry, so no override is needed.
-- Set these to force a specific ExplosionType instead.
local EXPLOSION_ON_IMPACT = -1
local EXPLOSION_ON_EXPIRE = -1

-- Optional override file so candidate values can be tried without repackaging:
--   %LOCALAPPDATA%/Hd2ProjRecon/dominator_bolt_pistol.cfg
-- containing lines such as
--   source=40
--   explosion=155
local function read_overrides()
    local base = os.getenv("LOCALAPPDATA")
    if not base then return end
    local ok, f = pcall(io.open, base .. "/Hd2ProjRecon/dominator_bolt_pistol.cfg", "r")
    if not ok or not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*(%a+)%s*=%s*(%d+)")
        if k and v then
            v = tonumber(v)
            if k == "explosion" then EXPLOSION_ON_IMPACT = v
            elseif k == "source" then SOURCE_TYPE = v
            elseif k == "fallback" then FALLBACK_TYPE = v
            elseif k == "expire" then EXPLOSION_ON_EXPIRE = v end
        end
    end
    f:close()
end

-- record field offsets (verified against the game's own type library)
local OFF_TYPE          = 0
local OFF_NAME_UPPER    = 4
local OFF_SPEED         = 32
local OFF_MASS          = 36
local OFF_DRAG          = 40
local OFF_GRAVITY       = 44
local OFF_DAMAGE        = 60
local OFF_THRUSTER      = 72
local OFF_EXPL_IMPACT   = 144
local OFF_EXPL_EXPIRE   = 156

-- ============================ 枚举回收 (2026-09-22) ============================
-- ProjectileType ids are NOT stable across builds. Measured on 1.8.45850:
--   type 201 used to be the P/40-K Bolt Pistol round (speed 350, drag 0,
--   gravity 0.30, DamageInfoType 151). In the new build type 201 is a totally
--   different projectile (speed 30, drag 0.40, gravity 1.00, DamageInfoType 189)
--   and the old code happily copied THAT onto the Dominator -- silently.
--
-- So identity now comes from the record itself: its name_upper hash (a hash of a
-- localisation key, stable) plus the ballistics of the 15x100mm shell family.
-- The ProjectileType id is only a hint, and it is *verified* before being used.
local NAME_15X100       = 0x1E2FAF6F   -- name_upper shared by the JAR-5 / P-40-K shells
-- Identity = name_upper hash + the shell's PHYSICAL ballistics, nothing else.
-- DamageInfoType / ExplosionType are enum indices too, and they drift as well:
-- the 15x100mm family's damage id was 144 in build 24826606 and is 149 in
-- 1.8.45850. Pinning on it made the matcher reject the very record it wanted
-- ("内容识别失败 ... 最佳得分 6"), so those fields are logged but never required.
-- The configured ProjectileType id is still tried FIRST and simply has to pass
-- the same stable check -- that also breaks ties inside a name group.
local IDENTITIES = {
    [40]  = { name = 0x095D6C88, speed = 180.0, label = "R-36 Eruptor round" },
    [201] = { name = NAME_15X100, speed = 350.0, label = "P/40-K Bolt Pistol round" },
}
local DOMINATOR_IDENT   = { name = NAME_15X100, speed = 180.0, label = "JAR-5 Dominator" }
local MIN_IDENT_SCORE   = 6      -- name + speed + mass + one more (max 7)

local VERIFY_EVERY      = 300            -- frames between re-checks (~5 s)
local SCAN_BUDGET       = 0.002          -- CPU seconds per scan step

-- --------------------------------------------------------------------- ffi --
local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then
    state.status = "no_ffi"
    print("[DominatorBolt] FFI unavailable")
    return
end

ffi.cdef [[
    void *GetCurrentProcess(void);
    void *GetModuleHandleA(const char *name);
    int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
    int VirtualProtect(void *address, size_t size, uint32_t protection, uint32_t *previous);
    typedef struct {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } DerMemRegion;
    size_t VirtualQuery(const void *address, void *region, size_t size);
    int CreateDirectoryA(const char *path, void *security);
    uint32_t GetLastError(void);
]]

local kernel = ffi.load("kernel32")
local process = kernel.GetCurrentProcess()

-- ------------------------------------------------------------------ logging --
local out_dir = nil
do
    local base = os.getenv("LOCALAPPDATA")
    if base then
        local candidate = base .. "/Hd2ProjRecon"
        if kernel.CreateDirectoryA(candidate, nil) ~= 0 or kernel.GetLastError() == 183 then
            out_dir = candidate
        end
    end
end

local NL = string.char(10)
local log_started = false
local function log(line)
    print("[DominatorBolt] " .. line)
    if not out_dir then return end
    local mode = log_started and "a" or "w"
    log_started = true
    local ok, f = pcall(io.open, out_dir .. "/DominatorBoltPistol.log", mode)
    if ok and f then
        pcall(f.write, f, line .. NL)
        pcall(f.close, f)
    end
end

-- ------------------------------------------------------------------ memory --
local scratch = ffi.new("uint8_t[1048576]")
local read_count = ffi.new("size_t[1]")
local written = ffi.new("size_t[1]")

local function read_at(address, size)
    if size <= 0 or size > 1048576 then return nil end
    if kernel.ReadProcessMemory(process, ffi.cast("const void *", address), scratch, size, read_count) == 0 then return nil end
    if read_count[0] ~= size then return nil end
    return ffi.string(scratch, size)
end

local region = ffi.new("DerMemRegion[1]")
local region_size = ffi.sizeof(region[0])

local function region_info(address)
    if kernel.VirtualQuery(ffi.cast("const void *", address), ffi.cast("void *", region), region_size) ~= region_size then
        return nil
    end
    return {
        base = tonumber(ffi.cast("uintptr_t", region[0].base)),
        size = tonumber(region[0].size),
        state = tonumber(region[0].state),
        protection = tonumber(region[0].protection),
        type = tonumber(region[0].type),
    }
end

local function is_writable_data(address, size)
    local r = region_info(address)
    if not r then return false end
    if r.state ~= 4096 then return false end
    if r.protection ~= 4 and r.protection ~= 8 then return false end
    if r.type ~= 131072 and r.type ~= 262144 then return false end
    return r.base <= address and address + size <= r.base + r.size
end

-- Write, temporarily lifting write protection if the page is read-only.
local function write_bytes(address, bytes)
    local n = #bytes
    if is_writable_data(address, n) then
        if kernel.WriteProcessMemory(process, ffi.cast("void *", address), bytes, n, written) == 0 then return false end
        return written[0] == n
    end
    local r = region_info(address)
    if not r or r.state ~= 4096 then return false end
    if r.type ~= 131072 and r.type ~= 262144 then return false end
    local previous = ffi.new("uint32_t[1]")
    if kernel.VirtualProtect(ffi.cast("void *", address), n, 4, previous) == 0 then return false end
    local ok = kernel.WriteProcessMemory(process, ffi.cast("void *", address), bytes, n, written) ~= 0
        and written[0] == n
    local discarded = ffi.new("uint32_t[1]")
    kernel.VirtualProtect(ffi.cast("void *", address), n, previous[0], discarded)
    return ok
end

local function u32_at(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u64_at(s, i)
    local lo = u32_at(s, i)
    local hi = u32_at(s, i + 4)
    if not lo or not hi then return nil end
    -- values we care about (pointers, ids) are far below 2^53, but keep the low/high
    -- split explicit so nothing is silently truncated by Lua's double precision
    return lo + hi * 4294967296
end

-- IEEE-754 single decode in pure Lua.
--
-- This used to poke a uint32_t[1] through a "float *" alias. That is classic type
-- punning and LuaJIT is allowed to keep the float load in a register across a hot
-- loop, so scanning 343 records returned stale values for some fields and the
-- identity matcher scored the right record as a miss. Pure arithmetic cannot be
-- optimised into a wrong answer, so it is used from here on.
local function bits_to_f32(bits)
    local sign = 1
    if bits >= 2147483648 then sign = -1; bits = bits - 2147483648 end
    local exp  = math.floor(bits / 8388608)
    local mant = bits - exp * 8388608
    if exp == 255 then
        if mant == 0 then return sign * math.huge end
        return 0 / 0
    end
    if exp == 0 then
        if mant == 0 then return sign * 0.0 end
        return sign * mant * 2 ^ -149
    end
    return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function f32_at(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return bits_to_f32(a + b * 256 + c * 65536 + d * 16777216)
end

-- Replace 4 bytes at 1-based index i. Plain concatenation only: feeding numeric
-- byte values through table.concat would render them as decimal text.
local function put_u32(s, i, v)
    return s:sub(1, i - 1)
        .. string.char(v % 256, math.floor(v / 256) % 256,
            math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
        .. s:sub(i + 4)
end

-- ------------------------------------------------------- locate the table ---
local SIGNATURE = string.char(0x4C, 0x44, 0x4C, 0x44, 1, 0, 0, 0,
    TYPE_PROJECTILES % 256, math.floor(TYPE_PROJECTILES / 256) % 256,
    math.floor(TYPE_PROJECTILES / 65536) % 256, math.floor(TYPE_PROJECTILES / 16777216) % 256)

-- Our own signature string lives in the Lua heap; never report a hit there.
local self_anchor = nil
do
    local ok, p = pcall(function()
        return tonumber(ffi.cast("uintptr_t", ffi.cast("const char *", SIGNATURE)))
    end)
    if ok and p and p > 0 then self_anchor = p end
end

local table_info = nil     -- { records = address, count = n }

-- Sanity-probe a record array without trusting any build constant.
local function probe_array(ptr, cnt, stride)
    if ptr < 65536 or ptr >= 2 ^ 47 then return nil, "pointer out of range" end
    if cnt < MIN_REC_COUNT or cnt > MAX_REC_COUNT then return nil, "count " .. tostring(cnt) end
    if stride < MIN_REC_SIZE or stride > MAX_REC_SIZE then
        return nil, "stride " .. tostring(stride)
    end
    local samples, sane = 8, 0
    for k = 0, samples - 1 do
        local index = math.floor(k * cnt / samples)
        local rec = read_at(ptr + index * stride, 8)
        if rec then
            local t = u32_at(rec, 1)
            if t and t < 20000 then sane = sane + 1 end
        end
    end
    if sane < samples - 1 then return nil, "records look like noise" end
    return true
end

-- Accept a ProjectileSettings block on magic + version + type hash alone, then
-- derive the record stride from its own DLArray descriptor. Two descriptor forms
-- are tried, exactly as the skill warns: in memory the first u64 is an absolute
-- pointer, in the on-disk image it is a relative offset.
local function validate_block(buf, magic)
    local ver = u32_at(buf, magic + 4)
    local typ = u32_at(buf, magic + 8)
    local size = u32_at(buf, magic + 12)
    if ver ~= 1 or typ ~= TYPE_PROJECTILES then return nil end
    if not size or size < 1024 or size > 16777216 then return nil end
    local f1 = u64_at(buf, magic + 24)
    local cnt = u64_at(buf, magic + 32)
    if not f1 or not cnt then return nil end
    if cnt < MIN_REC_COUNT or cnt > MAX_REC_COUNT then return nil end
    -- data (after the 24-byte header) = 16-byte descriptor + cnt * stride
    if (size - 16) % cnt ~= 0 then return nil end
    local stride = math.floor((size - 16) / cnt)
    local candidates = { f1, magic + 24 + f1 }
    for i = 1, #candidates do
        local ptr = candidates[i]
        if probe_array(ptr, cnt, stride) then
            if i == 2 then
                log(string.format("block 0x%X: descriptor read as a RELATIVE offset", magic))
            end
            return ptr, cnt, stride
        end
    end
    return nil
end

local region_list = nil
local region_index = 1
local region_offset = 0
local previous = ""
local CHUNK = 262144
local OVERLAP = 2048
local scan_finished = false
local scanned_bytes = 0

-- Scan policy (skill 6.14): never "fail forever". Bound the number of full
-- rounds, back off between them, and leave a census + STATUS behind instead of
-- grinding the player's frame rate when the table simply is not loaded yet.
local BACKOFF = { 2, 4, 8, 16, 30, 60, 120, 300 }
local MAX_EMPTY_ROUNDS = 8

local function write_file(name, text)
    if not out_dir then return false end
    local ok, f = pcall(io.open, out_dir .. "/" .. name, "w")
    if not ok or not f then return false end
    pcall(f.write, f, text)
    pcall(f.close, f)
    return true
end

local function write_status()
    local first
    if table_info then
        first = state.applied and "OK - patch applied" or "OK - projectile table located, applying"
    elseif state.gave_up then
        first = "FAILED - ProjectileSettings table never showed up (see census)"
    else
        first = "WORKING - scanning"
    end
    write_file("STATUS.txt", table.concat({
        first,
        "revision=" .. REVISION,
        "status=" .. tostring(state.status),
        "updated=" .. os.date("%Y-%m-%d %H:%M:%S"),
        "game=1.8.45850.0 (table grew to 95216 / 350 records; stride derived at runtime)",
        "scan_rounds=" .. tostring(state.scan_round or 0),
        "empty_rounds=" .. tostring(state.empty_rounds or 0),
        "records=" .. tostring(table_info and table_info.count or -1),
        "record_stride=" .. tostring(REC_SIZE),
        "source_type=" .. tostring(SOURCE_TYPE),
        "dominator_type=" .. tostring(DOMINATOR_TYPE),
        "log=" .. tostring(out_dir) .. "/DominatorBoltPistol.log",
    }, string.char(10)) .. string.char(10))
end

local function write_census()
    local body = { string.format("round %d; regions=%d scanned=%.0fMB; hits=%d",
        state.scan_round or 0, #(region_list or {}), scanned_bytes / 1048576, #(state.census or {})) }
    for i = 1, #(state.census or {}) do body[#body + 1] = state.census[i] end
    write_file(string.format("lld_census_round%d.txt", state.scan_round or 0),
        table.concat(body, string.char(10)) .. string.char(10))
end

local function is_readable(protection)
    return protection == 2 or protection == 4 or protection == 8
        or protection == 32 or protection == 64 or protection == 128
end

local function collect_regions()
    local list = {}
    local address = 65536
    while address < 2 ^ 47 do
        local r = region_info(address)
        if not r or not r.size or r.size <= 0 then break end
        if r.state == 4096 and is_readable(r.protection)
            and (r.type == 131072 or r.type == 262144) and r.size >= 65536 then
            if not (self_anchor and r.base <= self_anchor and self_anchor < r.base + r.size) then
                list[#list + 1] = { base = r.base, size = r.size }
            end
        end
        local next_address = r.base + r.size
        if next_address <= address then break end
        address = next_address
    end
    table.sort(list, function(a, b) return a.size > b.size end)
    return list
end

local function examine(window_base, window)
    local from = 1
    while true do
        local i = string.find(window, SIGNATURE, from, true)
        if not i then break end
        local abs = window_base + i - 1
        local skip = false
        if self_anchor then
            local d = abs - self_anchor
            if d > -4096 and d < 4096 then skip = true end
        end
        if not skip then
            state.census = state.census or {}
            local ptr, cnt, stride = validate_block(window, i)
            if not ptr and #state.census < 64 then
                state.census[#state.census + 1] = string.format(
                    "0x%X rejected (size=%s)", abs, tostring(u32_at(window, i + 12)))
            end
            if ptr then
                -- record stride came from the block itself, not from a build constant
                REC_SIZE = stride
                local probe = read_at(ptr, REC_SIZE)
                if probe and u32_at(probe, 1) ~= nil then
                    table_info = { records = ptr, count = cnt, magic = abs, stride = stride,
                                   size = u32_at(window, i + 12) }
                    log(string.format(
                        "projectile table found: magic=0x%X records=0x%X count=%d stride=%d (size=%d)",
                        abs, ptr, cnt, stride, table_info.size))
                    return true
                end
            end
        end
        from = i + 1
    end
    return false
end

local function scan_step()
    if scan_finished or table_info then return end
    if not region_list then
        -- First pass. Number it like reset_scan() does, otherwise the very first
        -- round is logged as "round 0" and the census file gets the wrong name.
        state.scan_round = (state.scan_round or 0) + 1
        state.census = {}
        region_list = collect_regions()
        region_index = 1
        region_offset = 0
        previous = ""
        scanned_bytes = 0
        log(string.format("round %d: %d regions", state.scan_round, #region_list))
        return
    end
    local deadline = os.clock() + SCAN_BUDGET
    while os.clock() < deadline do
        local r = region_list[region_index]
        if not r then
            scan_finished = true
            write_census()
            if table_info then
                state.empty_rounds = 0
                log(string.format("round %d done: table found (%d MB searched)",
                    state.scan_round or 0, math.floor(scanned_bytes / 1048576)))
            else
                state.empty_rounds = (state.empty_rounds or 0) + 1
                local wait = BACKOFF[math.min(state.empty_rounds, #BACKOFF)]
                state.next_scan_frame = state.frames + math.floor(wait * 60)
                log(string.format(
                    "round %d done: projectile table not in memory yet (empty %d/%d, next try in %ds, %d MB searched)",
                    state.scan_round or 0, state.empty_rounds, MAX_EMPTY_ROUNDS, wait,
                    math.floor(scanned_bytes / 1048576)))
                if state.empty_rounds >= MAX_EMPTY_ROUNDS then
                    state.gave_up = true
                    log("giving up: no ProjectileSettings table after " .. MAX_EMPTY_ROUNDS ..
                        " full rounds. Census written; all scanning stopped.")
                end
            end
            write_status()
            return
        end
        local remaining = r.size - region_offset
        if remaining <= 0 then
            region_index = region_index + 1
            region_offset = 0
            previous = ""
        else
            local want = CHUNK
            if want > remaining then want = remaining end
            local buf = read_at(r.base + region_offset, want)
            scanned_bytes = scanned_bytes + want
            if buf then
                local window_base = r.base + region_offset - #previous
                local window = previous .. buf
                if examine(window_base, window) then return end
                previous = buf:sub(-OVERLAP)
            else
                previous = ""
            end
            region_offset = region_offset + want
        end
    end
end

-- ------------------------------------------------------------------ apply ---
local function record_at(index)
    local address = table_info.records + index * REC_SIZE
    local bytes = read_at(address, REC_SIZE)
    if not bytes or #bytes ~= REC_SIZE then return nil, nil end
    return address, bytes
end

-- Guard: a wrong float decoder would silently mis-score every record.
do
    local checks = {
        [0x00000000] = 0.0, [0x3F800000] = 1.0, [0x43AF0000] = 350.0,
        [0x42C80000] = 100.0, [0x3E99999A] = 0.3, [0x3F19999A] = 0.6,
        [0x43960000] = 300.0, [0x3E800000] = 0.25,
    }
    for bits, want in pairs(checks) do
        local got = bits_to_f32(bits)
        if math.abs(got - want) > 1e-4 then
            state.status = "float_decoder_broken"
            log(string.format("float decoder self-check FAILED: 0x%08X -> %s, wanted %s. refusing to run.",
                bits, tostring(got), tostring(want)))
            return
        end
    end
end

-- One-shot dump of the whole live table. The 1.8.45850 update shifted
-- DamageInfoType values (144 -> 149) and recycled at least one ProjectileType id,
-- and guessing those offline cost two rounds. From now on the first run writes
-- every record's stable fields to disk so identities can be checked against
-- ground truth instead of against an old build.
local function dump_table()
    if state.dumped or not table_info then return end
    state.dumped = true
    local NLc = string.char(10)
    local lines = {
        string.format("ProjectileSettings magic=0x%X records=0x%X count=%d stride=%d size=%s",
            table_info.magic, table_info.records, table_info.count, REC_SIZE,
            tostring(table_info.size)),
        "idx\ttype\tname_upper\tcalibre\tspeed\tmass\tdrag\tgravity\tdmg\texpl_impact",
    }
    for i = 0, table_info.count - 1 do
        local _, rec = record_at(i)
        if rec then
            lines[#lines + 1] = string.format("%d\t%d\t0x%08X\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
                i, u32_at(rec, 1) or -1, u32_at(rec, OFF_NAME_UPPER + 1) or 0,
                tostring(f32_at(rec, 25)), tostring(f32_at(rec, OFF_SPEED + 1)),
                tostring(f32_at(rec, OFF_MASS + 1)), tostring(f32_at(rec, OFF_DRAG + 1)),
                tostring(f32_at(rec, OFF_GRAVITY + 1)), tostring(u32_at(rec, OFF_DAMAGE + 1)),
                tostring(u32_at(rec, OFF_EXPL_IMPACT + 1)))
        end
    end
    write_file("projectile_table.txt", table.concat(lines, NLc) .. NLc)
    log("已导出整张射弹表 -> projectile_table.txt (" .. tostring(table_info.count) .. " 条)")
end

local function find_by_type(want)
    for i = 0, table_info.count - 1 do
        local _, rec = record_at(i)
        if rec and u32_at(rec, OFF_TYPE + 1) == want then return i, rec end
    end
    return nil, nil
end

-- These identity lines repeat every frame while apply()/verify() run; only print
-- when the outcome actually changes, so the log stays readable.
local function log_once(key, line)
    state.logged = state.logged or {}
    if state.logged[key] ~= line then
        state.logged[key] = line
        log(line)
    end
end

-- Score one record against a wanted identity. -1 = wrong name hash (instant no).
local function ident_score(rec, want)
    local name  = u32_at(rec, OFF_NAME_UPPER + 1)
    if not name or name ~= want.name then return -1 end
    local speed = f32_at(rec, OFF_SPEED + 1)
    local mass  = f32_at(rec, OFF_MASS + 1)
    local drag  = f32_at(rec, OFF_DRAG + 1)
    local grav  = f32_at(rec, OFF_GRAVITY + 1)
    local s = 0
    -- speed is the field that separates the rounds inside one name group; a small
    -- tolerance absorbs build-to-build rebalancing.
    if speed and math.abs(speed - want.speed) <= 2.0 then s = s + 3 end
    if mass and math.abs(mass - 100.0) < 0.5  then s = s + 2 end
    if drag and math.abs(drag) < 0.001        then s = s + 1 end
    if grav and math.abs(grav - 0.3) < 0.02   then s = s + 1 end
    return s
end

-- Require a clear winner: all three pinning fields match (score >= 11 of 12) and
-- it is unique.
-- Two enum ids for the *same* round (byte-identical records) count as unique.
local function find_by_identity(want)
    local best_i, best, ties = nil, -1, 0
    for i = 0, table_info.count - 1 do
        local _, rec = record_at(i)
        if rec then
            local s = ident_score(rec, want)
            if s > best then best, best_i, ties = s, i, 1
            elseif s == best and s >= 0 then ties = ties + 1 end
        end
    end
    if not best_i or best < MIN_IDENT_SCORE then
        if best_i then
            local _, rec = record_at(best_i)
            if rec then
                log_once("cand_" .. tostring(want.label or "target"), string.format(
                    "  最佳候选 record %d: name=0x%08X speed=%s mass=%s drag=%s grav=%s dmg=%s -> 得分 %d",
                    best_i, tonumber(u32_at(rec, OFF_NAME_UPPER + 1)) or 0,
                    tostring(f32_at(rec, OFF_SPEED + 1)), tostring(f32_at(rec, OFF_MASS + 1)),
                    tostring(f32_at(rec, OFF_DRAG + 1)), tostring(f32_at(rec, OFF_GRAVITY + 1)),
                    tostring(u32_at(rec, OFF_DAMAGE + 1)), best))
            end
        end
        return nil, best, ties
    end
    if ties == 1 then return best_i, best, ties end
    local _, ref = record_at(best_i)
    if ref then
        for i = 0, table_info.count - 1 do
            if i ~= best_i then
                local _, rec = record_at(i)
                if rec and ident_score(rec, want) == best and rec ~= ref then
                    return nil, best, ties
                end
            end
        end
        return best_i, best, ties       -- all ties are byte-identical: same round
    end
    return nil, best, ties
end

local function find_source_index()
    local ident = IDENTITIES[SOURCE_TYPE]
    -- 1) the configured id, provided its record still passes the STABLE check.
    --    This is the normal path: the id is recycled only sometimes, and when it
    --    survives this also disambiguates records that share a name hash.
    if SOURCE_TYPE >= 0 then
        local i, rec = find_by_type(SOURCE_TYPE)
        if i and (not ident or ident_score(rec, ident) >= MIN_IDENT_SCORE) then
            log_once("src_id_ok", string.format(
                "源记录: ProjectileType %d 仍然对得上 -> record %d (name 0x%08X speed %s mass %s dmg %s)",
                SOURCE_TYPE, i, tonumber(u32_at(rec, OFF_NAME_UPPER + 1)) or 0,
                tostring(f32_at(rec, OFF_SPEED + 1)), tostring(f32_at(rec, OFF_MASS + 1)),
                tostring(u32_at(rec, OFF_DAMAGE + 1))))
            return i, rec, (ident and ident.label or "源射弹") .. " (enum id " .. SOURCE_TYPE .. ")"
        end
        if i then
            log_once("src_id_stale", string.format(
                "ProjectileType %d 指向 record %d 但内容对不上 (name 0x%08X speed %s mass %s) —— 枚举下标已被回收,改按内容查找",
                SOURCE_TYPE, i, tonumber(u32_at(rec, OFF_NAME_UPPER + 1)) or 0,
                tostring(f32_at(rec, OFF_SPEED + 1)), tostring(f32_at(rec, OFF_MASS + 1))))
        end
    end
    -- 2) content search over the whole table
    if ident then
        local i, score, ties = find_by_identity(ident)
        if i then
            log_once("src_ok", string.format(
                "源记录按内容识别: %s -> record %d (name 0x%08X, 得分 %s, 并列 %s)",
                ident.label, i, ident.name, tostring(score), tostring(ties)))
            local _, rec = record_at(i)
            return i, rec, ident.label
        end
        log_once("src_miss", string.format(
            "内容识别失败: %s 在表里找不到 (最佳得分 %s, 并列 %s)",
            ident.label, tostring(score), tostring(ties)))
    end
    if FALLBACK_TYPE >= 0 and FALLBACK_TYPE ~= SOURCE_TYPE then
        local j, rec2 = find_by_type(FALLBACK_TYPE)
        if j and (not ident or ident_score(rec2, ident) >= MIN_IDENT_SCORE) then
            return j, rec2, "fallback enum id " .. FALLBACK_TYPE
        end
    end
    return nil, nil, nil
end

local function find_target_index()
    -- 1) the configured id, if its record still passes the stable check
    local j, rec = find_by_type(DOMINATOR_TYPE)
    if j and ident_score(rec, DOMINATOR_IDENT) >= MIN_IDENT_SCORE then
        log_once("dst_id_ok", string.format(
            "目标记录: ProjectileType %d 仍然对得上 -> record %d (name 0x%08X speed %s mass %s dmg %s)",
            DOMINATOR_TYPE, j, tonumber(u32_at(rec, OFF_NAME_UPPER + 1)) or 0,
            tostring(f32_at(rec, OFF_SPEED + 1)), tostring(f32_at(rec, OFF_MASS + 1)),
            tostring(u32_at(rec, OFF_DAMAGE + 1))))
        return j, "enum id (verified)"
    end
    -- 1b) after OUR OWN write the target record carries the source round, so the
    --     Dominator check legitimately fails on it. Recognise that as "already
    --     patched" instead of refusing (verify() needs the index to work).
    local src_ident = IDENTITIES[SOURCE_TYPE]
    if j and src_ident and ident_score(rec, src_ident) >= MIN_IDENT_SCORE then
        return j, "already patched"
    end
    -- 2) otherwise find the Dominator by content
    local i = find_by_identity(DOMINATOR_IDENT)
    if i then return i, "content" end
    if j then
        log_once("dst_stale", string.format(
            "拒绝: ProjectileType %d 指向的 record %d 不像 JAR-5 主宰 (name 0x%08X speed %s mass %s) —— 枚举下标已回收",
            DOMINATOR_TYPE, j, tonumber(u32_at(rec, OFF_NAME_UPPER + 1)) or 0,
            tostring(f32_at(rec, OFF_SPEED + 1)), tostring(f32_at(rec, OFF_MASS + 1))))
    end
    return nil
end

local function apply()
    if not table_info then return end
    dump_table()

    local src, src_rec, src_label = find_source_index()
    if not src then
        state.status = "source_projectile_not_found"
        -- apply() runs every frame; without this the log grew to 1.1 MB in eight
        -- minutes (26 256 identical lines) and the disk churn was pointless.
        log_once("src_notfound", "source round not found (ProjectileType " .. SOURCE_TYPE .. ")")
        state.next_apply_frame = state.frames + 300      -- retry in ~5 s
        return
    end
    local dst = find_target_index()
    if not dst then
        state.status = "dominator_projectile_not_found"
        return
    end
    if src == dst then
        state.status = "source_equals_target"
        return
    end

    local src_addr = table_info.records + src * REC_SIZE
    local dst_addr, dst_rec = record_at(dst)
    if not src_rec or not dst_rec then
        state.status = "record_read_failed"
        return
    end

    local dst_type = u32_at(dst_rec, OFF_TYPE + 1)
    if dst_type ~= DOMINATOR_TYPE then
        state.status = "target_type_changed"
        return
    end

    -- Build the replacement payload:
    --   * keep the target's own type id so the table keeps unique type ids
    --   * force an impact explosion that spawns shrapnel
    --   * clear any airburst timer so the round detonates on contact
    local payload = put_u32(src_rec, 1, dst_type)
    if EXPLOSION_ON_IMPACT >= 0 then
        payload = put_u32(payload, OFF_EXPL_IMPACT + 1, EXPLOSION_ON_IMPACT)
    end
    if EXPLOSION_ON_EXPIRE >= 0 then
        payload = put_u32(payload, OFF_EXPL_EXPIRE + 1, EXPLOSION_ON_EXPIRE)
    end

    if #payload ~= REC_SIZE then
        state.status = "payload_size_error"
        log("payload size " .. #payload .. " != " .. REC_SIZE)
        return
    end

    if payload == dst_rec then
        state.applied = true
        state.status = "already_applied"
        return
    end

    if not write_bytes(dst_addr, payload) then
        state.status = "write_failed"
        log(string.format("write to 0x%X failed", dst_addr))
        return
    end

    local check = read_at(dst_addr, REC_SIZE)
    if check and check == payload then
        state.applied = true
        state.status = "applied"
        log(string.format("APPLIED: %s (record %d) -> Dominator (record %d), type kept at %d",
            src_label, src, dst, dst_type))
        log(string.format("  addresses 0x%X -> 0x%X", src_addr, dst_addr))
        log(string.format("  ballistics: mass=%.1f speed=%.1f drag=%.2f gravity=%.2f slowdown=%.2f",
            f32_at(src_rec, 37), f32_at(src_rec, 33), f32_at(src_rec, 41),
            f32_at(src_rec, 45), f32_at(src_rec, 65)))
        log(string.format("  damageType=%d  explosion on impact=%d / on expire=%d",
            u32_at(src_rec, 61), u32_at(src_rec, 145), u32_at(src_rec, 157)))
    else
        state.status = "verify_failed"
        log("write verification failed")
    end
end

local function verify()
    if not state.applied then return end
    local dst = find_target_index()
    if not dst then return end
    local _, dst_rec = record_at(dst)
    local src, src_rec = find_source_index()
    if not src or not dst_rec then return end
    -- compare against what apply() would write, not against the raw source
    local expect = put_u32(src_rec, 1, DOMINATOR_TYPE)
    if EXPLOSION_ON_IMPACT >= 0 then expect = put_u32(expect, OFF_EXPL_IMPACT + 1, EXPLOSION_ON_IMPACT) end
    if EXPLOSION_ON_EXPIRE >= 0 then expect = put_u32(expect, OFF_EXPL_EXPIRE + 1, EXPLOSION_ON_EXPIRE) end
    local same = (expect == dst_rec)
    if not same then
        log("projectile record reverted (map reload?); re-applying")
        state.applied = false
        apply()
    end
end

-- ------------------------------------------------------------------ drive ---
local function reset_scan()
    scan_finished = false
    region_list = collect_regions()
    region_index = 1
    region_offset = 0
    previous = ""
    scanned_bytes = 0
    state.scan_round = (state.scan_round or 0) + 1
    state.census = {}
    log(string.format("round %d: %d regions", state.scan_round, #region_list))
end

local original_update = update
if type(original_update) == "function" then
    local my_update
    my_update = function(...)
        state.frames = state.frames + 1
        if not state.retired and state.frames >= 120 then
            if not table_info then
                if not scan_finished then
                    if (state.frames % 2) == 0 then
                        local ok, err = pcall(scan_step)
                        if not ok then
                            scan_finished = true
                            log("scan error: " .. tostring(err))
                        end
                    end
                elseif not state.gave_up and state.frames >= (state.next_scan_frame or 0) then
                    -- The projectile table is not resident while docked, so a single
                    -- pass is not enough: retry with backoff instead of dying quietly.
                    local ok, err = pcall(reset_scan)
                    if not ok then log("rescan error: " .. tostring(err)) end
                end
            elseif table_info then
                if not state.applied and state.frames >= (state.next_apply_frame or 0) then
                    local ok, err = pcall(apply)
                    if not ok then
                        state.status = "apply_error: " .. tostring(err)
                        log(state.status)
                    end
                elseif (state.frames % VERIFY_EVERY) == 0 then
                    pcall(verify)
                end
            end
            if state.applied and not state.status_written then
                state.status_written = true
                pcall(write_status)
            end
        end
        return original_update(...)
    end
    update = my_update

    state.retire_hook = function()
        state.retired = true
        if update == my_update then
            update = original_update
        end
    end
    read_overrides()
    log(string.format("%s loaded; source=%d fallback=%d impactExplosion=%d expireExplosion=%d",
        REVISION, SOURCE_TYPE, FALLBACK_TYPE, EXPLOSION_ON_IMPACT, EXPLOSION_ON_EXPIRE))
    state.status = "hooked"
else
    state.status = "no_update"
    log("global update unavailable")
end

return { revision = REVISION, state = state }
