-- HD2-Addon: mods/dsh/double_leveller
-- EAT-411 Leveller: fill the hellpod rack's empty second slot so one call-in
-- drops two launchers, exactly like the EAT-17 and EAT-700 already do.
--
-- Target: the HellpodRackComponentData template in memory (LDLD table, type
-- 0xA98BB156). The Leveller's rack has SpawnPayloadSize = 2 but only one payload
-- defined, and the spawn logic stops at the first empty item. We copy rack slot 0
-- into slot 1 and retarget it to the right-hand attach node.
--
-- 64 bytes, two fields: Node 0x76C6D1E3 -> 0x7FE13CFF, RackSide Left(2) -> Right(1).
-- That is byte-for-byte what the game itself ships for the EAT-17 rack.
--
-- Table layout (identical in the on-disk image and in memory):
--   +0    LDLD | version(1) | typeHash | size(42568) | is64 | pad7
--   +24   ComponentIndexData[140]               (2240 bytes)
--   +2264 HellpodRackComponent[71]              (568 bytes each)
--          +0   RackAttach payloads[8]          (64 bytes each)
--          +556 u32 SpawnPayloadSize
-- Leveller rack index 26 -> slot0 at magic+17032, slot1 at magic+17096.

local state = rawget(_G, "Hd2DoubleLeveller")
if state then return end

state = {
    revision = "double-leveller-v1",
    frames = 0,
    patched = 0,
    phase = "init",
    refusals = 0,
}
rawset(_G, "Hd2DoubleLeveller", state)

-- ---------------------------------------------------------------- config ----
local CONFIG = {
    enabled            = true,     -- master switch
    spawn_payload_size = 2,        -- what the rack is expected to declare
    recheck_seconds    = 5,        -- re-validate the patch this often
    full_rescan_seconds = 0,        -- 0 = 禁用全量周期重扫(消灭每10分钟掉帧半分钟的问题)
    right_node         = 0x7FE13CFF,
    rack_side_right    = 1,
    verbose            = false,    -- log every rejected candidate
}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then
    print("[DoubleLeveller] FFI unavailable; nothing to do")
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
        local candidate = base .. "/Hd2DoubleLeveller"
        if kernel.CreateDirectoryA(candidate, nil) ~= 0 or kernel.GetLastError() == 183 then
            out_dir = candidate
        end
    end
end

local NL = string.char(10)
local log_started = false
local function log(line)
    print("[DoubleLeveller] " .. line)
    if not out_dir then return end
    local mode = log_started and "a" or "w"
    log_started = true
    local ok, f = pcall(io.open, out_dir .. "/DoubleLeveller.log", mode)
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

local function le_from_hex(hex)
    return (hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)):reverse()
end

local function to_hex(s)
    local parts = {}
    for i = 1, #s do parts[i] = string.format("%02x", s:byte(i)) end
    return table.concat(parts)
end

