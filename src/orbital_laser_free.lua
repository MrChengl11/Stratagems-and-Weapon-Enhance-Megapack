-- HD2-Addon: mods/dsh/orbital_laser_free
--
-- 轨道激光 (Orbital Laser) —— 取消每次任务的次数限制 + 冷却 300 s -> 180 s。
--
-- 数据来源:data/game/generated_stratagem_settings.dl_bin
--   LDLD 块类型 = djb2("StratagemSettings") = 0x30EB6399
--     +0    "LDLD" | version(1) | typeHash | size | is64=1 | 7 字节 pad
--     +24   DLArray { u64 offset, u64 count }   (StratagemSettings 只有一个 ARRAY 成员)
--     +24+offset  StratagemInfo[count], 每条 400 字节
--          +4    u32 id                          唯一标识;轨道激光 = 970450596
--          +80   u32 uses                        次数上限;0xFFFFFFFF = 无限(游戏自己就是这么编码的)
--          +104  f32 cooldown_duration_success   冷却秒数;轨道激光 = 300.0
--
-- 注意 +80 / +104 是**实测值**,不是从这里推出来的:按 typelib 的字段顺序对齐
-- 会把它算成 +100(少算了一个 float),写进去就静默改错了别的字段。这两个偏移
-- 一律由运行时反推,下面的注释只是给你对照日志用。
--
-- 两个数值字段的偏移**不写死**:运行时用一个"整表复现"校验把它推出来 ——
-- 只有唯一一个偏移能让全部 103 条策略同时复现原版数值时才会采用它。
-- 校验不通过就一个字节都不写,只落盘日志和区块转储。
--
-- 前提:必须装 Bingus Shared Loader v15 或更新版本,并且开启 addon 支持。

local state = rawget(_G, "DshOrbitalLaserFree")
if state then return end

state = {
    revision = "orbital-laser-free-v6",
    frames = 0,
    patched = 0,
    refusals = 0,
    phase = "init",
    scan_round = 0,
}
rawset(_G, "DshOrbitalLaserFree", state)

-- ---------------------------------------------------------------- config ----
local CONFIG = {
    enabled         = true,
    recheck_seconds = 5,
    unlimited_uses  = 4294967295,   -- 0xFFFFFFFF,和全部"无限次"策略一样的编码
    cooldown_bits   = 0x43340000,   -- 180.0f 的 IEEE-754 位模式
    cooldown_value  = 180.0,
    min_records     = 40,           -- 至少要认出这么多条策略才敢做整表校验
    max_empty_rounds = 12,          -- 连续这么多轮一个区块都没看到就彻底停手(别一直拖帧)
    max_targets     = 24,           -- 同一张表在内存里可能有多份,最多同时维护这么多
    status_seconds  = 10,           -- STATUS.txt 的心跳间隔(必须定期刷新,不能只在状态变化时写)
    maintain_seconds = 60,          -- 降频维护扫描(20s -> 60s)          -- 多久在"已知区块附近"轻量重扫一次(找新副本)
    deep_seconds    = 0,          -- 0 = 禁用全量周期重扫(消灭每10分钟掉帧半分钟的问题)          -- 多久做一次全量重扫(兜底:副本被搬到别处)
    verbose         = false,
}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then
    print("[OrbitalLaserFree] FFI 不可用,什么也不做")
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
        local candidate = base .. "/Hd2OrbitalLaserFree"
        if kernel.CreateDirectoryA(candidate, nil) ~= 0 or kernel.GetLastError() == 183 then
            out_dir = candidate
        end
    end
end

local NL = string.char(10)
local log_started = false
local function log(line)
    print("[OrbitalLaserFree] " .. line)
    if not out_dir then return end
    local mode = log_started and "a" or "w"
    log_started = true
    local ok, f = pcall(io.open, out_dir .. "/OrbitalLaserFree.log", mode)
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

-- 读 u64。高位过大(>= 2^53)就返回 nil —— Lua 的 number 装不下,绝不能让精度悄悄丢。
local function u64_at(s, i)
    local lo = u32_at(s, i)
    local hi = u32_at(s, i + 4)
    if not lo or not hi then return nil end
    if hi > 0x1FFFFF then return nil end
    return lo + hi * 4294967296
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
local MAGIC             = string.char(0x4C, 0x44, 0x4C, 0x44)   -- "LDLD"
local STRAT_TYPE_HASH   = 0x30EB6399                            -- djb2("StratagemSettings")
local ARRAY_HEADER_OFF  = 24
local RECORD_SIZE       = 400
local OFF_ID            = 4
local TARGET_ID         = 970450596                             -- StratagemType_OrbitalLaser

local STRAT_SIG = MAGIC .. string.char(1, 0, 0, 0) .. string.char(0x99, 0x63, 0xEB, 0x30)

