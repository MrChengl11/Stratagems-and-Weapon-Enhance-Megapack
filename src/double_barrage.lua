-- HD2-Addon: mods/dsh/double_barrage
-- Orbital 380mm HE Barrage ("轨道380mm高爆弹火力网"): double the rounds fired per
-- salvo while keeping the barrage's total duration bit-for-bit identical.
--
-- Baseline (verified against the game's own data table):
--   5 salvos x 3 shells = 15 shells, one shell every 1.5 s, 3.0 s pause between
--   salvos  ->  duration = (5-1)*(3.0 + (3-1)*1.5) + (3-1)*1.5 = 27.0 s
-- Patched:
--   5 salvos x 6 shells = 30 shells, one shell every 0.6 s, 3.0 s pause between
--   salvos  ->  duration = (5-1)*(3.0 + (6-1)*0.6) + (6-1)*0.6 = 27.0 s
--
-- Target table: BombardmentComponentData (LDLD, type 0xCDBC43D8, size 4672).
-- Layout, identical in the on-disk image and in memory:
--   +0    LDLD | version(1) | typeHash | size(4672) | is64=1 | pad7
--   +24   ComponentIndexData[40]        (16 bytes each: u64 entityHash, u32 idx, u32 pad)
--   +664  BombardmentComponent[21]      (192 bytes each)
--          +4    u32 RoundsPerSalvo
--          +8    f32 SecondsBetweenRounds
--          +24   u32 SalvoCount
--          +28   f32 SecondsBetweenSalvos
--          +36   f32 SalvoSpacing
--          +44   f32 BarrageRadius
-- The 380mm HE Barrage is entity 0xEF66B417EDC3B1D6 -> component index 7.

local state = rawget(_G, "Hd2DoubleBarrage")
if state then return end

state = {
    revision = "double-barrage-v1",
    frames = 0,
    patched = 0,
    phase = "init",
    refusals = 0,
}
rawset(_G, "Hd2DoubleBarrage", state)

-- ---------------------------------------------------------------- config ----
local CONFIG = {
    enabled          = true,     -- master switch
    recheck_seconds  = 5,        -- re-validate the patch this often
    full_rescan_seconds = 0,   -- 0 = 禁用全量周期重扫(消灭每10分钟掉帧半分钟的问题)   -- periodic full sweep for newly loaded copies
    rounds_per_salvo = 6,        -- written to +4   (baseline 3)
    seconds_between  = "3F19999A", -- written to +8 (big-endian hex of 0.6f, baseline 1.5f)
    seconds_between_value = 0.6, -- the same number, only used for log messages
    verbose          = false,    -- log every rejected candidate
}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then
    print("[DoubleBarrage] FFI unavailable; nothing to do")
    return
end

ffi.cdef [[
    void *GetCurrentProcess(void);
    int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
    int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
    int VirtualProtect(void *address, size_t size, uint32_t new_protect, uint32_t *old_protect);
    typedef struct {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } DshMemRegion;
    size_t VirtualQuery(const void *address, void *region, size_t size);
    int CreateDirectoryA(const char *path, void *security);
    uint32_t GetLastError(void);
]]

local kernel = ffi.load("kernel32")
local process = kernel.GetCurrentProcess()

local out_dir = nil
do
    local base = os.getenv("LOCALAPPDATA")
    if base then
        local candidate = base .. "/Hd2DoubleBarrage"
        if kernel.CreateDirectoryA(candidate, nil) ~= 0 or kernel.GetLastError() == 183 then
            out_dir = candidate
        end
    end
end

local NL = string.char(10)
local log_started = false
local function log(line)
    print("[DoubleBarrage] " .. line)
    if not out_dir then return end
    local mode = log_started and "a" or "w"
    log_started = true
    local ok, f = pcall(io.open, out_dir .. "/DoubleBarrage.log", mode)
    if ok and f then
        pcall(f.write, f, string.format("[frame %d] %s", state.frames, line) .. NL)
        pcall(f.close, f)
    end
end

local function write_file(name, text, mode)
    if not out_dir then return false end
    local ok, f = pcall(io.open, out_dir .. "/" .. name, mode or "w")
    if not ok or not f then return false end
    pcall(f.write, f, text)
    pcall(f.close, f)
    return true
end

-- ---------------------------------------------------------------- helpers ---
local scratch = ffi.new("uint8_t[1048576]")
local read_count = ffi.new("size_t[1]")
local written = ffi.new("size_t[1]")

local function read_at(address, size)
    if size <= 0 or size > 1048576 then return nil end
    local ok, r = pcall(function()
        return kernel.ReadProcessMemory(process, ffi.cast("const void *", address), scratch, size, read_count)
    end)
    if not ok or r == 0 then return nil end
    if read_count[0] ~= size then return nil end
    return ffi.string(scratch, size)
end

local function u32_at(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- big-endian hex text -> little-endian byte string.
-- NEVER goes through a Lua number for >2^53 values (see skill 6.1).
local function bytes_from_hex(hex)
    local out = {}
    for i = #hex / 2, 1, -1 do
        out[#out + 1] = string.char(tonumber(hex:sub(i * 2 - 1, i * 2), 16))
    end
    return table.concat(out)
end

local function u32_bytes(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function to_hex(s)
    local parts = {}
    for i = 1, #s do parts[i] = string.format("%02x", s:byte(i)) end
    return table.concat(parts)
end

-- -------------------------------------------------------------- constants ---
-- Build-drift policy (2026-09-22: game 1.8.45317.0 -> 1.8.45850.0).
-- The table grew from 4672 to 5120 bytes, so the old "size must equal 4672"
-- gate turned every candidate into a silent refusal. There is no longer any
-- size/count gate: the block is accepted on its type hash alone and the record
-- is located by the barrage's own published values. Bucket count, component
-- count and component size are *inferred and logged*, never required.
local MAGIC               = string.char(0x4C, 0x44, 0x4C, 0x44)   -- "LDLD"
local BOMBARD_TYPE_HASH   = 0xCDBC43D8                            -- djb2("BombardmentComponentData")
local DATA_OFF            = 24
local BUCKET_SIZE         = 16                                    -- ComponentIndexData stride
local MIN_TABLE_SIZE      = 256
local MAX_TABLE_SIZE      = 1048576

-- Orbital 380mm HE Barrage stratagem entity (asset: packages/generated/loadout/orbital_barrage.package)
local TARGET_ENTITY_HEX   = "EF66B417EDC3B1D6"
local TARGET_ENTITY_LE    = bytes_from_hex(TARGET_ENTITY_HEX)

local BOMBARD_SIG = MAGIC .. string.char(1, 0, 0, 0) .. bytes_from_hex("CDBC43D8")

-- field offsets inside one BombardmentComponent
local OFF_ROUNDS  = 4
local OFF_BETWEEN = 8
local OFF_SALVOS  = 24
local OFF_PAUSE   = 28
local OFF_SPACING = 36
local OFF_RADIUS  = 44

-- What the 380mm barrage must look like before we touch it. Positive IEEE-754
-- singles compare exactly like unsigned integers once you look at the raw bit
-- pattern, so every float check below is an integer comparison -- no float
-- conversion ever enters a decision.
local EXPECT = {
    rounds     = 3,
    between    = 0x3FC00000,            -- 1.5f, exact
    pause      = 0x40400000,            -- 3.0f, exact
    salvos     = { [5] = true, [6] = true },  -- 6 == the "More Guns" ship module
    spacing_lo = 0x4201999A,            -- 32.4f = 36.0f - 10%
    spacing_hi = 0x421E6666,            -- 39.6f = 36.0f + 10%
    radius_lo  = 0x44FA0000,            -- 2000f
    radius_hi  = 0x457A0000,            -- 4000f ("Atmospheric Monitoring" trims 15%)
}

local PATCH = {
    rounds  = CONFIG.rounds_per_salvo,
    between = bytes_from_hex(CONFIG.seconds_between),
}
local PATCH_BETWEEN_BITS = 0x3F19999A     -- 0.6f
local EXPECT_BETWEEN_BYTES = bytes_from_hex("3FC00000")

-- self-hit avoidance: our own pattern strings also live in the Lua heap
local self_addresses = {}
for _, s in ipairs({ BOMBARD_SIG, TARGET_ENTITY_LE }) do
    local ok, p = pcall(function()
        return tonumber(ffi.cast("uintptr_t", ffi.cast("const char *", s)))
    end)
    if ok and p and p > 0 then self_addresses[#self_addresses + 1] = p end
end

local function is_self(address)
    for i = 1, #self_addresses do
        local d = address - self_addresses[i]
        if d > -4096 and d < 4096 then return true end
    end
    return false
end

local function fmt_duration(rounds, between, salvos, pause)
    return (salvos - 1) * (pause + (rounds - 1) * between) + (rounds - 1) * between
end

-- ---------------------------------------------------------------- locate ----
-- Accept a block on magic + version + type hash ONLY, and hand back its declared
-- data size. There is deliberately no "size must equal 4672" gate any more: that
-- is precisely what silently refused every candidate after the 1.8.45850 update
-- (the table is 5120 bytes now).
local function validate_table(magic_address)
    local head = read_at(magic_address, 24)
    if not head then return nil, "unreadable" end
    if head:sub(1, 4) ~= MAGIC then return nil, "not LDLD" end
    local ver = u32_at(head, 5)
    local typ = u32_at(head, 9)
    local size = u32_at(head, 13)
    if ver ~= 1 then return nil, "version " .. tostring(ver) end
    if typ ~= BOMBARD_TYPE_HASH then return nil, string.format("type 0x%08X", typ or 0) end
    if not size or size < MIN_TABLE_SIZE or size > MAX_TABLE_SIZE then
        return nil, "size " .. tostring(size)
    end
    return size
end

-- Does the record starting at 0-based offset s inside the table data look like
-- the 380mm barrage, with the requested RoundsPerSalvo / SecondsBetweenRounds?
local function component_matches(data, s, rounds, between)
    local o = s + 1
    if u32_at(data, o + OFF_ROUNDS)  ~= rounds  then return false end
    if u32_at(data, o + OFF_BETWEEN) ~= between then return false end
    local salvos  = u32_at(data, o + OFF_SALVOS)
    local pause   = u32_at(data, o + OFF_PAUSE)
    local spacing = u32_at(data, o + OFF_SPACING)
    local radius  = u32_at(data, o + OFF_RADIUS)
    if not (salvos and pause and spacing and radius) then return false end
    if not EXPECT.salvos[salvos] then return false end
    if pause ~= EXPECT.pause then return false end
    if spacing < EXPECT.spacing_lo or spacing > EXPECT.spacing_hi then return false end
    if radius < EXPECT.radius_lo or radius > EXPECT.radius_hi then return false end
    return true
end

local function find_component_offset(data, size, rounds, between)
    local hits = {}
    for s = 0, size - 48 do
        if component_matches(data, s, rounds, between) then
            hits[#hits + 1] = s
            if #hits > 4 then break end
        end
    end
    if #hits == 1 then return hits[1] end
    return nil, hits
end

-- Resolve one table instance: entity bucket (cross-check) + component (by value).
-- Returns a descriptor, or nil plus a human-readable reason.
local function resolve_table(magic_address, size)
    local read_len = size
    if read_len > 262144 then read_len = 262144 end
    local data = read_at(magic_address + DATA_OFF, read_len)
    if not data then return nil, "table data unreadable" end
    size = #data

    -- 1) the target entity must be named by exactly one 16-byte ComponentIndexData
    --    bucket. Its index is only used as a cross-check and for the log.
    local idx, slot, n = nil, nil, 0
    for k = 0, math.floor((size - BUCKET_SIZE) / BUCKET_SIZE) do
        local o = k * BUCKET_SIZE + 1
        if data:sub(o, o + 7) == TARGET_ENTITY_LE then
            n = n + 1
            if n == 1 then idx = u32_at(data, o + 8); slot = k end
        end
    end
    if n == 0 then return nil, "no bucket carries entity " .. TARGET_ENTITY_HEX end
    -- The bucket is a cross-check; the record itself is located by value below.
    -- A second textual hit is logged, not fatal (the fingerprint must still be unique).
    if not idx then return nil, "target bucket carries no component index" end

    -- 2) find the record by its published values -- original form first, then the
    --    already-patched form, so we recognise our own work (idempotent).
    local off, hits = find_component_offset(data, size, EXPECT.rounds, EXPECT.between)
    local kind = "original"
    if not off then
        off, hits = find_component_offset(data, size, PATCH.rounds, PATCH_BETWEEN_BITS)
        kind = "patched"
    end
    if not off then
        local near = {}
        for i = 1, math.min(#hits, 4) do near[#near + 1] = tostring(hits[i]) end
        return nil, "record fingerprint not found (partial matches: " ..
            (#near > 0 and table.concat(near, ",") or "none") .. ")"
    end

    -- 3) infer (never require) the block's shape, and report it. Different
    --    (bucket count, component size) pairs can explain the same bytes; the
    --    fingerprint above is what we actually trust.
    local layouts = {}
    for z = 96, 512, 8 do
        local block = off - idx * z
        if block >= 0 and (block % BUCKET_SIZE) == 0 and (block / BUCKET_SIZE) > idx then
            local rest = size - block
            if rest > 0 and (rest % z) == 0 and (rest / z) > idx then
                layouts[#layouts + 1] = string.format("Z=%d B=%d C=%d", z, block / BUCKET_SIZE, rest / z)
            end
        end
    end

    return {
        size      = size,
        index     = idx,
        bucket    = slot,
        comp_off  = off,
        kind      = kind,
        layouts   = table.concat(layouts, " | "),
    }
end

-- returns "patch" | "already" | nil, reason ; second value is the salvo count
local function plan(index, comp)
    local rounds  = u32_at(comp, OFF_ROUNDS + 1)
    local between = u32_at(comp, OFF_BETWEEN + 1)
    local salvos  = u32_at(comp, OFF_SALVOS + 1)
    local pause   = u32_at(comp, OFF_PAUSE + 1)
    local spacing = u32_at(comp, OFF_SPACING + 1)
    local radius  = u32_at(comp, OFF_RADIUS + 1)

    if not (rounds and between and salvos and pause and spacing and radius) then
        return nil, "component record is truncated"
    end

    if rounds == PATCH.rounds and between == PATCH_BETWEEN_BITS then
        return "already", salvos
    end
    if rounds ~= EXPECT.rounds then
        return nil, "RoundsPerSalvo=" .. tostring(rounds) .. ", expected " .. EXPECT.rounds
    end
    if between ~= EXPECT.between then
        return nil, string.format("SecondsBetweenRounds=0x%08X, expected 0x%08X", between, EXPECT.between)
    end
    if not EXPECT.salvos[salvos] then
        return nil, "SalvoCount=" .. tostring(salvos) .. ", expected 5 or 6"
    end
    if pause ~= EXPECT.pause then
        return nil, string.format("SecondsBetweenSalvos=0x%08X, expected 0x%08X", pause, EXPECT.pause)
    end
    if spacing < EXPECT.spacing_lo or spacing > EXPECT.spacing_hi then
        return nil, string.format("SalvoSpacing=0x%08X, expected 0x%08X..0x%08X",
            spacing, EXPECT.spacing_lo, EXPECT.spacing_hi)
    end
    if radius < EXPECT.radius_lo or radius > EXPECT.radius_hi then
        return nil, string.format("BarrageRadius=0x%08X, expected 0x%08X..0x%08X",
            radius, EXPECT.radius_lo, EXPECT.radius_hi)
    end
    return "patch", salvos
end

-- ---------------------------------------------------------------- patching --
local function write_bytes(address, payload)
    local page = 4096
    local start = address - (address % page)
    local stop = address + #payload
    local span = (stop - (stop % page)) + page - start
    if span < #payload then span = page end
    local old = ffi.new("uint32_t[1]")
    local PAGE_READWRITE = 0x04
    if kernel.VirtualProtect(ffi.cast("void *", start), span, PAGE_READWRITE, old) == 0 then
        return false, "VirtualProtect failed"
    end
    local ok = kernel.WriteProcessMemory(process, ffi.cast("void *", address), payload, #payload, written)
    kernel.VirtualProtect(ffi.cast("void *", start), span, old[0], old)
    if ok == 0 then return false, "WriteProcessMemory failed" end
    if written[0] ~= #payload then return false, "wrote " .. tostring(written[0]) .. " of " .. #payload end
    return true
end

-- Patch ONE table instance. Returns true when that instance is patched.
-- Every copy the game keeps in memory gets its own call (skill: "同一张表在内存
-- 里有多份"; patching only the first is the classic "works for a minute" bug).
local function try_location(magic_address, size)
    local desc, why = resolve_table(magic_address, size)
    if not desc then return false, why end

    local comp_address = magic_address + DATA_OFF + desc.comp_off
    local comp = read_at(comp_address, 48)
    if not comp then return false, "component unreadable" end

    -- Log the resolved layout once per table copy, not on every 5 s recheck.
    if not state.tables[magic_address] then
        log(string.format("table 0x%X size=%d bucket=%d idx=%d comp=0x%X form=%s layout[%s]",
            magic_address, desc.size, desc.bucket, desc.index, comp_address, desc.kind,
            desc.layouts ~= "" and desc.layouts or "?"))
    end

    local verdict, detail = plan(desc.index, comp)
    if verdict == "already" then
        if not state.tables[magic_address] then
            log(string.format("table 0x%X already doubled", magic_address))
        end
        state.tables[magic_address] = desc
        return true
    end
    if not verdict then return false, detail end
    local salvos = detail

    write_file("original_component_" .. string.format("%X", magic_address) .. ".hex",
        string.format("table=0x%X|entity=%s|index=%d|component=0x%X|component_offset=%d|table_size=%d|bucket=%d",
            magic_address, TARGET_ENTITY_HEX, desc.index, comp_address,
            desc.comp_off, desc.size, desc.bucket) .. NL
        .. to_hex(read_at(magic_address + DATA_OFF, math.min(desc.size, 4096)) or "") .. NL)

    local payload = u32_bytes(PATCH.rounds) .. PATCH.between   -- +4 u32, +8 f32 (8 bytes)
    local before = read_at(comp_address + OFF_ROUNDS, 8)
    local okw, err = write_bytes(comp_address + OFF_ROUNDS, payload)
    if not okw then
        state.refusals = state.refusals + 1
        log("REFUSED write at 0x" .. string.format("%X", comp_address + OFF_ROUNDS) .. ": " .. tostring(err))
        return false, err
    end

    local after = read_at(comp_address + OFF_ROUNDS, 8)
    if not after or after ~= payload then
        state.refusals = state.refusals + 1
        log("REFUSED verification at 0x" .. string.format("%X", comp_address + OFF_ROUNDS)
            .. ": readback " .. (after and to_hex(after) or "(unreadable)"))
        return false, "readback mismatch"
    end
    state.patched = state.patched + 1
    state.tables[magic_address] = desc
    state.entity = TARGET_ENTITY_HEX
    state.phase = "patched"
    state.status_dirty = true
    log(string.format("PATCHED entity %s (component %d): table=0x%X comp=0x%X",
        TARGET_ENTITY_HEX, desc.index, magic_address, comp_address))
    log(string.format("  RoundsPerSalvo %d -> %d ; SecondsBetweenRounds %s -> %s",
        EXPECT.rounds, PATCH.rounds, to_hex(EXPECT_BETWEEN_BYTES), to_hex(PATCH.between)))
    log(string.format("  wrote %s (was %s)", to_hex(payload), before and to_hex(before) or "(unreadable)"))
    log(string.format("  barrage: %d salvos, %d rounds/salvo = %d shells over %.1f s (was %d shells over %.1f s)",
        salvos, PATCH.rounds, PATCH.rounds * salvos,
        fmt_duration(PATCH.rounds, CONFIG.seconds_between_value, salvos, 3.0),
        EXPECT.rounds * salvos,
        fmt_duration(EXPECT.rounds, 1.5, salvos, 3.0)))
    return true
end

-- ------------------------------------------------------------ scan driver ---
state.regions = nil
state.region_index = 1
state.region_offset = 0
state.previous = ""
state.scanned = 0
state.scan_round = 0
local SCAN_CHUNK = 262144
local SCAN_OVERLAP = 2048
local SCAN_BUDGET = 0.002
local SCAN_EVERY = 2

local max_scan = 2 ^ 47
local region = ffi.new("DshMemRegion[1]")
local region_size = ffi.sizeof(region[0])

local function is_readable(protection)
    return protection == 2 or protection == 4 or protection == 8
        or protection == 32 or protection == 64 or protection == 128
end

local function collect_regions()
    local list = {}
    local address = 65536
    while address < max_scan do
        if kernel.VirtualQuery(ffi.cast("const void *", address), ffi.cast("void *", region), region_size) ~= region_size then break end
        local base = tonumber(ffi.cast("uintptr_t", region[0].base))
        local size = tonumber(region[0].size)
        if not size or size <= 0 then break end
        if tonumber(region[0].state) == 4096 and is_readable(tonumber(region[0].protection))
            and size >= 65536 then
            list[#list + 1] = { base = base, size = size }
        end
        local next_address = base + size
        if next_address <= address then break end
        address = next_address
    end
    table.sort(list, function(a, b) return a.size > b.size end)
    return list
end

-- Scan policy (skill 6.14): a scanner that never finds anything AND never stops
-- is worse than one that is merely slow -- it costs the player frames forever.
-- So: collect *every* copy in one pass, then back off, then give up loudly and
-- leave a census behind instead of rescanning the address space forever.
state.tables = state.tables or {}
state.census = {}
state.empty_rounds = 0
state.next_scan_frame = 0
state.gave_up = false

local BACKOFF = { 2, 4, 8, 16, 30, 60, 120, 300 }
local MAX_EMPTY_ROUNDS = 8

local function table_count()
    local n = 0
    for _ in pairs(state.tables) do n = n + 1 end
    return n
end

local function write_status()
    local n = table_count()
    local first
    if n > 0 then
        first = string.format("OK - patch applied (%d table copy/copies live)", n)
    elseif state.gave_up then
        first = "FAILED - BombardmentComponentData never showed up (see census)"
    else
        first = "WORKING - scanning"
    end
    local lines = { first,
        "revision=" .. state.revision,
        "phase=" .. tostring(state.phase),
        "updated=" .. os.date("%Y-%m-%d %H:%M:%S"),
        "game=1.8.45850.0 (build drift: table grew 4672 -> handled at runtime)",
        "table_copies=" .. n,
        "patched_writes=" .. tostring(state.patched),
        "refusals=" .. tostring(state.refusals),
        "scan_rounds=" .. tostring(state.scan_round),
        "empty_rounds=" .. tostring(state.empty_rounds),
        "entity=" .. TARGET_ENTITY_HEX,
        "log=" .. tostring(out_dir) .. "/DoubleBarrage.log",
    }
    write_file("STATUS.txt", table.concat(lines, NL) .. NL)
end

local function begin_round()
    state.scan_round = state.scan_round + 1
    state.regions = collect_regions()
    state.region_index = 1
    state.region_offset = 0
    state.previous = ""
    state.scanned = 0
    state.logged_rejections = 0
    state.census = {}
    state.seen_this_round = {}
    log(string.format("round %d: %d regions", state.scan_round, #state.regions))
end

local function end_round(round_no)
    local n = table_count()
    local body = { string.format("round %d; regions=%d scanned=%.0fMB; type-hash hits=%d",
        round_no, #(state.regions or {}), (state.scanned or 0) / 1048576, #state.census) }
    for i = 1, #state.census do body[#body + 1] = state.census[i] end
    write_file(string.format("lld_census_round%d.txt", round_no), table.concat(body, NL) .. NL)
    if n > 0 then
        state.phase = "patched"
        state.empty_rounds = 0
        log(string.format("round %d done: %d table copy/copies patched", round_no, n))
    else
        state.empty_rounds = state.empty_rounds + 1
        local wait = BACKOFF[math.min(state.empty_rounds, #BACKOFF)]
        state.next_scan_frame = state.frames + math.floor(wait * 60)
        log(string.format("round %d done: nothing found (empty round %d/%d, next try in %ds)",
            round_no, state.empty_rounds, MAX_EMPTY_ROUNDS, wait))
        if state.empty_rounds >= MAX_EMPTY_ROUNDS then
            state.gave_up = true
            state.phase = "gave_up"
            log("giving up: no usable BombardmentComponentData table after " ..
                MAX_EMPTY_ROUNDS .. " full rounds. Census written; stopping all scanning.")
        end
    end
    state.regions = nil
    write_status()
end

local function scan_step()
    if state.gave_up then return end
    if state.frames < (state.next_scan_frame or 0) then return end
    if not state.regions then begin_round(); return end
    local deadline = os.clock() + SCAN_BUDGET
    while os.clock() < deadline do
        local r = state.regions[state.region_index]
        if not r then end_round(state.scan_round); return end
        local remaining = r.size - state.region_offset
        if remaining <= 0 then
            state.region_index = state.region_index + 1
            state.region_offset = 0
            state.previous = ""
        else
            local want = SCAN_CHUNK
            if want > remaining then want = remaining end
            local buf = read_at(r.base + state.region_offset, want)
            state.scanned = state.scanned + want
            if buf then
                local window_base = r.base + state.region_offset - #state.previous
                local window = state.previous .. buf
                local from = 1
                while true do
                    local i = string.find(window, BOMBARD_SIG, from, true)
                    if not i then break end
                    local abs = window_base + i - 1
                    if not is_self(abs) and not state.seen_this_round[abs] then
                        state.seen_this_round[abs] = true
                        -- NOTE: we no longer return on the first success. Every
                        -- copy in memory has to be patched, or the game will read
                        -- one we never touched.
                        local size, why0 = validate_table(abs)
                        local ok, why = false, why0
                        if size then ok, why = try_location(abs, size) end
                        local reason = ok and "patched" or tostring(why)
                        local sz = size or -1
                        state.census[#state.census + 1] =
                            string.format("0x%X size=%d -> %s", abs, sz, reason)
                        if not ok then
                            state.refusals = state.refusals + 1
                            if CONFIG.verbose or (state.logged_rejections or 0) < 6 then
                                state.logged_rejections = (state.logged_rejections or 0) + 1
                                log(string.format("candidate 0x%X (size=%s) rejected: %s",
                                    abs, tostring(size), reason))
                            end
                        end
                    end
                    from = i + 1
                end
                state.previous = buf:sub(-SCAN_OVERLAP)
            else
                state.previous = ""
            end
            state.region_offset = state.region_offset + want
        end
    end
end

-- Keep every known copy patched. Cheap: a handful of reads per table.
local function recheck()
    local alive = 0
    for magic_address, desc in pairs(state.tables) do
        local size, why = validate_table(magic_address)
        if not size then
            log(string.format("recheck: table 0x%X is gone (%s)", magic_address, tostring(why)))
            state.tables[magic_address] = nil
        else
            local ok, why2 = try_location(magic_address, size)
            if not ok then
                log(string.format("recheck: 0x%X refused: %s", magic_address, tostring(why2)))
            end
            alive = alive + 1
        end
    end
    if alive == 0 then
        state.tables = {}
        state.phase = "scanning"
        state.regions = nil
        state.empty_rounds = 0
        state.next_scan_frame = state.frames
        log("recheck: no live copies left; rescanning from scratch")
    end
end

local function tick()
    if state.phase == "patched" then
        -- keep STATUS.txt fresh: it may have been written before this copy landed
        if state.status_dirty then
            state.status_dirty = false
            pcall(write_status)
        end
        local interval = math.max(60, math.floor(CONFIG.recheck_seconds * 60))
        if (state.frames - (state.last_recheck or 0)) >= interval then
            state.last_recheck = state.frames
            recheck()
            -- Periodic full sweep: disabled when full_rescan_seconds <= 0
            if CONFIG.full_rescan_seconds and CONFIG.full_rescan_seconds > 0 then
                local full = math.max(interval, math.floor(CONFIG.full_rescan_seconds * 60))
                if (state.frames - (state.last_full or 0)) >= full then
                    state.last_full = state.frames
                    log("periodic full rescan for newly loaded table copies")
                    state.regions = nil
                    state.empty_rounds = 0
                    state.phase = "scanning"
                end
            end
        end
    else
        scan_step()
    end
end

state.phase = "scanning"
local original_update = update
if type(original_update) == "function" then
    local my_update
    my_update = function(...)
        state.frames = state.frames + 1
        if not state.retired and CONFIG.enabled and state.frames >= 120 and (state.frames % SCAN_EVERY) == 0 then
            local ok, err = pcall(tick)
            if not ok then
                state.errors = (state.errors or 0) + 1
                if state.errors <= 5 then log("tick error: " .. tostring(err)) end
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
    log(state.revision .. " armed; out_dir=" .. tostring(out_dir))
else
    state.phase = "no_update"
    log("global update unavailable; cannot run")
end

return { revision = state.revision, state = state }