local function u32_bytes(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- -------------------------------------------------------------- constants ---
-- Build-drift policy (2026-09-22: game 1.8.45317.0 -> 1.8.45850.0).
-- No table size / rack count / index-array size / rack block offset is required
-- any more. The Leveller's rack is identified by its own payload item hash and
-- slot 1 is exactly ATTACH_SIZE bytes into that rack, so the whole thing works
-- whatever the surrounding layout does.
local MAGIC             = string.char(0x4C, 0x44, 0x4C, 0x44)   -- "LDLD"
local RACK_TYPE_HASH    = 0xA98BB156                            -- djb2("HellpodRackComponentData")
local DATA_OFF          = 24
local INDEX_BYTES_HINT  = 2240       -- hint only: used to report the rack index
local RACK_SIZE         = 568        -- stride of one HellpodRackComponent
local MIN_TABLE_SIZE    = 1024
local MAX_TABLE_SIZE    = 1048576
local ATTACH_SIZE       = 64
local OFF_ATTACH_NODE   = 8          -- 0-based, within one RackAttach
local OFF_ATTACH_SIDE   = 52         -- 0-based
local OFF_SPAWN_PAYLOAD = 556        -- 0-based, within one HellpodRackComponent
local ZERO8             = string.rep(string.char(0), 8)

local LEVELLER_ITEM     = le_from_hex("7617642765AC38C7")
local RIGHT_NODE        = u32_bytes(0x7FE13CFF)
local RACK_SIG          = MAGIC .. string.char(1, 0, 0, 0) .. le_from_hex("A98BB156")

-- self-hit avoidance: both patterns also live in our own Lua heap
local self_addresses = {}
for _, s in ipairs({ RACK_SIG, LEVELLER_ITEM }) do
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

-- ---------------------------------------------------------------- locate ----
-- Accept a block on magic + version + type hash only; return its declared size.
-- The old "size must be 42568" gate is gone on purpose (see the build-drift note).
local function validate_table(magic_address)
    local head = read_at(magic_address, 24)
    if not head then return nil, "unreadable" end
    if head:sub(1, 4) ~= MAGIC then return nil, "not LDLD" end
    local ver = u32_at(head, 5)
    local typ = u32_at(head, 9)
    local size = u32_at(head, 13)
    if ver ~= 1 then return nil, "version " .. tostring(ver) end
    if typ ~= RACK_TYPE_HASH then return nil, string.format("type 0x%08X", typ or 0) end
    if not size or size < MIN_TABLE_SIZE or size > MAX_TABLE_SIZE then
        return nil, "size " .. tostring(size)
    end
    return size
end

-- Locate the Leveller's rack inside one table instance, by content only:
-- the rack's first 8 bytes are the Leveller payload item hash.
local function resolve_rack(magic_address, size)
    local read_len = size
    if read_len > 262144 then read_len = 262144 end
    local data = read_at(magic_address + DATA_OFF, read_len)
    if not data then return nil, "table data unreadable" end
    size = #data

    -- The item hash can appear more than once in the table; only one of those
    -- positions is a real Leveller rack, so filter by the rack's own invariants
    -- (SpawnPayloadSize) instead of demanding a single textual hit.
    local rack0, hits, valid = nil, 0, 0
    local from = 1
    while true do
        local i = data:find(LEVELLER_ITEM, from, true)
        if not i then break end
        hits = hits + 1
        local at = i - 1                          -- 0-based offset inside the data
        if at + RACK_SIZE <= size then
            local spawn = u32_at(data, at + OFF_SPAWN_PAYLOAD + 1)
            if spawn == CONFIG.spawn_payload_size then
                valid = valid + 1
                if not rack0 then rack0 = at end
            end
        end
        from = i + 1
        if hits > 64 then break end
    end
    if hits == 0 then return nil, "no rack carries the Leveller payload" end
    if valid == 0 then
        return nil, hits .. " item-hash hit(s), none is a valid rack (SpawnPayloadSize mismatch)"
    end
    if valid > 1 then
        return nil, valid .. " valid Leveller racks in one table (refusing: ambiguous)"
    end
    if rack0 + RACK_SIZE > size then return nil, "rack runs past the end of the table" end
    local index = (rack0 - INDEX_BYTES_HINT) / RACK_SIZE
    local grid_ok = (index == math.floor(index)) and index >= 0
    return {
        rack0 = rack0,
        index = index,
        grid_ok = grid_ok,
        size = size,
        comp = data:sub(rack0 + 1, rack0 + RACK_SIZE),
    }
end

-- Build the 64-byte slot-1 RackAttach: a copy of slot 0 with the node hash and
-- the rack side flipped. Returns payload, slot1_offset_in_data | "already" | nil, reason.
local function build_slot1(rack)
    local spawn = u32_at(rack.comp, OFF_SPAWN_PAYLOAD + 1)
    if spawn ~= CONFIG.spawn_payload_size then
        return nil, string.format("SpawnPayloadSize=%s, expected %d",
            tostring(spawn), CONFIG.spawn_payload_size)
    end
    local slot1 = rack.comp:sub(ATTACH_SIZE + 1, ATTACH_SIZE * 2)
    if #slot1 ~= ATTACH_SIZE then return nil, "short rack record" end
    if slot1:sub(1, 8) == LEVELLER_ITEM then return "already" end
    if slot1:sub(1, 8) ~= ZERO8 then
        return nil, "slot 1 is occupied by " .. to_hex(slot1:sub(1, 8))
    end
    local payload = rack.comp:sub(1, ATTACH_SIZE)
    payload = payload:sub(1, OFF_ATTACH_NODE)
        .. RIGHT_NODE
        .. payload:sub(OFF_ATTACH_NODE + 5, OFF_ATTACH_SIDE)
        .. u32_bytes(CONFIG.rack_side_right)
        .. payload:sub(OFF_ATTACH_SIDE + 5)
    if #payload ~= ATTACH_SIZE then return nil, "payload size " .. tostring(#payload) end
    if payload:sub(1, 8) ~= LEVELLER_ITEM then
        return nil, "payload does not start with the Leveller item"
    end
    return payload, rack.rack0 + ATTACH_SIZE
end

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

-- Patch ONE table copy. The scan no longer stops at the first hit: every copy
-- the game keeps in memory has to be patched, otherwise the game happily reads
-- one we never touched (skill 6.17 -- this is the "works, then stops working"
-- trap, and it is scan-order dependent, which is why an update can flip it).
local function try_location(magic_address, size)
    local rack, why = resolve_rack(magic_address, size)
    if not rack then return false, why end
    local payload, second = build_slot1(rack)
    if payload == "already" then
        if not state.tables[magic_address] then
            log(string.format("table 0x%X rack %.2f already carries two payloads",
                magic_address, rack.index))
        end
        state.tables[magic_address] = rack
        return true
    end
    if not payload then return false, second end

    local slot1_address = magic_address + DATA_OFF + second
    local before = read_at(slot1_address, ATTACH_SIZE)
    write_file("original_slot1_" .. string.format("%X", magic_address) .. ".hex",
        string.format("table=0x%X|rack_index=%.2f|slot1=0x%X|offset_from_magic=%d|table_size=%d|grid_ok=%s",
            magic_address, rack.index, slot1_address, DATA_OFF + second, rack.size,
            tostring(rack.grid_ok)) .. NL
        .. (before and to_hex(before) or "(unreadable)") .. NL)

    local okw, err = write_bytes(slot1_address, payload)
    if not okw then
        state.refusals = state.refusals + 1
        log("REFUSED write at 0x" .. string.format("%X", slot1_address) .. ": " .. tostring(err))
        return false, err
    end
    local after = read_at(slot1_address, ATTACH_SIZE)
    if not after or #after ~= ATTACH_SIZE or after:sub(1, 8) ~= LEVELLER_ITEM then
        state.refusals = state.refusals + 1
        log("REFUSED verification at 0x" .. string.format("%X", slot1_address) .. ": readback mismatch")
        return false, "readback mismatch"
    end
    local node_ok = after:sub(OFF_ATTACH_NODE + 1, OFF_ATTACH_NODE + 4) == RIGHT_NODE
    local side_ok = u32_at(after, OFF_ATTACH_SIDE + 1) == CONFIG.rack_side_right
    state.patched = state.patched + 1
    state.tables[magic_address] = rack
    state.phase = "patched"
    state.status_dirty = true
    log(string.format("PATCHED rack %.2f: table=0x%X size=%d slot1=0x%X node_ok=%s side_ok=%s",
        rack.index, magic_address, rack.size, slot1_address, tostring(node_ok), tostring(side_ok)))
    log("  wrote " .. to_hex(payload))
    return true
end

-- ------------------------------------------------------------ scan driver ---
-- Scan policy (skill 6.14 + 6.17):
--   * one pass collects EVERY table copy and patches each of them -- stopping at
--     the first hit is scan-order dependent and is exactly how a patch "works,
--     then suddenly stops working" after a game update;
--   * empty rounds back off exponentially and then stop for good, leaving a
--     census + STATUS behind instead of grinding the player's frame rate.
state.tables = state.tables or {}
state.census = {}
state.empty_rounds = 0
state.next_scan_frame = 0
state.scan_round = 0
state.gave_up = false

local BACKOFF = { 2, 4, 8, 16, 30, 60, 120, 300 }
local MAX_EMPTY_ROUNDS = 8
local SCAN_CHUNK = 262144
local SCAN_OVERLAP = 2048
local SCAN_BUDGET = 0.002
local SCAN_EVERY = 2

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
        first = "FAILED - HellpodRackComponentData never showed up (see census)"
    else
        first = "WORKING - scanning"
    end
    write_file("STATUS.txt", table.concat({
        first,
        "revision=" .. state.revision,
        "phase=" .. tostring(state.phase),
        "updated=" .. os.date("%Y-%m-%d %H:%M:%S"),
        "game=1.8.45850.0 (rack located by content, no layout constant)",
        "table_copies=" .. n,
        "patched_writes=" .. tostring(state.patched),
        "refusals=" .. tostring(state.refusals),
        "scan_rounds=" .. tostring(state.scan_round),
        "empty_rounds=" .. tostring(state.empty_rounds),
        "log=" .. tostring(out_dir) .. "/DoubleLeveller.log",
    }, NL) .. NL)
end

local function begin_round()
    state.scan_round = state.scan_round + 1
    state.regions = collect_regions()
    state.region_index = 1
    state.region_offset = 0
    state.previous = ""
    state.scanned = 0
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
        log(string.format("round %d done: nothing found (empty %d/%d, next try in %ds)",
            round_no, state.empty_rounds, MAX_EMPTY_ROUNDS, wait))
        if state.empty_rounds >= MAX_EMPTY_ROUNDS then
            state.gave_up = true
            state.phase = "gave_up"
            log("giving up: no HellpodRackComponentData table after " .. MAX_EMPTY_ROUNDS ..
                " full rounds. Census written; all scanning stopped.")
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
                    local i = string.find(window, RACK_SIG, from, true)
                    if not i then break end
                    local abs = window_base + i - 1
                    if not is_self(abs) and not state.seen_this_round[abs] then
                        state.seen_this_round[abs] = true
                        local size, why0 = validate_table(abs)
                        local ok, why = false, why0
                        if size then ok, why = try_location(abs, size) end
                        state.census[#state.census + 1] =
                            string.format("0x%X size=%s -> %s", abs, tostring(size), ok and "patched" or tostring(why))
                        if not ok then
                            state.refusals = state.refusals + 1
                            if CONFIG.verbose and why then
                                log(string.format("candidate 0x%X rejected: %s", abs, tostring(why)))
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

-- Keep every known copy patched (a handful of reads per copy, every few seconds).
local function recheck()
    local alive = 0
    for magic_address in pairs(state.tables) do
        local size, why = validate_table(magic_address)
        if not size then
            log(string.format("recheck: table 0x%X is gone (%s)", magic_address, tostring(why)))
            state.tables[magic_address] = nil
        else
            local rack, why2 = resolve_rack(magic_address, size)
            if rack then
                local payload, second = build_slot1(rack)
                if payload == "already" then
                    state.tables[magic_address] = rack
                    alive = alive + 1
                else
                    local ok, why3 = try_location(magic_address, size)
                    if ok then alive = alive + 1
                    else log(string.format("recheck: 0x%X re-patch refused: %s",
                        magic_address, tostring(why3))) end
                end
            else
                log(string.format("recheck: 0x%X no Leveller rack (%s)", magic_address, tostring(why2)))
            end
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
        if state.status_dirty then
            state.status_dirty = false
            pcall(write_status)
        end
        local interval = math.max(60, math.floor(CONFIG.recheck_seconds * 60))
        if (state.frames - (state.last_recheck or 0)) >= interval then
            state.last_recheck = state.frames
            recheck()
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