-- 原版数值表:103 条策略 { id = { uses, cooldown_bits } },来自游戏自己的
-- generated_stratagem_settings.dl_bin。它既是"哪条是哪条"的字典(靠 id),
-- 也是整表校验的判据 —— 字段偏移就是靠它反推出来的。
local GROUND = {
    -- 103 条策略:id -> { uses 上限, cooldown_duration_success 的 f32 位模式 }
    [1907808218] = { 4294967295, 0x43F00000 },
    [3353508219] = { 4294967295, 0x43960000 },
    [3843705076] = { 4294967295, 0x43F00000 },
    [1753436707] = { 4294967295, 0x43F00000 },
    [485866824] = { 4294967295, 0x43F00000 },
    [951988742] = { 4294967295, 0x43F00000 },
    [5185868] = { 4294967295, 0x43F00000 },
    [867876502] = { 4294967295, 0x43340000 },
    [2229216190] = { 4294967295, 0x43960000 },
    [2808191861] = { 4, 0x41700000 },
    [4119049995] = { 1, 0x41700000 },
    [1979913877] = { 2, 0x41700000 },
    [1238358532] = { 2, 0x41700000 },
    [2040137691] = { 2, 0x41700000 },
    [1685231450] = { 2, 0x41700000 },
    [3656370131] = { 4, 0x41700000 },
    [3837064536] = { 4294967295, 0x43160000 },
    [3001049275] = { 2, 0x41700000 },
    [929878807] = { 3, 0x41700000 },
    [2281932031] = { 4294967295, 0x42B40000 },
    [2919842659] = { 4294967295, 0x43340000 },
    [12688472] = { 4294967295, 0x43340000 },
    [2742141597] = { 4294967295, 0x43340000 },
    [2239174926] = { 4294967295, 0x43340000 },
    [644090457] = { 4294967295, 0x43340000 },
    [2402590523] = { 4294967295, 0x42F00000 },
    [823976513] = { 4294967295, 0x3F800000 },
    [2186648412] = { 4294967295, 0x41200000 },
    [3928947721] = { 4294967295, 0x41200000 },
    [2319566343] = { 4294967295, 0x41200000 },
    [716273285] = { 4294967295, 0x41200000 },
    [115737856] = { 4294967295, 0x43960000 },
    [3989310204] = { 4294967295, 0x41F00000 },
    [1503060624] = { 4294967295, 0x42F00000 },
    [1606251952] = { 4294967295, 0x42F00000 },
    [1824787072] = { 4294967295, 0x41F00000 },
    [3722314010] = { 4294967295, 0x41F00000 },
    [2720892179] = { 4294967295, 0x41F00000 },
    [685210453] = { 4294967295, 0x41F00000 },
    [650447969] = { 4294967295, 0x41F00000 },
    [1921790255] = { 4294967295, 0x42B40000 },
    [1005987791] = { 4294967295, 0x43340000 },
    [871315230] = { 4294967295, 0x43340000 },
    [509712523] = { 4294967295, 0x43340000 },
    [716088572] = { 4294967295, 0x43340000 },
    [2266266587] = { 4294967295, 0x40C00000 },
    [1695682779] = { 4294967295, 0x41F00000 },
    [3193487269] = { 1, 0x43340000 },
    [3300666223] = { 4294967295, 0x3F800000 },
    [2663642538] = { 1, 0x44960000 },
    [905054095] = { 1, 0x44610000 },
    [1232978203] = { 4294967295, 0x41F00000 },
    [3868299561] = { 1, 0x00000000 },
    [2985177386] = { 4294967295, 0x41700000 },
    [1042447730] = { 4294967295, 0x41A00000 },
    [1426041086] = { 4294967295, 0x41F00000 },
    [3523620028] = { 4294967295, 0x42B40000 },
    [1560416221] = { 4294967295, 0x42C80000 },
    [1280711447] = { 4294967295, 0x42960000 },
    [1063322614] = { 4294967295, 0x43340000 },
    [3193297673] = { 4294967295, 0x42960000 },
    [3108516875] = { 4294967295, 0x43700000 },
    [970450596] = { 3, 0x43960000 },
    [2744472229] = { 4294967295, 0x43520000 },
    [3279813377] = { 4294967295, 0x43700000 },
    [2084654169] = { 4294967295, 0x428C0000 },
    [3713568312] = { 4294967295, 0x42C80000 },
    [2902516083] = { 4294967295, 0x43700000 },
    [1295431756] = { 4294967295, 0x41F00000 },
    [255298804] = { 1, 0x41F00000 },
    [2587901119] = { 1, 0x44160000 },
    [1091253198] = { 1, 0x44160000 },
    [3316399568] = { 1, 0x42B40000 },
    [3275255096] = { 1, 0x42340000 },
    [1567517764] = { 1, 0x44160000 },
    [875551083] = { 4294967295, 0x43F00000 },
    [3343676429] = { 4294967295, 0x43F00000 },
    [458198946] = { 4294967295, 0x43F00000 },
    [14345846] = { 4294967295, 0x43F00000 },
    [3078242205] = { 4294967295, 0x43F00000 },
    [1298599997] = { 4294967295, 0x43F00000 },
    [2822568285] = { 4294967295, 0x43F00000 },
    [2625074523] = { 4294967295, 0x43F00000 },
    [2207713849] = { 4294967295, 0x43F00000 },
    [3413606544] = { 4294967295, 0x428C0000 },
    [2232989803] = { 4294967295, 0x42F00000 },
    [1432571981] = { 4294967295, 0x43F00000 },
    [533318241] = { 4294967295, 0x43F00000 },
    [2007887745] = { 4294967295, 0x43F00000 },
    [2194525688] = { 4294967295, 0x43340000 },
    [3923676543] = { 4294967295, 0x43F00000 },
    [992079466] = { 4294967295, 0x43F00000 },
    [4152191751] = { 4294967295, 0x43F00000 },
    [623391597] = { 4294967295, 0x43160000 },
    [4239785897] = { 4294967295, 0x42B40000 },
    [1582497738] = { 4294967295, 0x43340000 },
    [3085503322] = { 4294967295, 0x43340000 },
    [717707279] = { 4294967295, 0x43160000 },
    [854563507] = { 4294967295, 0x43160000 },
    [863373678] = { 4294967295, 0x40C00000 },
    [2230051894] = { 4294967295, 0x43960000 },
    [295629711] = { 2, 0x44160000 },
    [1290499887] = { 2, 0x44160000 },
}

-- 自身模式串也活在 Lua 堆里,扫描时必然命中自己 —— 取地址并跳过。
local self_address = nil
do
    local ok, p = pcall(function()
        return tonumber(ffi.cast("uintptr_t", ffi.cast("const char *", STRAT_SIG)))
    end)
    if ok and p and p > 0 then self_address = p end
end

local function is_self(address)
    if not self_address then return false end
    local d = address - self_address
    return d > -4096 and d < 4096
end

-- ---------------------------------------------------------------- ingest ----
-- 读一段记录数组,并用"记录里的 id 认不认识"来判定它到底是不是策略表。
-- 这是整套流程里唯一的真相判据:103 个 id 落在 32 位空间里,随机数据几乎不可能命中。
local function load_records(base, count)
    if not base or base < 0x10000 then return nil end
    if count < 1 or count > 2048 then return nil end
    local blob = read_at(base, count * RECORD_SIZE)
    if not blob or #blob ~= count * RECORD_SIZE then return nil end
    local hits = 0
    for i = 0, count - 1 do
        local id = u32_at(blob, i * RECORD_SIZE + 1 + OFF_ID)
        if id and GROUND[id] then hits = hits + 1 end
    end
    if hits * 5 < count * 3 then return nil end      -- 少于 60% 认识 -> 不是这张表
    return blob, hits
end

-- LDLD 的数组描述符在**文件里是相对偏移,在内存里是绝对指针**(FileDiver 的镜像
-- 是文件形态)。所以这里两个解释都试,谁能让记录里的 id 对上号就用谁。
local function ingest_block(magic_address)
    local head = read_at(magic_address, 40)
    if not head then return nil, "unreadable" end
    if head:sub(1, 4) ~= MAGIC then return nil, "not LDLD" end
    local ver  = u32_at(head, 5)
    local typ  = u32_at(head, 9)
    local size = u32_at(head, 13)
    if ver ~= 1 then return nil, "version " .. tostring(ver) end
    if typ ~= STRAT_TYPE_HASH then return nil, string.format("type 0x%08X", typ or 0) end
    if not size or size < 32 or size > 4194304 then return nil, "size " .. tostring(size) end

    local arr = read_at(magic_address + ARRAY_HEADER_OFF, 16)
    if not arr then return nil, "array header unreadable" end
    local f1 = u64_at(arr, 1)      -- {offset} 或 {pointer}
    local f2 = u64_at(arr, 9)      -- {count}
    if not f1 or not f2 then return nil, "array header out of range" end

    local cands = {
        { base = f1,                              count = f2, tag = "abs" },
        { base = magic_address + ARRAY_HEADER_OFF + f1, count = f2, tag = "rel+24" },
        { base = magic_address + f1,               count = f2, tag = "rel+0" },
        { base = f2,                              count = f1, tag = "abs-swapped" },
    }
    local best = nil
    for i = 1, #cands do
        local c = cands[i]
        local blob, hits = load_records(c.base, c.count)
        if blob and (not best or hits > best.hits) then
            best = { base = c.base, count = c.count, blob = blob, hits = hits, tag = c.tag }
        end
    end
    if not best then
        return nil, string.format("没有一种数组解释对得上(f1=0x%X f2=%d size=%d)", f1, f2, size)
    end

    return {
        magic = magic_address,
        base  = best.base,
        count = best.count,
        blob  = best.blob,
        hits  = best.hits,
        tag   = best.tag,
        size  = size,
    }
end

local function collect_records(blocks)
    local out = {}
    for i = 1, #blocks do
        local b = blocks[i]
        for j = 0, b.count - 1 do
            local off = j * RECORD_SIZE + 1
            local id = u32_at(b.blob, off + OFF_ID)
            if id and GROUND[id] then
                out[#out + 1] = {
                    id   = id,
                    blob = b.blob,
                    off  = off,
                    addr = b.base + j * RECORD_SIZE,
                }
            end
        end
    end
    return out
end

-- 从区块里把这个策略的所有副本记录挑出来
local function harvest_targets(blk, out)
    local n = 0
    for j = 0, blk.count - 1 do
        local off = j * RECORD_SIZE + 1
        if u32_at(blk.blob, off + OFF_ID) == TARGET_ID then
            out[#out + 1] = {
                id   = TARGET_ID,
                blob = blk.blob,
                off  = off,
                addr = blk.base + j * RECORD_SIZE,
            }
            n = n + 1
        end
    end
    return n
end

-- ------------------------------------------------------------- detection ----
-- which: 1 = uses, 2 = cooldown bits
-- 目标记录允许已经是打过补丁的值(幂等)。
local function value_ok(rec, cand, which)
    local v = u32_at(rec.blob, rec.off + cand)
    if v == nil then return false end
    if v == GROUND[rec.id][which] then return true end
    if rec.id == TARGET_ID then
        if which == 1 and v == CONFIG.unlimited_uses then return true end
        if which == 2 and v == CONFIG.cooldown_bits then return true end
    end
    return false
end

-- 在 0..396 里找出"得分最高"的字段偏移,返回 best, score, ties。
-- 允许少量离群(舰船模块有可能在载入时改过个别策略的冷却),但要求:
--   * 命中数 >= 90% 的记录
--   * 最高分**唯一**(没有并列),否则一律拒绝
local function detect_offset(records, which)
    local best, best_score, ties, second = nil, -1, 0, -1
    for cand = 0, RECORD_SIZE - 4, 4 do
        local score = 0
        for i = 1, #records do
            if value_ok(records[i], cand, which) then score = score + 1 end
        end
        if score > best_score then
            second = best_score
            best, best_score, ties = cand, score, 1
        elseif score == best_score then
            ties = ties + 1
        elseif score > second then
            second = score
        end
    end
    return best, best_score, ties, second
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
    local okp = kernel.VirtualProtect(ffi.cast("void *", start), span, PAGE_READWRITE, old)
    if okp == 0 then return false, "VirtualProtect failed" end
    local ok = kernel.WriteProcessMemory(process, ffi.cast("void *", address), payload, #payload, written)
    kernel.VirtualProtect(ffi.cast("void *", start), span, old[0], old)
    if ok == 0 then return false, "WriteProcessMemory failed" end
    if written[0] ~= #payload then
        return false, "wrote " .. tostring(written[0]) .. " of " .. #payload
    end
    return true
end

-- 只用于日志:把正整数秒的 float 位模式还原成十进制
local function cd_value_of(bits)
    local sign = 1
    if bits >= 0x80000000 then sign = -1; bits = bits - 0x80000000 end
    local exp = math.floor(bits / 0x800000)
    local mant = bits % 0x800000
    if exp == 0 then return 0 end
    return sign * (1 + mant / 0x800000) * (2 ^ (exp - 127))
end

local function apply_patch(rec)
    if not rec then return false, "no target record" end

    local cur_uses = u32_at(rec.blob, rec.off + state.off_uses)
    local cur_cd   = u32_at(rec.blob, rec.off + state.off_cd)
    if not cur_uses or not cur_cd then return false, "target record unreadable" end

    if cur_uses == CONFIG.unlimited_uses and cur_cd == CONFIG.cooldown_bits then
        state.phase = "patched"
        return true, "already"
    end
    if cur_uses ~= 3 then
        state.refusals = state.refusals + 1
        return false, "uses=" .. tostring(cur_uses) .. ", 期望原版值 3"
    end
    -- 冷却按正整数 float 的位模式比较:30.0f .. 1000.0f
    if cur_cd < 0x41F00000 or cur_cd > 0x447A0000 then
        state.refusals = state.refusals + 1
        return false, string.format("cooldown bits 0x%08X 不在 30..1000 秒区间", cur_cd)
    end

    local target_addr = rec.addr
    local uses_addr = target_addr + state.off_uses
    local cd_addr = target_addr + state.off_cd

    -- 每个地址只备份一次(副本可能有十几份,别互相覆盖)
    state.backed_up = state.backed_up or {}
    if not state.backed_up[target_addr] then
        local full = read_at(target_addr, RECORD_SIZE)
        if full then
            state.backed_up[target_addr] = true
            write_file("original_stratagem_" .. TARGET_ID .. "_" .. string.format("%X", target_addr) .. ".hex",
                string.format("id=%d|record=0x%X|off_uses=%d|off_cd=%d|uses=%d|cooldown_bits=0x%08X",
                    TARGET_ID, target_addr, state.off_uses, state.off_cd, cur_uses, cur_cd) .. NL
                .. to_hex(full) .. NL)
        end
    end

    local okw, err = write_bytes(uses_addr, u32_bytes(CONFIG.unlimited_uses))
    if not okw then
        state.refusals = state.refusals + 1
        log("REFUSED uses write at 0x" .. string.format("%X", uses_addr) .. ": " .. tostring(err))
        return false, err
    end
    local okw2, err2 = write_bytes(cd_addr, u32_bytes(CONFIG.cooldown_bits))
    if not okw2 then
        state.refusals = state.refusals + 1
        log("REFUSED cooldown write at 0x" .. string.format("%X", cd_addr) .. ": " .. tostring(err2))
        return false, err2
    end

    local after = read_at(target_addr, RECORD_SIZE)
    if not after
        or u32_at(after, state.off_uses + 1) ~= CONFIG.unlimited_uses
        or u32_at(after, state.off_cd + 1) ~= CONFIG.cooldown_bits then
        state.refusals = state.refusals + 1
        log("REFUSED verification for record 0x" .. string.format("%X", target_addr))
        return false, "readback mismatch"
    end

    state.patched = state.patched + 1
    state.phase = "patched"
    log(string.format("PATCHED 轨道激光 record 0x%X (id %d)", target_addr, TARGET_ID))
    log(string.format("  uses        +%d : %d -> %d (无限)", state.off_uses, cur_uses, CONFIG.unlimited_uses))
    log(string.format("  cooldown    +%d : %.3f s (0x%08X) -> %.1f s (0x%08X)",
        state.off_cd, cd_value_of(cur_cd), cur_cd, CONFIG.cooldown_value, CONFIG.cooldown_bits))
    return true
end

-- ----------------------------------------------------------- scan driver ----
local SCAN_CHUNK   = 262144     -- 小一点:单次 ReadProcessMemory 的越界开销就小,帧尖峰也小
local SCAN_OVERLAP = 2048
local SCAN_BUDGET  = 0.002      -- 每帧最多 4 ms,配 SCAN_EVERY=2 大约 2 ms/帧
local SCAN_EVERY   = 2
local MAX_BLOCKS   = 48
local MAX_HITS     = 64
local DUMP_BYTES   = 1024       -- 认不出来时每个命中点落盘这么多原始字节,够离线看布局

state.regions = nil
state.region_index = 1
state.region_offset = 0
state.previous = ""
state.blocks = nil
state.seen = nil

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
        if kernel.VirtualQuery(ffi.cast("const void *", address),
                ffi.cast("void *", region), region_size) ~= region_size then break end
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

-- 记住每个区块附近的窗口:维护扫描只扫这些窗口,代价从"整个地址空间"降到几 MB
local function add_watch(magic, size)
    local base = magic - 32768
    if base < 65536 then base = 65536 end
    local stop = magic + size + 32768
    local list = state.watch or {}
    for i = 1, #list do
        local w = list[i]
        if base <= w.base + w.size and stop >= w.base then
            if base < w.base then
                w.size = w.size + (w.base - base)
                w.base = base
            end
            if stop > w.base + w.size then w.size = stop - w.base end
            state.watch = list
            return
        end
    end
    list[#list + 1] = { base = base, size = stop - base }
    state.watch = list
end

local function dump_raw_hits(hits, suffix)
    local out = {}
    for i = 1, math.min(#hits, 12) do
        local a = hits[i]
        out[#out + 1] = string.format("addr=0x%X", a)
        local raw = read_at(a, DUMP_BYTES)
        if raw then out[#out + 1] = to_hex(raw) end
    end
    write_file("strat_blocks_" .. suffix .. ".hex", table.concat(out, NL) .. NL)
end

local function finish_round()
    local blocks = state.blocks or {}
    local hits = state.hits or {}
    local records = collect_records(blocks)
    local census = state.census or {}
    state.blocks = nil
    state.hits = nil
    state.seen = nil
    state.census = nil
    state.census_seen = nil
    state.regions = nil

    state.last_round = string.format(
        "round %d: regions=%d hits=%d blocks=%d records=%d lld_census=%d empty_rounds=%d",
        state.scan_round, state.region_count or 0, #hits, #blocks, #records, #census,
        state.empty_rounds or 0)
    log(string.format("第 %d 轮扫描结束:签名命中 %d 处,%d 个 StratagemSettings 区块,%d 条策略记录",
        state.scan_round, #hits, #blocks, #records))

    -- 签名命中了、却一个区块都解析不出来 —— 表就在那儿,是我们的布局假设不对。
    -- 这种情况立刻停手并落盘原始字节,绝不循环重扫(那是最费帧的做法)。
    if #blocks == 0 and #hits > 0 then
        dump_raw_hits(hits, "round" .. state.scan_round)
        if #census > 0 then
            write_file("lld_census_round" .. state.scan_round .. ".txt", table.concat(census, NL) .. NL)
        end
        state.refusals = state.refusals + 1
        state.phase = "refused"
        log("REFUSED:" .. #hits .. " 处签名命中但都解析不出记录数组;原始字节已落盘,停止扫描")
        return
    end

    -- 一个签名都没命中时,把内存里所有 LDLD 块列出来 —— 这样"什么都没发生"
    -- 也有一条能离线分析的线索,而不是一个哑掉的日志。
    if #blocks == 0 and #census > 0 then
        log("LDLD 普查(共 " .. #census .. " 项):")
        for i = 1, math.min(#census, 40) do log("   " .. census[i]) end
        write_file("lld_census_round" .. state.scan_round .. ".txt", table.concat(census, NL) .. NL)
    end

    if #records < CONFIG.min_records then
        if #blocks > 0 then
            state.refusals = state.refusals + 1
            state.phase = "refused"
            log("REFUSED:只认出 " .. #records .. " 条策略(< " .. CONFIG.min_records .. "),拒绝写入")
            return
        end
        state.empty_rounds = (state.empty_rounds or 0) + 1
        if state.empty_rounds >= CONFIG.max_empty_rounds then
            state.phase = "gave_up"
            log("连续 " .. state.empty_rounds .. " 轮都没有 StratagemSettings 区块,停止扫描(不再拖帧)")
            return
        end
        local delay = math.min(30, 2 ^ state.empty_rounds) * 60
        state.next_round_frame = state.frames + delay
        state.phase = "scanning"
        log(string.format("这一轮没看到区块;约 %d 秒后重扫", math.floor(delay / 60)))
        return
    end

    local u_off, u_score, u_ties, u_second = detect_offset(records, 1)
    local c_off, c_score, c_ties, c_second = detect_offset(records, 2)
    -- 判据刻意留了余量:社区明文 JSON 和当前构建之间会有平衡性改动(实测冷却只
    -- 对上 70/76),所以放宽到 65%,真正的保证来自"最高分必须是第二名的 3 倍以上,
    -- 且并列数为 1" —— 随机/凑巧的偏移给不出这种断层。
    local floor = math.floor(#records * 0.65)
    log(string.format("uses     候选偏移 +%s,命中 %d/%d(第二 %d),并列 %d",
        tostring(u_off), u_score, #records, u_second, u_ties))
    log(string.format("cooldown 候选偏移 +%s,命中 %d/%d(第二 %d),并列 %d",
        tostring(c_off), c_score, #records, c_second, c_ties))

    if not u_off or not c_off or u_ties ~= 1 or c_ties ~= 1
        or u_score < floor or c_score < floor
        or u_score < u_second * 3 or c_score < c_second * 3
        or u_off == c_off then
        local dump = { "blocks=" .. #blocks, "records=" .. #records,
            string.format("uses=+%s score=%d ties=%d second=%d", tostring(u_off), u_score, u_ties, u_second),
            string.format("cooldown=+%s score=%d ties=%d second=%d", tostring(c_off), c_score, c_ties, c_second),
            "floor=" .. floor }
        for i = 1, #blocks do
            local b = blocks[i]
            dump[#dump + 1] = string.format("  block magic=0x%X base=0x%X count=%d size=%d",
                b.magic, b.base, b.count, b.size)
        end
        for i = 1, math.min(#records, 8) do
            dump[#dump + 1] = string.format("  rec id=%d addr=0x%X %s",
                records[i].id, records[i].addr,
                to_hex(records[i].blob:sub(records[i].off, records[i].off + RECORD_SIZE - 1)))
        end
        write_file("refused_dump.txt", table.concat(dump, NL) .. NL)
        state.refusals = state.refusals + 1
        state.phase = "refused"
        log("REFUSED:字段偏移整表校验没过,拒绝写入(转储已落盘)")
        return
    end

    state.off_uses = u_off
    state.off_cd = c_off
    state.records = records

    -- 同一张表在内存里会有多份副本(普查里同类型哈希的块有几十个),而且游戏可能在
    -- 进任务 / 换图时再加载一份新的。**全部收集、全部打**,并且之后持续维护 ——
    -- 只挑第一个正是"一开始生效、过一会儿就失效"的成因。
    local targets = {}
    for i = 1, #records do
        if records[i].id == TARGET_ID then targets[#targets + 1] = records[i] end
    end
    if #targets == 0 then
        state.phase = "refused"
        state.refusals = state.refusals + 1
        log("REFUSED:没找到 id " .. TARGET_ID .. " 的记录")
        return
    end
    if #targets > CONFIG.max_targets then
        log(string.format("找到 %d 个副本,只维护前 %d 个", #targets, CONFIG.max_targets))
    end
    state.targets = {}
    for i = 1, math.min(#targets, CONFIG.max_targets) do state.targets[i] = targets[i] end

    state.watch = {}                       -- 全量扫过一次就重建观察窗口
    for i = 1, #blocks do add_watch(blocks[i].magic, blocks[i].size) end

    state.phase = "located"
    log(string.format("校验通过:uses=+%d, cooldown=+%d,轨道激光记录 %d 份副本",
        state.off_uses, state.off_cd, #state.targets))

    local done = 0
    for i = 1, #state.targets do
        local ok, err = apply_patch(state.targets[i])
        if ok then
            done = done + 1
        else
            log(string.format("副本 0x%X 打补丁失败:%s", state.targets[i].addr, tostring(err)))
        end
    end
    if done == #state.targets then state.phase = "patched" end
end

local function begin_round()
    state.scan_round = state.scan_round + 1
    state.regions = collect_regions()
    state.region_index = 1
    state.region_offset = 0
    state.previous = ""
    state.blocks = {}
    state.hits = {}
    state.seen = {}
    state.census = {}
    state.census_seen = {}
    state.logged_rejections = 0
    state.scanned = 0
    state.region_count = #state.regions
    log(string.format("第 %d 轮:共 %d 个可读内存区", state.scan_round, #state.regions))
end

local function scan_step()
    if not state.regions then
        if state.frames < (state.next_round_frame or 0) then return end
        begin_round()
        return
    end
    local deadline = os.clock() + SCAN_BUDGET
    while os.clock() < deadline do
        local r = state.regions[state.region_index]
        if not r then
            finish_round()
            return
        end
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
                    local i = string.find(window, STRAT_SIG, from, true)
                    if not i then break end
                    local abs = window_base + i - 1
                    if not is_self(abs) and not (state.seen and state.seen[abs]) then
                        if state.seen then state.seen[abs] = true end
                        if state.hits and #state.hits < MAX_HITS then
                            state.hits[#state.hits + 1] = abs
                        end
                        local ok, blk, why = pcall(ingest_block, abs)
                        if ok and blk then
                            if #(state.blocks or {}) < MAX_BLOCKS then
                                state.blocks[#state.blocks + 1] = blk
                                log(string.format("区块 magic=0x%X count=%d hits=%d/%d size=%d via %s",
                                    blk.magic, blk.count, blk.hits, blk.count, blk.size, blk.tag))
                            end
                        elseif CONFIG.verbose or (state.logged_rejections or 0) < 6 then
                            state.logged_rejections = (state.logged_rejections or 0) + 1
                            log(string.format("候选 0x%X 被拒:%s", abs, tostring(why)))
                        end
                    end
                    from = i + 1
                end
                -- 顺带做一份 LDLD 普查(只用诊断,不参与打补丁)
                if state.census and #state.census < 200 then
                    local cfrom = 1
                    while true do
                        local i = string.find(window, MAGIC, cfrom, true)
                        if not i then break end
                        local abs = window_base + i - 1
                        if not is_self(abs) and not (state.census_seen and state.census_seen[abs]) then
                            if state.census_seen then state.census_seen[abs] = true end
                            if #state.census < 200 then
                                local head = read_at(abs, 16)
                                if head and head:sub(1, 4) == MAGIC then
                                    local cv = u32_at(head, 5)
                                    local ct = u32_at(head, 9)
                                    local cs = u32_at(head, 13)
                                    if cv == 1 and ct and cs and cs < 4194304 then
                                        state.census[#state.census + 1] =
                                            string.format("0x%X type=0x%08X size=%d", abs, ct, cs)
                                    end
                                end
                            end
                        end
                        cfrom = i + 1
                    end
                end
                state.previous = buf:sub(-SCAN_OVERLAP)
            else
                state.previous = ""
            end
            state.region_offset = state.region_offset + want
        end
    end
end

-- 逐份复查;被冲掉就重打,读不到就丢掉。任何一份回来了都算活着。
local function recheck()
    local targets = state.targets
    if not targets or #targets == 0 then
        state.phase = "scanning"
        state.regions = nil
        return
    end
    local alive, redone = {}, 0
    for i = 1, #targets do
        local rec = targets[i]
        local cur = read_at(rec.addr, RECORD_SIZE)
        if cur then
            alive[#alive + 1] = rec
            if u32_at(cur, state.off_uses + 1) ~= CONFIG.unlimited_uses
                or u32_at(cur, state.off_cd + 1) ~= CONFIG.cooldown_bits then
                rec.blob = cur                       -- 必须以**当前**字节为准
                rec.off = 1                          -- cur 是"从这条记录开始"读的 400 字节
                local ok, err = apply_patch(rec)
                if ok then
                    redone = redone + 1
                else
                    log(string.format("复查重打失败 0x%X:%s", rec.addr, tostring(err)))
                end
            end
        else
            log(string.format("复查:副本 0x%X 已不可读,丢弃", rec.addr))
        end
    end
    state.targets = alive
    if redone > 0 then log("复查:重新打上 " .. redone .. " 份副本") end
    if #alive == 0 then
        log("所有副本都失效了,重新全量扫描")
        state.phase = "scanning"
        state.regions = nil
    end
end

-- 轻量维护扫描:只扫已知区块附近的窗口(几 MB),用来抓游戏新加载出来的副本
local function maintenance_scan()
    local watch = state.watch
    if not watch or #watch == 0 then return 0 end
    local known = {}
    for i = 1, #(state.targets or {}) do known[state.targets[i].addr] = true end
    local added = 0
    local deadline = os.clock() + 0.002
    for i = 1, #watch do
        if os.clock() >= deadline then break end
        local w = watch[i]
        local off = 0
        while off < w.size do
            if os.clock() >= deadline then break end
            local want = SCAN_CHUNK
            if want > w.size - off then want = w.size - off end
            local buf = read_at(w.base + off, want)
            if buf then
                local from = 1
                while true do
                    local k = string.find(buf, STRAT_SIG, from, true)
                    if not k then break end
                    local abs = w.base + off + k - 1
                    if not is_self(abs) then
                        local ok, blk = pcall(ingest_block, abs)
                        if ok and blk then
                            local tmp = {}
                            if harvest_targets(blk, tmp) > 0 then
                                for j = 1, #tmp do
                                    if not known[tmp[j].addr] then
                                        known[tmp[j].addr] = true
                                        state.targets[#state.targets + 1] = tmp[j]
                                        added = added + 1
                                    end
                                end
                            end
                        end
                    end
                    from = k + 1
                end
            end
            off = off + want
        end
    end
    return added
end

-- 先认 loader。生态里流传的"Requires ... API 1"指的就是 loader 自己上报的 api 等级
-- (Bingus Shared Loader 在 _G.CowboyBingusModLoader 里放 {api=1, version=16},
--  并把自己的首行 banner 写进 BingusSharedLoader.log)。版本不够就**立刻停手**,
-- 而不是继续扫到天荒地老然后让用户以为"在 working"。
local function probe_loader()
    local info = { api = nil, version = nil, source = "none" }
    local l = rawget(_G, "CowboyBingusModLoader")
    if type(l) == "table" then
        info.api = tonumber(l.api)
        info.version = tonumber(l.version)
        info.source = "global"
    end
    if info.api == nil then
        local base = os.getenv("LOCALAPPDATA")
        if base then
            local ok, fh = pcall(io.open, base .. "/CowboyBingus/Helldivers2/Logs/BingusSharedLoader.log", "r")
            if ok and fh then
                local first = fh:read("*l") or ""
                pcall(fh.close, fh)
                local v = first:match("loader%-v(%d+)")
                local a = first:match("API%s+(%d+)")
                if v or a then
                    info.version = tonumber(v) or info.version
                    info.api = tonumber(a) or info.api
                    info.source = "log"
                end
            end
        end
    end
    return info
end

-- 给用户留一份一眼能看懂的状态文件(日志太长,很多人不会看)。
-- 关键:**必须定期刷新**,不能只在状态变化时写 —— 否则收上来一份 "still scanning",
-- 根本分不清是"刚启动 5 秒"还是"卡了 20 分钟"。所以这里带上时间戳、已运行秒数、
-- 轮次和上一轮的扫描结果;判不出结论时也绝不写 "working"。
local function sync_status(force)
    local elapsed = "?"
    if state.t0 and os.time then
        local ok, now = pcall(os.time)
        if ok and now then elapsed = tostring(now - state.t0) end
    end
    local verdict
    if state.phase == "patched" then
        verdict = "OK - patch applied"
    elseif state.phase == "refused" then
        verdict = "FAILED - refused to write (send the log)"
    elseif state.phase == "gave_up" then
        verdict = "FAILED - StratagemSettings table never found (send lld_census_*.txt + log)"
    elseif state.phase == "no_update" then
        verdict = "FAILED - global update() unavailable (Bingus Shared Loader too old?)"
    elseif state.phase == "bad_loader" then
        verdict = "FAILED - Bingus Shared Loader is too old: found API " ..
                  tostring(state.loader and state.loader.api or "?") ..
                  ", this mod needs API 1 (= loader v15 or newer). Update the loader, then restart the game."
    elseif state.phase == "located" then
        verdict = "WORKING - table found, applying the patch"
    else
        verdict = "WORKING - still scanning memory for the table (check elapsed_s; " ..
                  "reading this file right after launch means nothing yet)"
    end
    local stamp = "?"
    if os.date then
        local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
        if ok and s then stamp = s end
    end
    write_file("STATUS.txt", table.concat({
        verdict,
        "revision=" .. tostring(state.revision),
        "updated=" .. stamp .. "  (host local time)",
        "elapsed_s=" .. elapsed,
        "phase=" .. tostring(state.phase),
        "loader=" .. (state.loader
            and ("api=" .. tostring(state.loader.api) .. " version=" .. tostring(state.loader.version)
                 .. " (from " .. tostring(state.loader.source) .. ")")
            or "unknown"),
        "rounds=" .. tostring(state.scan_round or 0),
        "last_round=" .. tostring(state.last_round or "(no full scan round finished yet)"),
        "off_uses=" .. (state.off_uses and ("+" .. tostring(state.off_uses)) or "unknown"),
        "off_cd=" .. (state.off_cd and ("+" .. tostring(state.off_cd)) or "unknown"),
        "copies=" .. tostring(state.targets and #state.targets or 0),
        "patched_writes=" .. tostring(state.patched),
        "refusals=" .. tostring(state.refusals),
        "log=" .. tostring(out_dir) .. "/OrbitalLaserFree.log",
    }, NL) .. NL)
end

local function secs(n) return math.max(30, math.floor(n * 60)) end

local function tick()
    if state.status_phase ~= state.phase then
        state.last_status = state.frames
        state.status_phase = state.phase
        sync_status(true)
    end
    if state.phase == "gave_up" then
        return
    elseif state.phase == "patched" or state.phase == "located" then
        if (state.frames - (state.last_recheck or 0)) >= secs(CONFIG.recheck_seconds) then
            state.last_recheck = state.frames
            if state.phase == "located" then
                local done = 0
                for i = 1, #(state.targets or {}) do
                    local ok, err = apply_patch(state.targets[i])
                    if ok then done = done + 1 else log("重试打补丁失败:" .. tostring(err)) end
                end
                if done > 0 and done == #state.targets then state.phase = "patched" end
            else
                recheck()
            end
        end
        if state.phase == "patched"
            and (state.frames - (state.last_maintain or 0)) >= secs(CONFIG.maintain_seconds) then
            state.last_maintain = state.frames
            local added = maintenance_scan()
            if added > 0 then
                log("维护扫描:新发现 " .. added .. " 份副本")
                local done = 0
                for i = 1, #state.targets do
                    local ok = apply_patch(state.targets[i])
                    if ok then done = done + 1 end
                end
                log(string.format("维护扫描后共 %d 份副本,成功 %d", #state.targets, done))
            end
        end
        if state.phase == "patched"
            and CONFIG.deep_seconds and CONFIG.deep_seconds > 0
            and (state.frames - (state.last_deep or 0)) >= secs(CONFIG.deep_seconds) then
            state.last_deep = state.frames
            log("定期全量重扫(兜底:副本可能被搬到别的地方)")
            state.phase = "scanning"
            state.regions = nil
        end
    elseif state.phase ~= "refused" then
        scan_step()
    end
end

state.t0 = os.time and os.time() or nil
state.loader = probe_loader()
state.phase = "scanning"

if state.loader.api ~= nil and state.loader.api < 1 then
    state.phase = "bad_loader"
    log(string.format("REFUSED: 检测到的 Bingus Shared Loader API = %d,本 mod 需要 API 1。",
        state.loader.api))
    if state.loader.version then
        log(string.format("  检测到的 loader 版本: v%d(来源:%s)", state.loader.version, state.loader.source))
    end
    log("  请升级 Bingus Shared Loader 到 v15 或更新版本,然后完全退出游戏再重开。")
    log("  版本不够的话本 mod 不会扫描、不会写内存。")
    pcall(function() sync_status(true) end)
    return { revision = state.revision, state = state }
end
if state.loader.api == nil then
    log("警告:没能确认 Bingus Shared Loader 的 API 等级(global 缺失、日志也读不到),继续尝试。")
end

local original_update = update
if type(original_update) == "function" then
    local my_update
    my_update = function(...)
        state.frames = state.frames + 1
        local cadence = (state.phase == "patched") and 60 or SCAN_EVERY
        if not state.retired and CONFIG.enabled and state.frames >= 120 and (state.frames % cadence) == 0 then
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
    log("全局 update 不可用,无法运行")
end
pcall(function() sync_status() end)

return { revision = state.revision, state = state }
