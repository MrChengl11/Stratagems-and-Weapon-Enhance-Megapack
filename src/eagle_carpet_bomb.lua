-- HD2-Addon: mods/dsh/eagle_carpet_bomb
--
-- 飞鹰地毯式空袭 (Eagle Carpet Bombing Run)
-- 把箭头隐藏/没有发布的战备 "CARPET BOMB" (StratagemType_CarpetBomb, id 905054095) 放出来,
-- 并且用**飞鹰战机**补上那条被删掉的投放载具。
--
-- 数据来源(全部来自游戏自己的明文数据表,没有编造值):
--   generated_stratagem_settings.dl_bin   LDLD 类型 djb2("StratagemSettings") = 0x30EB6399
--       +0  "LDLD" | ver(1) | typeHash | size | is64=1 + 7B pad        (24 字节)
--       +24 DLArray { u64 ptr, u64 count }  -> 记录数组(内存里 ptr 是绝对地址)
--       +40 StratagemSettings[count],每条 400 字节
--            +4   u32 id
--            +80  u32 uses                          (0xFFFFFFFF = 无限)
--            +104 f32 cooldown_duration_success
--          其余字段偏移**不写死**,运行时用"整表复现"校验反推。
--
--   generated_entities.dl_bin             LDLD 类型 djb2("EagleComponentData") = 0x556FF68B
--       +24 ComponentIndexData[A] { u64 entityHash, u32 index, u32 pad }
--       +24+A*16 EagleComponent[N],每条 152 字节
--
-- 关于"3 架飞鹰":
--   原版这条战备的打击实体 0x6CCB976676EF6CC6 用的是 shuttle_transport(运输艇)模型,
--   箭头把它整个删掉了(该 payload 哈希在内存里查无此物)。照要求改用飞鹰:
--   把仍然存在、但没有任何战备在用的 "EAGLE (NOT USED) AIR-TO-AIR MISSILES" 打击实体
--   0xDFBB9A0D8FA27D85 (unit = content/fac_helldivers/vehicles/eagle/eagle.bones)
--   改造成地毯式轰炸机,并把 CARPET BOMB 的 payload 指过去。
--   要 3 架就再把 payload 数组由 1 项扩到 3 项;这一步带严格安全检查,检查不过自动退回 1 架。
--
-- 前提:Bingus Shared Loader v15 或更新(API 1)。只装 loader 一个,不需要别的。
-- 提醒:客户端本地内存改动。联机时队友界面里看不到这条战备;效果是否同步取决于房主,
--       建议先单人试。移除 addon / 禁用 mod 即可完全还原。

local state = rawget(_G, "DshEagleCarpetBomb")
if state then return end

state = {
    revision = "eagle-carpet-bomb-v1",
    frames = 0,
    patched = 0,
    refusals = 0,
    phase = "init",
    scan_round = 0,
    flight = 0,
    flight_reason = "n/a",
}
rawset(_G, "DshEagleCarpetBomb", state)

-- ---------------------------------------------------------------- config ----
local CONFIG = {
    enabled             = true,

    -- ===== 战备层 =====
    enable_stratagem    = true,     -- selectable 0 -> 1,让它出现在战备列表
    make_ship_available = true,     -- origin_type ClanStation -> ShipSpecific
    individual_cooldown = true,     -- cooldown_type SharedClan -> Individual
    -- 借壳:把一条**你已经解锁、已经在列表里**的战备原地改造成地毯式轰炸。
    -- 为什么必须这么做:把社区仓库 1573 个数据文件全 grep 过,**游戏数据里没有任何
    -- "玩家已解锁战备列表"** —— 战备选择界面的条目来自账号解锁状态,只把 selectable 打开不够。
    -- 默认借"飞鹰烟幕"(1685231450);设成 0 就关掉。
    --   其他候选:1238358532 飞鹰空袭 / 2040137691 飞鹰凝固汽油 / 3656370131 飞鹰集束
    hijack_id           = 1685231450,
    -- ★ 鹰系挂架(additional_stratagem = StratagemType_EagleRearm)。
    --   它决定"次数用完之后能不能回舰装填":
    --     挂着   -> 游戏按鹰系战备处理:次数用完 -> 飞鹰回舰装填 -> 次数补满,和其它飞鹰一样
    --     摘掉   -> 用一次进真正的冷却,但**次数用完就永久消失**(实测:两次之后点不动)
    --   早期为了把卡面数字改成"真冷却"把它摘了,代价就是不能补 —— 现在按需求装回去。
    eagle_rearm         = true,
    eagle_rearm_type    = 48,       -- StratagemType_EagleRearm
    -- 冷却(秒)—— 卡面显示值。原版地毯是 900,现按需求"和别的飞鹰一样"。
    -- 标定依据(用户舰船实测):飞鹰空袭 / 集束 / 500kg 的记录里 cooldown_duration_success
    -- 都是 15,卡面都显示 9 -> 只要卡面写 9,反算出来的基础值就是 15,**和别的飞鹰逐位相同**。
    cooldown_seconds    = 9,
    -- 舰船升级修正:游戏会在卡面上把基础值再乘一个系数(受你已买的鹰系模块影响)。
    -- 想让**卡面显示**正好等于 cooldown_seconds,就把观测到的系数填进来:
    --   实测卡面 174s / 基础 300s -> 系数 0.58 -> 这里填 0.58,mod 会反算基础值写进去。
    -- 填 1.0 = 不反算(卡面显示的就是被升级改过的值)。
    -- 舰船升级修正系数 = 卡面显示 ÷ 记录里的基础值。
    -- 实测标定(用户舰船):
    --   飞鹰空袭/集束/500kg 的基础 cooldown_duration_success 都是 15,卡面都显示 9  -> 9/15 = 0.60
    --   次数:三条都是"基础 + 1"(1->2、2->3、4->5),这是另一套模块,本 mod 不碰。
    -- 想改目标显示冷却,只改 cooldown_seconds;要重标定就用"卡面值 ÷ 基础值"。
    upgrade_factor      = 0.60,
    copy_eagle_icon     = true,     -- 图标:这条战备的 icon 被箭头清成了 0,抄一个现成的
    fix_description     = true,     -- 描述:它的 description 字符串键在当前构建里已经不存在了,
                                    --       改指到 2253302537 —— 现成的
                                    --       "A barrage of bombs creating a non-targeted carpet of explosions."
    description_key     = 2253302537,

    -- ===== 投放层 =====
    flight_size         = 3,        -- 1 = 忠实还原;3 = 三架飞鹰
    -- 借谁的 payload 数组来放 3 架(地毯式空袭自己的数组只有 1 项,且后面不是空白,不能原地扩)。
    -- 默认借 [TUTORIAL] EXTRACTION:只在教学关用,而且它的 payload 数组正好 3 个槽位。
    --   2230051894 = StratagemType_Tutorial_Extract(3 项)
    --   867876502  = StratagemType_AmmoRack / 补给(6 项)——别用,那是正常玩法要用的
    donor_payload_id    = 2230051894,
    -- ★ 优先直接写"战备自己的 payload 数组"(把 1、2 号槽位填成鹰的装载物)。
    -- 这是社区大佬验证过的路子:三架飞鹰会**一排**出来。关掉它就退回备选路线(借数组/原地扩容)。
    prefer_own_array    = true,

    -- ===== 投放层(数值尽量贴 2024-06 快照里"被删掉的那条地毯实体"的原版配方)=====
    -- 原版配方(analysis/27_carpet.py 可复现,来源 shalzuth/HelldiversData@5bccca12eb):
    --   payload=CarpetBombing  pattern=6Z  projectile=Bomb_200kg  target_angle=90
    --   search_radius=50  fire_duration=2  bomb_interval=0.5  attack_movespeed=75
    --   approach_distance=750  approach_height=750  strafing_run_length=30  fire_distance=1000
    --   num_angles_to_try=0  num_heights_to_try=0(固定进场角度)
    -- ★ 地毯几何(由实机现象反推出的模型):
    --     地毯长度 ≈ attack_movespeed × fire_duration
    --     投弹起点 ≈ 距战备球 strafing_run_fire_distance 米,沿进场方向往前铺开
    --   => 想让**战备球落在正中**,起点就该在球前方"半个地毯长度"处。
    --   之前是 200 m/s + 300m 起点:地毯被拉长到几百米、整体又落在球前方 300m —— 就是"落点不对"。
    -- 弹头。按名字在**当前构建**的射弹表里查(枚举下标会被版本回收,别抄社区表):
    --   237 = "500kg BOMB"   <- 现在用的。重量 500,爆炸 expOnImpact=189 / expExpire=272
    --   192 = "200KG BOMB"   (原规格;重量 200,爆炸 expOnImpact=178)
    --   170 = "100KG BOMB"   (飞鹰空袭在用)
    -- 交叉验证:当前构建里飞鹰 500kg 打击实体自己的 projectile_type 字段就是 237 ✓
    projectile_type     = 237,      -- ★ 只作为**兜底**:运行时按 name_upper 反查会覆盖它
    -- ★ 枚举下标会被版本回收(技能文档 6.26):同一台机器上实测 ProjectileType 201 在
    --   旧构建是爆弹手枪弹头、更新后变成了另一个完全不同的射弹。所以写死的 237 不可信。
    --   改成运行时到**活的** ProjectileSettings 表里按 name_upper(本地化键哈希,跨构建稳定)反查:
    resolve_warhead       = true,   -- 关掉就退回旧行为(直接用上面写死的 projectile_type)
    warhead_max_rounds    = 8,      -- 前 8 轮按 20 秒节奏快速试
    warhead_retry_seconds = 20,     -- 两轮之间等多久(表是分批加载的)
    warhead_slow_retry_seconds = 120, -- 8 轮之后**不放弃**:表通常要进任务才常驻,放慢节奏继续试
    run_length          = 150.0,    -- strafing_run_length:轰炸走廊长度(米)。原版 30;规格要 150
    search_radius       = 50.0,     -- search_radius:目标搜索半径(米)。原版地毯就是 50 ✓
    -- 投弹窗口。地毯长度 = move_speed × fire_duration = 75 × 2 = 150 米 ✓ 规格
    fire_duration       = 2.0,      -- 原版地毯 2.0(正常飞鹰是 1.5)
    bomb_interval       = 0.03,     -- 手动投弹间隔(秒);target_bombs > 0 时会被自标定覆盖
    -- ★ 自标定:写"这一发一共想要多少枚炸弹",间隔按**投弹窗口 ÷ 弹数**反算。
    --   窗口默认 = fire_duration(0 = 用 fire_duration)。
    target_bombs        = 60,
    bomb_window         = 0,        -- 投弹窗口(秒);0 = 用 fire_duration
    -- ★ 实机标定:引擎对一次呼叫**实际上只飞 1 架**(payload 数组写 3 项也只出 1 架),
    --   所以投弹间隔必须按 1 架反算,才能让这一架把 60 发全投完。
    --   填 0 或 nil = 按 flight_size 反算(旧行为:3 架 -> 每架 20 发 -> 实机只投 20 发)。
    bomb_planes         = 1,
    flyby_distance      = 500.0,
    approach_distance   = 600.0,    -- 原版地毯是 750;拉近一点,飞机进场更快也更清楚
    approach_height     = 300.0,    -- 原版 750。压低到 300m 才是"贴脸低空掠过"
    -- ★ 原版地毯自己的速度就是 75(正常飞鹰是 300)。它决定了地毯长度(速度 × 窗口),
    --   改成 200 会把地毯拉长 2.7 倍 —— 这是"落点不对"的一半原因。慢一点反而看得更清楚。
    move_speed          = 75.0,
    acceleration        = 50.0,
    deceleration        = 75.0,
    -- ★ 关键:飞机"离目标多远开始投弹"(= 地毯的起点)。原版地毯写的是 1000m —— 那是条
    --   没发布的半成品配方,1000 米外就把弹放光,落点这边只看见炸弹、看不见飞机。
    --   要让战备球落在**正中**,起点 = 半个地毯长度 = 150/2 = 75 米。
    --   调大 = 整条地毯往球前方平移;调小 = 往球后方平移。
    fire_distance       = 75.0,
    -- 呼叫时间(秒):对标飞鹰空袭那条记录里 +92 那个 10.0(全表只有空袭有值,其余都是 0)
    call_in_time        = 10.0,

    -- ===== 运行参数 =====
    recheck_seconds     = 5,
    -- 全字段复查间隔: 0 禁用定期重跑, 避免稳态下耗时重新解析103条战备
    sweep_seconds       = 0,
    status_seconds      = 10,
    maintain_seconds    = 10,       -- 飞鹰表搜寻重试间隔(秒);找到后 eagle_found=true 永久休眠
    deep_seconds        = 0,         -- 0 = 禁用全量周期重扫(消灭每10分钟掉帧半分钟的问题)
    -- 这只是"这看起来是张真表吗"的地板值,不是构建常量:真正的把关是
    -- load_records 的"id 命中率 >= 60%" + 偏移反推的"断层"判据 + CARPET BOMB 指纹。
    -- 原来写 40(等于半个表 148/2=74 的门槛)会让"只扫到一半副本"这种轮次更接近被拒。
    min_records         = 24,
    max_empty_rounds    = 12,
    verbose             = false,

    -- ===== 抗漂移:扫描节奏 =====
    expand_seconds      = 0,        -- 0 = 禁用周期全量补扫(消灭每20秒一轮的重扫卡顿)
    max_expand_rounds   = 0,
    region_refresh_sec  = 10,       -- 单轮扫描中途重新收集 region 列表的间隔(抓新分配的内存区)
    min_region_bytes    = 16384,    -- 小于它的 region 不扫(最大那个区块约 19KB;原来写 64KB 会漏)
    need_log_limit      = 64,       -- "为什么需要重打"的诊断上限(每个副本一次)
}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi or not ffi then
    print("[EagleCarpetBomb] FFI 不可用,什么也不做")
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
        local candidate = base .. "/Hd2EagleCarpetBomb"
        if kernel.CreateDirectoryA(candidate, nil) ~= 0 or kernel.GetLastError() == 183 then
            out_dir = candidate
        end
    end
end

local NL = string.char(10)
local log_started = false
local function log(line)
    print("[EagleCarpetBomb] " .. line)
    if not out_dir then return end
    local mode = log_started and "a" or "w"
    log_started = true
    local ok, f = pcall(io.open, out_dir .. "/EagleCarpetBomb.log", mode)
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
    if not address or address < 0x10000 then return nil end
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

local function u64_at(s, i)
    local lo = u32_at(s, i)
    local hi = u32_at(s, i + 4)
    if not lo or not hi then return nil end
    if hi > 0x1FFFFF then return nil end   -- 超出 2^53 一律当"读不到",绝不丢精度
    return lo + hi * 4294967296
end

local function u32_bytes(v)
    v = v % 4294967296
    return string.char(v % 256, math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- 指针这类 < 2^53 的整数照样能精确拆成 8 字节
local function u64_bytes(v)
    local lo = v % 4294967296
    local hi = math.floor(v / 4294967296)
    return u32_bytes(lo) .. u32_bytes(hi)
end

local function f32_bytes(x)
    if x == 0 then return u32_bytes(0) end
    local neg = false
    if x < 0 then neg = true; x = -x end
    local exp = 0
    while x >= 2 do x = x / 2; exp = exp + 1 end
    while x < 1 do x = x * 2; exp = exp - 1 end
    local mant = math.floor((x - 1) * 8388608 + 0.5)
    if mant >= 8388608 then mant = 0; exp = exp + 1 end
    local bits = (exp + 127) * 8388608 + mant
    if neg then bits = bits + 2147483648 end
    return u32_bytes(bits)
end

local function f32_bits(x)
    return u32_at(f32_bytes(x), 1)
end

-- IEEE-754 单精度解码,只用于回读校验 —— 绝不能用同一个编码器去验证自己
local function f32_from_bits(bits)
    local sign = 1
    if bits >= 0x80000000 then sign = -1; bits = bits - 0x80000000 end
    local exp = math.floor(bits / 0x800000)
    local mant = bits % 0x800000
    if exp == 0 then return 0 end
    if exp == 255 then return sign * math.huge end
    return sign * (1 + mant / 0x800000) * (2 ^ (exp - 127))
end

-- 启动自检:编码器/解码器对不上就什么都不做(而不是写一堆垃圾进内存)
local function selftest_f32()
    local known = { [0.0] = 0x00000000, [1.0] = 0x3F800000, [1.5] = 0x3FC00000,
                    [50.0] = 0x42480000, [75.0] = 0x42960000, [150.0] = 0x43160000,
                    [750.0] = 0x443B8000, [1000.0] = 0x447A0000 }
    for v, bits in pairs(known) do
        if f32_bits(v) ~= bits then return false, string.format("%g -> 0x%08X 期望 0x%08X", v, f32_bits(v), bits) end
        local back = f32_from_bits(bits)
        if math.abs(back - v) > 0.001 then return false, string.format("解码 %g -> %g", v, back) end
    end
    return true
end

local function to_hex(s)
    local parts = {}
    for i = 1, #s do parts[i] = string.format("%02x", s:byte(i)) end
    return table.concat(parts)
end

-- >2^53 的 64 位 ID 一律用字节串,绝不过 Lua number
local function hex_le(hex)
    local s = (hex:gsub("%x%x", function(p) return string.char(tonumber(p, 16)) end))
    return s:reverse()
end

-- -------------------------------------------------------------- constants ---
local MAGIC            = string.char(0x4C, 0x44, 0x4C, 0x44)
local STRAT_TYPE_HASH  = 0x30EB6399
local EAGLE_TYPE_HASH  = 0x556FF68B
local ARRAY_HEADER_OFF = 24
local RECORD_SIZE      = 400
local OFF_ID           = 4
local EAGLE_RECSIZE    = 152

local STRAT_SIG = MAGIC .. string.char(1, 0, 0, 0) .. string.char(0x99, 0x63, 0xEB, 0x30)
local EAGLE_SIG = MAGIC .. string.char(1, 0, 0, 0) .. string.char(0x8B, 0xF6, 0x6F, 0x55)

local CARPET_ID          = 905054095
local CARPET_OLD_PAYLOAD = "6CCB976676EF6CC6"      -- 已删除的 shuttle_transport 打击实体
local CARPET_ICON_HEX    = "8A0D47AA05EAFBC1"      -- 原版 CARPET BOMB 的图标哈希(旧构建里的值)
local CARPET_DESC_KEY    = 692079485                    -- 原版 CARPET BOMB 的 description 键(当前构建里已无此字符串)
-- 下面两个偏移来自实机 dump 的逐字段对齐(enabled@192 是 byte,max_in_loadout@204 已由整表复现确认):
local OFF_CALL_IN        = 92                           -- 未在组件表里列出的一个 float,全表只有飞鹰空袭是 10.0
local OFF_DEPENDS_ON     = 196                          -- depends_on (enum)
local OFF_ADDL_STRAT     = 200                          -- additional_stratagem (enum)
-- 三架飞鹰 = 三个**不同**的打击实体哈希(同一个哈希重复三次引擎只生成一架)。
-- 这三个都是"没有任何可选战备在引用"的现役飞鹰实体:
--   0xDFBB9A0D8FA27D85  EAGLE (NOT USED) AIR-TO-AIR MISSILES
--   0x0BD0F9D59048E9D1  (双倍扫射用,没有任何战备引用)
--   0xDBB286AD7ED9DF96  (没有任何战备引用)
-- ★ 社区大佬指路:用"**常规飞鹰战备的装载物**",而不是自造的没人用的实体。
-- 0x1B3BCADABC7EF8D6 = 飞鹰烟幕那台鹰的 payload 实体 —— 而烟幕的槽位已经被我们借壳占用了,
-- 所以它现在没有任何战备在用,正好当"常规飞鹰装载物"。
-- (之前用另外两个"没人引用"的实体时只出来一架 —— 很可能就是它们的 package 从没被加载过、刷不出来。)
local EAGLE_STRIKE_HEX   = "1B3BCADABC7EF8D6"
local EAGLE_STRIKE_HEXES = { "1B3BCADABC7EF8D6", "DFBB9A0D8FA27D85", "0BD0F9D59048E9D1" }
local EAGLE_PKG_HEX      = "4E381ABCE2D425E8"      -- packages/generated/loadout/eagle_missile.package
local EAGLE_AIRSTRIKE_ID = 1238358532

local ZERO8              = string.rep(string.char(0), 8)
local CARPET_OLD_BYTES   = hex_le(CARPET_OLD_PAYLOAD)
local CARPET_ICON_BYTES  = hex_le(CARPET_ICON_HEX)
local EAGLE_STRIKE_BYTES = hex_le(EAGLE_STRIKE_HEX)
local STRIKE_BYTES = {}
for i = 1, #EAGLE_STRIKE_HEXES do STRIKE_BYTES[i] = hex_le(EAGLE_STRIKE_HEXES[i]) end

-- 借来的数组里要写的 N 份:优先用不同的哈希,不够就循环
local function strike_payload_bytes(n)
    local out = {}
    for i = 1, n do out[i] = STRIKE_BYTES[((i - 1) % #STRIKE_BYTES) + 1] end
    return table.concat(out)
end

local function is_our_strike(bytes)
    for i = 1, #STRIKE_BYTES do
        if bytes == STRIKE_BYTES[i] then return true end
    end
    return false
end
local EAGLE_PKG_BYTES    = hex_le(EAGLE_PKG_HEX)

local CD_BITS = nil                -- 目标冷却的 f32 位模式,init 时按 CONFIG.cooldown_seconds 算
-- 引擎音效(偏移由实机 dump 对齐确认:+132 启动 / +136 停止 / +144 音爆)。
-- 取"集群炸弹"那套(2575235296 / 3256338444)——同一份资源、确实存在,听感更接近连续投弹。
local EAGLE_AUDIO_START  = 2575235296
local EAGLE_AUDIO_STOP   = 3256338444
-- 按实际架数反算投弹间隔,让总弹数落在 target_bombs 附近
local function bomb_interval_for(flight)
    if not CONFIG.target_bombs or CONFIG.target_bombs <= 0 then return CONFIG.bomb_interval end
    local planes = CONFIG.bomb_planes
    if not planes or planes <= 0 then planes = flight end
    planes = math.max(1, planes or 1)
    local per_plane = CONFIG.target_bombs / planes
    -- 投弹窗口:默认就是 fire_duration(地毯长度 = move_speed × 窗口)
    local win = CONFIG.bomb_window
    if not win or win <= 0 then win = CONFIG.fire_duration end
    if not win or win <= 0 then win = 2.0 end
    local iv = win / per_plane
    if iv < 0.02 then iv = 0.02 end
    if iv > 1.0 then iv = 1.0 end
    return iv
end

local EAGLE_PAYLOAD_CARPET = 6      -- EaglePayload_CarpetBombing

-- ================= 弹头:ProjectileSettings 按 name_upper 反查 =================
-- 为什么要反查:枚举下标会被版本回收。写死的 id 一旦失效,引擎拿到无效射弹 ->
-- **炸弹一颗都生成不出来**(实机现象:飞机起飞了、弹头不落地)。
-- name_upper 是本地化键的哈希,与构建无关,所以拿它当锚点。
local PROJ_TYPE_HASH = 0xBD4042C2                     -- djb2("ProjectileSettings")
local PROJ_SIG = MAGIC .. string.char(1, 0, 0, 0) .. string.char(0xC2, 0x42, 0x40, 0xBD)
local PROJ_DESC_OFF = 24                              -- +24 起是 16 字节 DLArray 描述符
local PROJ_REC_MIN, PROJ_REC_MAX = 32, 65536
local PROJ_STRIDE_MIN, PROJ_STRIDE_MAX = 64, 4096
-- ProjectileInfo 记录内的字段偏移(纯 Lua 解码出来的,离线旧构建真表逐条核对过)
local P_ID, P_NAME, P_CALIBRE = 0, 4, 24
local P_SPEED, P_MASS, P_DRAG, P_GRAV = 32, 36, 40, 44
local P_DAMAGE, P_EXPL_IMPACT = 60, 144
-- "500kg BOMB" 的身份。
-- ★ 构建漂移(实机 20:21 这次实测):DamageInfoType / explosion 枚举**会**漂移 ——
--   同一台机器同一次更新后,15x100mm 家族的 damage id 从 144 变成了 149。
--   500kg 的候选记录因此只拿到 10/16,掉的正好是 damage(3)+expl(3) 那 6 分,
--   于是判据把**本来正确的记录**拒了(日志:"这张表没用: 最高分只有 10/16")。
--   所以判据重新分层:
--     * name_upper —— 主键,本地化键哈希,跨构建稳定,**必须**命中;
--     * 物性 speed/mass/calibre/drag/gravity —— **硬判据**;
--     * damage / explosion —— 只当**弱提示**,漂移了也不影响结论。
local WARHEAD_NAME = 0x3D40F1F6
local WARHEAD_IDENT = { speed = 500.0, mass = 500.0, calibre = 50.0, drag = 0.5, grav = 1.0 }
local WARHEAD_HINT  = { damage = 245, expl = 189 }
local WARHEAD_PHYS_TOTAL = 5
local WARHEAD_PHYS_MIN   = 4      -- 5 项物性至少中 4 项
-- 满分 = 物性 3+3+2+1+1 = 10,再加两个弱提示各 1 = 12
local WARHEAD_SCORE_MAX = 12
local WARHEAD_SCORE_MIN = 9       -- 物性满 10 分里的 9 分;两个弱提示全丢也照样过
local WARHEAD_BUDGET = 0.004
local EAGLE_PATTERN_6Z     = 0      -- EagleAirstrikePattern_6Z

-- 原版数值表:id -> { uses, cooldown_bits, selectable(u32列,已不用), origin_type, cooldown_type,
--                    max_in_loadout, cost, payload_count, mission_specific, selectable, triggers_war }
-- 注意最后三项在游戏里是 **byte**(见社区 data/components/StratagemInfo.json:
--   mission_specific: byte / selectable: byte / triggers_war: byte),三个连续字节,
--   所以必须按字节比、按字节写 —— 用 u32 读它们永远读不对。
-- 既是"哪条是哪条"的字典,也是整表复现校验的判据。
local GROUND = {
    -- 103 条战备:id -> { uses, cooldown_bits, selectable(u32), origin_type, cooldown_type,
    --                  max_in_loadout, cost, payload_count,
    --                  mission_specific(byte), selectable(byte), triggers_war(byte), description }
    [5185868] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1310660946 },   -- StratagemType_Drone_GASPROJECTOR
    [12688472] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3253166361 },   -- StratagemType_MineDeployer
    [14345846] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 781284349 },   -- StratagemType_LightMachinegun
    [115737856] = { 4294967295, 0x43960000, 0, 0, 1, 0, 0, 1, 1, 0, 0, 4118375536 },   -- StratagemType_Extract
    [255298804] = { 1, 0x41F00000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 323223727 },   -- StratagemType_HealthPackRack_PresidentReward
    [295629711] = { 2, 0x44160000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1244754797 },   -- StratagemType_DropoffCombatWalker
    [458198946] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1385974777 },   -- StratagemType_Machinegun
    [485866824] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 4200594030 },   -- StratagemType_DroneMG
    [509712523] = { 4294967295, 0x43340000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 3051942155 },   -- StratagemType_ImmediateExtractionBeacon
    [533318241] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2064918640 },   -- StratagemType_Heavy_Mg
    [623391597] = { 4294967295, 0x43160000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 150097484 },   -- StratagemType_TurretMachinegun
    [644090457] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 763226325 },   -- StratagemType_MineDeployer_GasMines
    [650447969] = { 4294967295, 0x41F00000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 4044431460 },   -- StratagemType_SeismicProbe
    [685210453] = { 4294967295, 0x41F00000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 121536852 },   -- StratagemType_ProspectingDrill
    [716088572] = { 4294967295, 0x43340000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 145883417 },   -- StratagemType_EmergencyExtractionBeacon
    [716273285] = { 4294967295, 0x41200000, 0, 0, 0, 0, 1, 1, 1, 0, 0, 397482148 },   -- StratagemType_DrillingCharge
    [717707279] = { 4294967295, 0x43160000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1776173825 },   -- StratagemType_TurretRocket
    [823976513] = { 4294967295, 0x3F800000, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0 },   -- StratagemType_ShipBowling
    [854563507] = { 4294967295, 0x43160000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 587865164 },   -- StratagemType_TurretAutocannon
    [863373678] = { 4294967295, 0x40C00000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 1413448488 },   -- StratagemType_Tutorial_ReinforcementBeacon
    [867876502] = { 4294967295, 0x43340000, 0, 0, 1, 0, 1, 6, 1, 0, 0, 2806852005 },   -- StratagemType_AmmoRack
    [871315230] = { 4294967295, 0x43340000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 145883417 },   -- StratagemType_ExtractionBeacon
    [875551083] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 847218420 },   -- StratagemType_AutomaticCannon
    [905054095] = { 1, 0x44610000, 0, 2, 2, 1, 5, 1, 1, 0, 1, 692079485 },   -- StratagemType_CarpetBomb
    [929878807] = { 3, 0x41700000, 0, 0, 0, 0, 1, 1, 1, 0, 1, 2285331910 },   -- StratagemType_EagleStrafe
    [951988742] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1177236491 },   -- StratagemType_Drone_Laser_Rifle
    [970450596] = { 3, 0x43960000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1202939756 },   -- StratagemType_OrbitalLaser
    [992079466] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 4158786502 },   -- StratagemType_ArcThrower
    [1005987791] = { 4294967295, 0x43340000, 0, 0, 0, 0, 0, 2, 1, 0, 0, 1857062393 },   -- StratagemType_Scrambler
    [1042447730] = { 4294967295, 0x41A00000, 0, 0, 0, 0, 0, 2, 1, 0, 0, 1622894175 },   -- StratagemType_DarkFluidBackpack
    [1063322614] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 905887718 },   -- StratagemType_OrbitalStrike
    [1091253198] = { 1, 0x44160000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 3613714996 },   -- StratagemType_MedicBackpack_PresidentReward
    [1232978203] = { 4294967295, 0x41F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 3764280239 },   -- StratagemType_RemoteExplosives
    [1238358532] = { 2, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2253302537 },   -- StratagemType_EagleAirstrike
    [1280711447] = { 4294967295, 0x42960000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 968200865 },   -- StratagemType_OrbitalStun
    [1290499887] = { 2, 0x44160000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3085604271 },   -- StratagemType_DropoffCombatWalker_Autocannon
    [1295431756] = { 4294967295, 0x41F00000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 2806852005 },   -- StratagemType_AmmoRack_PresidentReward
    [1298599997] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3192210987 },   -- StratagemType_Recoilless
    [1426041086] = { 4294967295, 0x41F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 478919492 },   -- StratagemType_TCS03Thumper
    [1432571981] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3579339289 },   -- StratagemType_Flamethrower
    [1503060624] = { 4294967295, 0x42F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 3122737775 },   -- StratagemType_DropoffBugPlug
    [1560416221] = { 4294967295, 0x42C80000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1385818198 },   -- StratagemType_OrbitalShot
    [1567517764] = { 1, 0x44160000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 1385974777 },   -- StratagemType_Machinegun_PresidentReward
    [1582497738] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2910711004 },   -- StratagemType_TurretMortar
    [1606251952] = { 4294967295, 0x42F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 3438445098 },   -- StratagemType_DropoffCargoContainer
    [1685231450] = { 2, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2577236392 },   -- StratagemType_EagleAirstrikeSmoke
    [1695682779] = { 4294967295, 0x41F00000, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1401993058 },   -- StratagemType_OrbitalIlluminationFlare
    [1753436707] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3461754799 },   -- StratagemType_JumppackBackpack
    [1824787072] = { 4294967295, 0x41F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 2361953887 },   -- StratagemType_SpireSterilizer
    [1907808218] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3975000072 },   -- StratagemType_AmmoBackpack
    [1921790255] = { 4294967295, 0x42B40000, 0, 0, 0, 0, 0, 2, 1, 0, 0, 237983875 },   -- StratagemType_Prospector
    [1979913877] = { 2, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 3175686507 },   -- StratagemType_EagleRocket
    [2007887745] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2694439458 },   -- StratagemType_Air_Burst_Rocket_Launcher
    [2040137691] = { 2, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 459824368 },   -- StratagemType_EagleAirstrikeNapalm
    [2084654169] = { 4294967295, 0x428C0000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1132758889 },   -- StratagemType_OrbitalGatlingBarrage
    [2186648412] = { 4294967295, 0x41200000, 0, 0, 0, 0, 1, 2, 1, 0, 0, 2864982245 },   -- StratagemType_ShoulderMountedCamera
    [2194525688] = { 4294967295, 0x43340000, 0, 0, 0, 0, 1, 2, 1, 0, 0, 2579238661 },   -- StratagemType_MiniMissile
    [2207713849] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 326359764 },   -- StratagemType_Sniper
    [2229216190] = { 4294967295, 0x43960000, 0, 0, 0, 0, 1, 2, 1, 0, 0, 323223727 },   -- StratagemType_HealthPackRack
    [2230051894] = { 4294967295, 0x43960000, 0, 0, 1, 0, 0, 3, 1, 0, 0, 4118375536 },   -- StratagemType_Tutorial_Extract
    [2232989803] = { 4294967295, 0x42F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 865908403 },   -- StratagemType_LaserGuidedMissileLauncher
    [2239174926] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3345385259 },   -- StratagemType_MineDeployer_AntiTank
    [2266266587] = { 4294967295, 0x40C00000, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1413448488 },   -- StratagemType_ReinforcementBeacon
    [2281932031] = { 4294967295, 0x42B40000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3644933986 },   -- StratagemType_EnergyShield
    [2319566343] = { 4294967295, 0x41200000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 1976891343 },   -- StratagemType_CarryData
    [2402590523] = { 4294967295, 0x42F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 325063728 },   -- StratagemType_TurretTesla
    [2587901119] = { 1, 0x44160000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 1244754797 },   -- StratagemType_DropoffCombatWalker_PresidentReward
    [2625074523] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1021642579 },   -- StratagemType_LaserPulseCannon
    [2663642538] = { 1, 0x44960000, 1, 2, 2, 0, 3, 1, 1, 1, 1, 4215408457 },   -- StratagemType_Nuke
    [2720892179] = { 4294967295, 0x41F00000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 2545832384 },   -- StratagemType_BugThumper
    [2742141597] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 790986208 },   -- StratagemType_MineDeployer_IncendiaryMines
    [2744472229] = { 4294967295, 0x43520000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 3169729221 },   -- StratagemType_OrbitalRailcannon
    [2808191861] = { 4, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 3222052854 },   -- StratagemType_EagleCAS
    [2822568285] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 594530405 },   -- StratagemType_LaserCannon
    [2902516083] = { 4294967295, 0x43700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2876315862 },   -- StratagemType_OrbitalNapalmBarrage
    [2919842659] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2279292804 },   -- StratagemType_TurretManned
    [2985177386] = { 4294967295, 0x41700000, 0, 1, 1, 0, 0, 0, 1, 0, 1, 232489632 },   -- StratagemType_SEAF_Gun
    [3001049275] = { 2, 0x41700000, 0, 0, 0, 0, 1, 1, 1, 0, 1, 3073176943 },   -- StratagemType_EagleMissile
    [3078242205] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3266438902 },   -- StratagemType_Railgun
    [3085503322] = { 4294967295, 0x43340000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 914930931 },   -- StratagemType_TurretMortar_Staticfield
    [3108516875] = { 4294967295, 0x43700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2549590927 },   -- StratagemType_OrbitalBarrage
    [3193297673] = { 4294967295, 0x42960000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2094967063 },   -- StratagemType_OrbitalGas
    [3193487269] = { 1, 0x43340000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 4084206755 },   -- StratagemType_SOSBeacon
    [3275255096] = { 1, 0x42340000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 1776173825 },   -- StratagemType_TurretRocket_PresidentReward
    [3279813377] = { 4294967295, 0x43700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 2367237658 },   -- StratagemType_OrbitalWalkingBarrage
    [3300666223] = { 4294967295, 0x3F800000, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1193192688 },   -- StratagemType_UploadDiscovery
    [3316399568] = { 1, 0x42B40000, 0, 0, 1, 0, 1, 2, 1, 0, 0, 3461754799 },   -- StratagemType_JumppackBackpack_PresidentReward
    [3343676429] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 3007597551 },   -- StratagemType_GrenadeLauncher
    [3353508219] = { 4294967295, 0x43960000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1818586518 },   -- StratagemType_BallisticShield
    [3413606544] = { 4294967295, 0x428C0000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2066801016 },   -- StratagemType_LATOneshot
    [3523620028] = { 4294967295, 0x42B40000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 3022121013 },   -- StratagemType_OrbitalShell
    [3656370131] = { 4, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1419287698 },   -- StratagemType_EagleClusterbombs
    [3713568312] = { 4294967295, 0x42C80000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1684652607 },   -- StratagemType_OrbitalSmoke
    [3722314010] = { 4294967295, 0x41F00000, 0, 1, 0, 0, 0, 2, 1, 0, 0, 1301909390 },   -- StratagemType_RaiseFlag
    [3837064536] = { 4294967295, 0x43160000, 0, 1, 0, 1, 0, 0, 1, 0, 0, 830421671 },   -- StratagemType_EagleRearm
    [3843705076] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2714093614 },   -- StratagemType_EnergyShieldBackpack
    [3868299561] = { 1, 0x00000000, 0, 0, 0, 0, 1, 2, 1, 0, 0, 2647942171 },   -- StratagemType_JammedPinata
    [3923676543] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 2566951657 },   -- StratagemType_FafMissileLauncher
    [3928947721] = { 4294967295, 0x41200000, 0, 1, 0, 0, 1, 2, 1, 0, 0, 1976891343 },   -- StratagemType_CyborgCarryData
    [3989310204] = { 4294967295, 0x41F00000, 0, 1, 1, 0, 0, 2, 1, 0, 0, 3384196968 },   -- StratagemType_DropoffHellbomb
    [4119049995] = { 1, 0x41700000, 1, 0, 0, 0, 1, 1, 1, 1, 1, 898053559 },   -- StratagemType_EagleBomb
    [4152191751] = { 4294967295, 0x43F00000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 714923769 },   -- StratagemType_Chem_Gun
    [4239785897] = { 4294967295, 0x42B40000, 1, 0, 0, 0, 1, 2, 1, 1, 0, 1122588897 },   -- StratagemType_TurretMachinegunGPMG
}

-- 商店/发射包哈希(只放非 0 的),用来反推 package 字段偏移
local GROUND_PKG = {
    -- 72 条 package 非 0
    [5185868] = "35F4CA4FA00D380A",
    [12688472] = "A4946425B2C70017",
    [255298804] = "C6D14774E5C77651",
    [295629711] = "22749A294788AF66",
    [485866824] = "BE6C260FADCB8719",
    [623391597] = "992D325D88DE5FBF",
    [644090457] = "EF8EDB7B47D8F0B3",
    [650447969] = "7435E3429DB5CC46",
    [685210453] = "8C96BA199DA24AE3",
    [716273285] = "A957B51F1483DE7A",
    [717707279] = "11BBDF8CE39E5FC5",
    [854563507] = "54DC633A67BAA93D",
    [867876502] = "4D4C26C04A220CAA",
    [875551083] = "49875503E219E80D",
    [929878807] = "9B0D37F93BA0AB03",
    [951988742] = "32CB44321DA1B5A0",
    [970450596] = "662A9D42F834777E",
    [992079466] = "2A9FB8F5D0576EAE",
    [1042447730] = "D87885C7EAACE597",
    [1063322614] = "25B8CFF26C7C0112",
    [1091253198] = "731ACEC30A1A6FAC",
    [1232978203] = "28812689506A3E9C",
    [1238358532] = "1E33CC1600FF38F3",
    [1280711447] = "1E6C958B95568DD7",
    [1290499887] = "E72D3E9B05C3DB0B",
    [1295431756] = "4D4C26C04A220CAA",
    [1298599997] = "15EB7241C3616351",
    [1426041086] = "91F45A686207A351",
    [1503060624] = "982259927D0C50FF",
    [1560416221] = "F51342B25542A582",
    [1582497738] = "8C5A99A9A40D5B8D",
    [1606251952] = "641457F8ECB6BD56",
    [1685231450] = "23BB68BD2E366FDF",
    [1753436707] = "3E78581FDAB81A73",
    [1907808218] = "519980A75EBD50AD",
    [1921790255] = "A892EA036508AD9C",
    [1979913877] = "BFE4D006CC25A01E",
    [2007887745] = "E12F82D7C0C7BC63",
    [2040137691] = "DE456F55554ABB56",
    [2084654169] = "7D72A031B0B3C618",
    [2186648412] = "AAA4485C0B8A76ED",
    [2194525688] = "2947AFE42093062F",
    [2229216190] = "C6D14774E5C77651",
    [2239174926] = "12CE4BC7CDDAF51C",
    [2281932031] = "FE0DB34AC2B9AC61",
    [2402590523] = "8ABFFB1F5544121B",
    [2587901119] = "22749A294788AF66",
    [2720892179] = "3752BFA96CAD0109",
    [2742141597] = "335A97FA3774906E",
    [2744472229] = "F4DC2361985C3026",
    [2808191861] = "2C26BC4C6592FA14",
    [2902516083] = "96CEDF4706334C5F",
    [2919842659] = "68E80476C1C602F5",
    [2985177386] = "51C7DEF49EC9F6BF",
    [3001049275] = "4E381ABCE2D425E8",
    [3085503322] = "4666692B63185121",
    [3108516875] = "FE3EF44300E4A1E2",
    [3193297673] = "6369816737A36A40",
    [3275255096] = "11BBDF8CE39E5FC5",
    [3279813377] = "C0C7278D9F015EE7",
    [3316399568] = "3E78581FDAB81A73",
    [3353508219] = "FC1A5BF2F3FF15DF",
    [3523620028] = "DBAE525060F06D70",
    [3656370131] = "F70996775C6430A9",
    [3713568312] = "BF35E874AC3A3B5A",
    [3722314010] = "055F887C3BC616FE",
    [3843705076] = "47B43A883CAAE42C",
    [3868299561] = "A37891D879CB3B1D",
    [3923676543] = "530BB611A14B6CE3",
    [3989310204] = "681275AF9E93CB2C",
    [4119049995] = "9BC33B7058A2BD5A",
    [4239785897] = "154BD6143819DF7D",
}

-- ---------------------------------------------------- 自身模式串地址规避 -----
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
    return d > -8192 and d < 8192
end

-- ------------------------------------------------------- 战备表: 读 + 校验 --
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
    if hits * 5 < count * 3 then return nil end
    return blob, hits
end

local function ingest_strat_block(magic_address)
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
    local f1 = u64_at(arr, 1)
    local f2 = u64_at(arr, 9)
    if not f1 or not f2 then return nil, "array header out of range" end

    local cands = {
        { base = f1, count = f2, tag = "abs" },
        { base = magic_address + ARRAY_HEADER_OFF + f1, count = f2, tag = "rel+24" },
        { base = magic_address + f1, count = f2, tag = "rel+0" },
        { base = f2, count = f1, tag = "abs-swapped" },
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
        return nil, string.format("数组解释不匹配(f1=0x%X f2=%d size=%d)", f1, f2, size)
    end
    return {
        magic = magic_address, base = best.base, count = best.count,
        blob = best.blob, hits = best.hits, tag = best.tag, size = size,
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
                out[#out + 1] = { id = id, blob = b.blob, off = off,
                                  addr = b.base + j * RECORD_SIZE, blk = b }
            end
        end
    end
    return out
end

-- ------------------------------------------------------- 偏移反推(整表复现) --
-- which: 1=uses 2=cooldown_bits 3=selectable 4=origin 5=cooldown_type 6=maxload 7=cost
--        8 = DLArray 的 count(描述符 +8)
local function expected_u32(rec, which)
    local g = GROUND[rec.id]
    if not g then return nil end
    return g[which]
end

local function value_ok(rec, cand, which)
    local a
    if which == 8 then
        a = u32_at(rec.blob, rec.off + cand + 8)
    else
        a = u32_at(rec.blob, rec.off + cand)
    end
    if a == nil then return false end
    local want = expected_u32(rec, which)
    if want == nil then return false end
    if a == want then return true end
    -- 目标记录允许已经是打完补丁的值(幂等)
    if rec.id == CARPET_ID then
        if which == 1 and a == 4294967295 then return true end
        if which == 3 and a == 1 then return true end
        if which == 4 and a == 0 then return true end
        if which == 5 and a == 0 then return true end
        if which == 8 and a == (state.desired_pcount or 1) then return true end
    end
    return false
end

local function detect_offset(records, which, list)
    records = list or records
    local best, best_score, ties, second = nil, -1, 0, -1
    local last = RECORD_SIZE - 4
    if which == 8 then last = RECORD_SIZE - 16 end
    for cand = 0, last, 4 do
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

-- package(u64 哈希)的偏移:拿 72 条非 0 的原版值逐字节比对
local function detect_package_offset(records)
    local subset = {}
    for i = 1, #records do
        local hex = GROUND_PKG[records[i].id]
        if hex then subset[#subset + 1] = { rec = records[i], bytes = hex_le(hex) } end
    end
    if #subset < 20 then return nil, 0, 0 end
    local best, best_score, ties, second = nil, -1, 0, -1
    for cand = 0, RECORD_SIZE - 8, 4 do
        local score = 0
        for i = 1, #subset do
            local b = subset[i].rec.blob:sub(subset[i].rec.off + cand, subset[i].rec.off + cand + 7)
            if b == subset[i].bytes then score = score + 1 end
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

-- selectable 的编码不是唯一的一种,两种都试、谁分高用谁:
--   A "byte":  独立的一个 0/1 字节                       -> byte == selectable
--   B "bit1":  和别的标志挤在同一个字节里(当前构建就是这样)
--              bit0 恒为 1,bit1 = selectable             -> byte == 1 + 2*selectable
-- 判据还是整表复现:同一列在一百多条记录上同时对上,不可能是巧合。
local SEL_RULES = {
    { name = "byte", n = 2,
      want = function(sel) return sel end,
      on   = function(b) return b == 1 end,
      off  = function(b) return b == 0 end,
      set  = function(b) return 1 end },
    { name = "bit1", n = 3,
      want = function(sel) return 1 + 2 * sel end,
      on   = function(b) return (b % 4) >= 2 end,
      off  = function(b) return (b % 4) < 2 end,
      -- LuaJIT 没有位运算,用算术置 bit1
      set  = function(b) if (b % 4) >= 2 then return b end return b + 2 end },
}

local function detect_selectable(records)
    local best = nil
    for r = 1, #SEL_RULES do
        local rule = SEL_RULES[r]
        local off, score, ties, second = nil, -1, 0, -1
        for cand = 0, RECORD_SIZE - 1 do
            local s = 0
            for i = 1, #records do
                local rec = records[i]
                local g = GROUND[rec.id]
                if g then
                    local b = rec.blob:byte(rec.off + cand)
                    if b == rule.want(g[10]) then s = s + 1
                    elseif rec.id == CARPET_ID and b == rule.want(1) then s = s + 1 end
                end
            end
            if s > score then
                second = score
                off, score, ties = cand, s, 1
            elseif s == score then
                ties = ties + 1
            elseif s > second then
                second = s
            end
        end
        local entry = { rule = rule, off = off, score = score, ties = ties, second = second }
        if not best or entry.score > best.score then best = entry end
    end
    return best
end

-- 记录里 selectable 现在是"开"还是"关"(打完补丁后是开)
local function sel_is_on(b)
    local rule = SEL_RULES[state.sel_rule or 1]
    return rule.on(b)
end
local function sel_is_off(b)
    local rule = SEL_RULES[state.sel_rule or 1]
    return rule.off(b)
end

-- 诊断用:把关注列表里的战备记录原样 dump 出来(认不出来的时候离线对齐)
local WATCH_IDS = { 905054095, 1238358532, 3837064536, 970450596, 929878807,
                    3989310204, 1907808218, 1560416221, 3001049275, 2040137691,
                    1685231450, 3656370131, 1979913877, 4119049995 }   -- 含借壳目标与其它鹰系,便于对照

local function dump_watch(records, suffix, force)
    local out = {}
    local seen = {}
    for i = 1, #records do
        local rec = records[i]
        for w = 1, #WATCH_IDS do
            if rec.id == WATCH_IDS[w] then
                seen[rec.id] = (seen[rec.id] or 0) + 1
                if seen[rec.id] <= 2 then
                    out[#out + 1] = string.format("id=%d addr=0x%X copy=%d", rec.id, rec.addr, seen[rec.id])
                    out[#out + 1] = to_hex(rec.blob:sub(rec.off, rec.off + RECORD_SIZE - 1))
                end
            end
        end
    end
    if #out > 0 then write_file("records_hex" .. (suffix or "") .. ".txt", table.concat(out, NL) .. NL) end
    return #out
end

-- ---------------------------------------------------------------- 写入 ------
local function write_bytes(address, payload)
    if #payload == 0 then return true end
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

local function backup_record(tag, addr, size, extra)
    state.backed_up = state.backed_up or {}
    local key = tag .. ":" .. tostring(addr)
    if state.backed_up[key] then return end
    local raw = read_at(addr, size)
    if not raw then return end
    state.backed_up[key] = true
    write_file("original_" .. tag .. "_" .. string.format("%X", addr) .. ".hex",
        (extra or "") .. NL .. to_hex(raw) .. NL)
end

-- ------------------------------------------------------- 战备记录: 打补丁 ---
-- 把 rec 的 payload 数组换成"借来的那个"(里面已经写好 N 份飞鹰实体)
local function repoint_to_donor(rec, wrote)
    local d = state.donor
    if not d then return false, "没有可用的 donor" end
    if not d.prepared then
        local old = read_at(d.ptr, 8 * d.count)
        if old then
            write_file("original_donor_payload_" .. tostring(d.id) .. ".hex",
                string.format("id=%d addr=0x%X count=%d", d.id, d.ptr, d.count) .. NL .. to_hex(old) .. NL)
        end
        local okw, err = write_bytes(d.ptr, strike_payload_bytes(CONFIG.flight_size))
        if not okw then return false, "写 donor 数组失败: " .. tostring(err) end
        d.prepared = true
    end
    local ok1 = write_bytes(rec.addr + state.off_payload, u64_bytes(d.ptr))
    local ok2 = write_bytes(rec.addr + state.off_payload + 8, u64_bytes(CONFIG.flight_size))
    if not (ok1 and ok2) then return false, "重指向 payload 描述符失败" end
    local np = u64_at(read_at(rec.addr + state.off_payload, 8) or "", 1)
    local nc = u64_at(read_at(rec.addr + state.off_payload + 8, 8) or "", 1)
    if np ~= d.ptr or nc ~= CONFIG.flight_size then
        return false, string.format("重指向回读不符(ptr=0x%X count=%s)", np or 0, tostring(nc))
    end
    rec.used_donor_array = true       -- 这份副本的 payload 描述符指向 donor 数组
    wrote[#wrote + 1] = string.format("payload -> 借用 %d 号的数组(%d 项)", d.id, CONFIG.flight_size)
    return true
end

-- ★ 社区大佬路线:直接把战备**自己的** payload 数组写满(1、2 号槽位 = 常规飞鹰战备的装载物)。
-- 之前那道"扩展位置必须是空白"的安全检查是自己给自己设的障碍 —— 那 16 字节本来就是数组的容量。
-- 现在改成:照写,但先把被覆盖的字节备份下来,写完回读校验。
local function write_own_array(rec, p_ptr, p_cnt, wrote)
    local span = 8 * CONFIG.flight_size
    local old = read_at(p_ptr, span)
    if old then
        write_file("original_payload_array_" .. string.format("%X", p_ptr) .. ".hex",
            string.format("id=%d addr=0x%X ptr=0x%X old_count=%d", rec.id, rec.addr, p_ptr, p_cnt) .. NL
            .. to_hex(old) .. NL)
    end
    local okw, err = write_bytes(p_ptr, strike_payload_bytes(CONFIG.flight_size))
    if not okw then return false, "写数组失败: " .. tostring(err) end
    local okc = write_bytes(rec.addr + state.off_payload + 8, u64_bytes(CONFIG.flight_size))
    if not okc then return false, "写 count 失败" end
    local np = read_at(rec.addr + state.off_payload, 8)
    local nc = read_at(rec.addr + state.off_payload + 8, 8)
    if not np or u64_at(np, 1) ~= p_ptr or u64_at(nc, 1) ~= CONFIG.flight_size then
        return false, "描述符回读不符"
    end
    local first = read_at(p_ptr, 8)
    if not first or not is_our_strike(first) then return false, "数组内容回读不符" end
    rec.used_donor_array = false      -- 这份副本用的是它**自己的**数组(复查判据要认这一点)
    state.flight = CONFIG.flight_size
    state.flight_reason = tostring(CONFIG.flight_size) .. " 架(写自己的 payload 数组 " ..
        tostring(p_cnt) .. "->" .. tostring(CONFIG.flight_size) .. " 项)"
    wrote[#wrote + 1] = "payload 数组 " .. tostring(p_cnt) .. " -> " .. tostring(CONFIG.flight_size) ..
        " 项(自己的数组;1、2 号槽位 = 常规飞鹰装载物)"
    return true
end

local function expand_payload(rec, p_ptr, p_cnt, wrote)
    state.flight = 1
    if CONFIG.flight_size < 2 then
        state.flight_reason = "1 架(配置要求)"
        return
    end

    -- ★ ① 社区大佬路线:直接写**它自己的**数组。
    -- 原版地毯式空袭的数组里 1、2 号槽位本来就留给"额外两架";现在里面不是零,
    -- 但那本来就是数组自己的容量,照写即可(写前备份被覆盖的字节)。
    if CONFIG.prefer_own_array then
        local oko, erro = write_own_array(rec, p_ptr, p_cnt, wrote)
        if oko then
            log("  " .. state.flight_reason)
            return
        end
        log("  写自己的数组没成:" .. tostring(erro) .. ",改走备选")
    end

    -- ② 备选:借一条没人用的战备的 payload 数组(不用赌内存布局)
    if state.donor then
        local okd, errd = repoint_to_donor(rec, wrote)
        if okd then
            state.flight = CONFIG.flight_size
            state.flight_reason = tostring(CONFIG.flight_size) .. " 架(借 " .. tostring(state.donor.id) .. " 的 payload 数组)"
            log("  " .. state.flight_reason)
            return
        end
        log("  借 payload 数组没成:" .. tostring(errd) .. ",改试原地扩容")
    end
    -- 数组本来就够长:原地写满,最安全
    if p_cnt >= CONFIG.flight_size then
        local ok, err = write_bytes(p_ptr, strike_payload_bytes(CONFIG.flight_size))
        if ok then
            state.flight = CONFIG.flight_size
            state.flight_reason = tostring(CONFIG.flight_size) .. " 架(原数组已有 " .. tostring(p_cnt) .. " 项)"
            wrote[#wrote + 1] = "payload[0.." .. tostring(CONFIG.flight_size - 1) .. "]=" .. EAGLE_STRIKE_HEX
        else
            state.flight_reason = "1 架(原地写失败:" .. tostring(err) .. ")"
        end
        return
    end
    local why = nil
    if p_cnt ~= 1 then
        why = "原数组 count=" .. tostring(p_cnt)
    else
        local tail = read_at(p_ptr + 8, 16)
        if not tail then
            why = "扩展位置不可读"
        elseif tail ~= string.rep(string.char(0), 16) then
            why = "扩展位置不是空白"
        elseif not rec.blk then
            why = "缺少区块上下文"
        else
            local blk = rec.blk
            local probe = read_at(blk.magic, blk.size)
            if not probe then
                why = "区块重读失败"
            elseif not (p_ptr + 24 <= blk.magic + blk.size) then
                why = "扩展位置超出区块"
            else
                local lo, hi = p_ptr + 8, p_ptr + 24
                for i = 1, #probe - 7, 4 do
                    local v = u64_at(probe, i)
                    if v and v >= lo and v < hi then why = "扩展位置被别的指针引用"; break end
                end
            end
        end
    end
    if why then
        state.flight_reason = "1 架(未通过 3 架安全检查:" .. why .. ")"
        return
    end
    local ok, err = write_bytes(p_ptr + 8, strike_payload_bytes(CONFIG.flight_size - 1))
    if ok then
        state.flight = 3
        state.flight_reason = "3 架(安全检查通过)"
        wrote[#wrote + 1] = "payload[1..2]=" .. EAGLE_STRIKE_HEX
    else
        state.flight_reason = "1 架(写入失败:" .. tostring(err) .. ")"
    end
end

local function patch_carpet(rec)
    local B, O = rec.blob, rec.off
    local function g(off) return u32_at(B, O + off) end

    local cur_uses   = g(state.off_uses)
    local cur_cd     = g(state.off_cd)
    local cur_sel    = B:byte(O + state.off_selectable)   -- 可能是 bit1 挤在字节里
    local cur_origin = g(state.off_origin)
    local cur_ctype  = g(state.off_ctype)

    -- ★ 别再拿"旧构建常量"当准入闸门(两条实测教训):
    --   * uses:这个字段本 mod **根本不写**,原来却拿 cur_uses == 1 当门槛 ——
    --     构建一变(或者别的 mod 改过)就整份拒绝,而且拒绝理由和真正要写的字段无关。
    --     现在只告警 + 记住实测值(每个副本一次),写入照常。
    --   * cooldown:原来写死"必须等于 0x44610000(= 某个构建里的 900s)或等于我们写的值"。
    --     改成"第一次在这份副本上看到什么原版值就记什么"(rec.orig_cd),之后只要求
    --     现值 == 那份副本的原版值,或 == 我们写进去的值。
    if cur_uses ~= 1 then
        rec.orig_uses = cur_uses
        if not rec.warned_uses then
            rec.warned_uses = true
            log(string.format("  注意:副本 0x%X 的 uses=%s(内置基线是 1,可能是构建漂移);"
                .. "本 mod 不写这个字段,继续。", rec.addr, tostring(cur_uses)))
        end
    end
    if not rec.orig_cd and cur_cd ~= CD_BITS then
        rec.orig_cd = cur_cd
        local base_cd = GROUND[CARPET_ID] and GROUND[CARPET_ID][2] or nil
        if base_cd and cur_cd ~= base_cd then
            log(string.format("  注意:副本 0x%X 的 cooldown 实测原版位模式 0x%08X(%.0fs);"
                .. "内置基线 0x%08X(%.0fs)—— 按实测值接受", rec.addr, cur_cd or 0,
                f32_from_bits(cur_cd or 0), base_cd, f32_from_bits(base_cd)))
        end
    end
    if cur_cd ~= CD_BITS and (not rec.orig_cd or cur_cd ~= rec.orig_cd) then
        state.refusals = state.refusals + 1
        return false, string.format("cooldown bits 0x%08X 既不是我们写的 0x%08X(%.0fs),也不是这份副本的原版值 %s —— 拒绝",
            cur_cd or 0, CD_BITS or 0, CONFIG.cooldown_base,
            rec.orig_cd and string.format("0x%08X", rec.orig_cd) or "(还没观测到)")
    end

    local p_ptr = u64_at(B, O + state.off_payload)
    local p_cnt = u64_at(B, O + state.off_payload + 8)
    if not p_ptr or not p_cnt then return false, "payload 描述符读不出来" end

    local elem0 = read_at(p_ptr, 8)
    if not elem0 then return false, "payload 数组不可读" end
    local is_old = (elem0 == CARPET_OLD_BYTES)
    local is_new = is_our_strike(elem0)
    if not is_old and not is_new then
        return false, "payload[0]=" .. to_hex(elem0) .. " 既不是原版也不是我们的,拒绝"
    end

    local want_cnt = (CONFIG.flight_size >= 2) and 3 or 1
    local icon_ok = true
    if CONFIG.copy_eagle_icon and state.off_icon then
        local cur_icon = read_at(rec.addr + state.off_icon, 8)
        icon_ok = (cur_icon ~= nil and cur_icon ~= ZERO8)
    end
    if is_new and icon_ok and (p_cnt == want_cnt or (p_cnt == 1 and want_cnt == 3))
        and (not CONFIG.enable_stratagem or sel_is_on(cur_sel))
        and (not CONFIG.make_ship_available or cur_origin == 0)
        and (not CONFIG.individual_cooldown or cur_ctype == 0)
        and (cur_cd == CD_BITS)
        and (math.abs(f32_from_bits(u32_at(B, O + OFF_CALL_IN) or 0) - CONFIG.call_in_time) < 0.01)
        and (not CONFIG.fix_description or state.off_description == nil
             or u32_at(B, O + state.off_description) == CONFIG.description_key) then
        state.flight = p_cnt
        state.flight_reason = "already"
        return true, "already"
    end

    backup_record("carpet_stratagem", rec.addr, RECORD_SIZE,
        string.format("id=%d addr=0x%X payload_ptr=0x%X payload_cnt=%d", CARPET_ID, rec.addr, p_ptr, p_cnt))

    local wrote = {}

    local okw, err = write_bytes(p_ptr, STRIKE_BYTES[1])
    if not okw then
        state.refusals = state.refusals + 1
        return false, "写 payload[0] 失败: " .. tostring(err)
    end
    wrote[#wrote + 1] = "payload[0]=" .. EAGLE_STRIKE_HEX

    expand_payload(rec, p_ptr, p_cnt, wrote)

    if p_cnt ~= state.flight then
        local okc, errc = write_bytes(rec.addr + state.off_payload + 8, u32_bytes(state.flight))
        if not okc then
            state.refusals = state.refusals + 1
            return false, "写 payload count 失败: " .. tostring(errc)
        end
        wrote[#wrote + 1] = "payload_count " .. tostring(p_cnt) .. " -> " .. tostring(state.flight)
    end

    if cur_cd ~= CD_BITS then
        local okcd = write_bytes(rec.addr + state.off_cd, u32_bytes(CD_BITS))
        if okcd then wrote[#wrote + 1] = string.format("cooldown %.0fs -> %.1fs(卡面约 %.0fs)",
            f32_from_bits(cur_cd), CONFIG.cooldown_base, CONFIG.cooldown_seconds) end
    end
    -- call-in 的偏移(+92)来自实机 dump 对齐 —— 属于"构建可能漂移"的常量,所以先做**内容校验**:
    -- 呼叫时间只可能是 0..60 秒这种小正数;读出来不是这个范围就说明 +92 已经不是那个字段了,
    -- 宁可不写,也别把隔壁字段一起冲掉。
    local cur_ci = f32_from_bits(u32_at(B, O + OFF_CALL_IN) or 0)
    if math.abs(cur_ci - CONFIG.call_in_time) > 0.01 then
        if cur_ci >= 0 and cur_ci <= 60 then
            local okci = write_bytes(rec.addr + OFF_CALL_IN, f32_bytes(CONFIG.call_in_time))
            if okci then wrote[#wrote + 1] = string.format("call-in %.1fs -> %.1fs", cur_ci, CONFIG.call_in_time) end
        else
            log(string.format("  注意:副本 0x%X 的 +%d 读出来是 %.1f,不在 0..60 秒的合理范围,"
                .. "跳过 call-in 写入(偏移可能漂移)", rec.addr, OFF_CALL_IN, cur_ci))
        end
    end

    if state.off_package then
        local okp, errp = write_bytes(rec.addr + state.off_package, EAGLE_PKG_BYTES)
        if okp then wrote[#wrote + 1] = "package=" .. EAGLE_PKG_HEX
        else log("package 写失败(非致命): " .. tostring(errp)) end
    end

    if CONFIG.enable_stratagem and sel_is_off(cur_sel) then
        -- 只写 1 个字节,并且用算术置位(保留同字节里别的标志)
        local newb = SEL_RULES[state.sel_rule or 1].set(cur_sel)
        local ok1 = write_bytes(rec.addr + state.off_selectable, string.char(newb))
        if ok1 then
            wrote[#wrote + 1] = string.format("selectable(%s) 0x%02X -> 0x%02X",
                SEL_RULES[state.sel_rule or 1].name, cur_sel, newb)
        end
    end
    if CONFIG.make_ship_available and cur_origin ~= 0 then
        local ok1 = write_bytes(rec.addr + state.off_origin, u32_bytes(0))
        if ok1 then wrote[#wrote + 1] = "origin_type " .. tostring(cur_origin) .. " -> 0 (ShipSpecific)" end
    end
    if CONFIG.individual_cooldown and cur_ctype ~= 0 then
        local ok1 = write_bytes(rec.addr + state.off_ctype, u32_bytes(0))
        if ok1 then wrote[#wrote + 1] = "cooldown_type " .. tostring(cur_ctype) .. " -> 0 (Individual)" end
    end
    if CONFIG.fix_description and state.off_description and state.off_description >= 8
        and state.off_description + 4 <= RECORD_SIZE then
        local cur_desc = u32_at(B, O + state.off_description)
        if cur_desc ~= CONFIG.description_key then
            local okd = write_bytes(rec.addr + state.off_description, u32_bytes(CONFIG.description_key))
            if okd then
                wrote[#wrote + 1] = string.format("description %d -> %d(现成的地毯式轰炸说明)",
                    cur_desc or -1, CONFIG.description_key)
            end
        end
    end

    if CONFIG.copy_eagle_icon and state.off_icon and state.icon_bytes then
        local cur_icon = read_at(rec.addr + state.off_icon, 8)
        if cur_icon and cur_icon == ZERO8 then
            local ok1 = write_bytes(rec.addr + state.off_icon, state.icon_bytes)
            if ok1 then wrote[#wrote + 1] = "icon 0x0 -> 补上飞鹰空袭的图标" end
        elseif cur_icon then
            wrote[#wrote + 1] = "icon 已经是 " .. to_hex(cur_icon):upper()
        end
    end

    local after = read_at(rec.addr, RECORD_SIZE)
    if not after then return false, "回读失败" end
    local e0 = read_at(p_ptr, 8)
    local cnt = (state.flight ~= p_cnt) and u32_at(after, state.off_payload + 9) or p_cnt
    if not e0 or not is_our_strike(e0) or cnt ~= state.flight
        or u32_at(after, state.off_cd + 1) ~= CD_BITS then
        state.refusals = state.refusals + 1
        return false, "回读不匹配"
    end
    if CONFIG.enable_stratagem and not sel_is_on(after:byte(state.off_selectable + 1)) then
        state.refusals = state.refusals + 1
        return false, "selectable 回读不匹配"
    end

    state.patched = state.patched + 1
    state.phase = "patched"
    log(string.format("PATCHED CARPET BOMB @0x%X: %s", rec.addr, table.concat(wrote, " | ")))
    log("  投放架数: " .. tostring(state.flight) .. "  (" .. tostring(state.flight_reason) .. ")")
    return true
end

-- ---------------------------------------------------------- 借壳改造 ------
-- 把 hijack 目标那条战备的"身份 + 行为"换成地毯式轰炸的。
-- 只改这几处:名字/描述/fluff(16 字节连在一起)、uses、冷却、package、payload[0]。
-- origin_type / cooldown_type / 图标 / 分类 都**保持目标战备自己的** —— 那些是"能用"的前提。
local function apply_hijack(rec)
    if not CONFIG.hijack_id or CONFIG.hijack_id == 0 or CONFIG.hijack_id == CARPET_ID then
        return false, "disabled"
    end
    if rec.id ~= CONFIG.hijack_id then return false, "not target" end

    local B, O = rec.blob, rec.off
    local src = state.carpet_identity
    if not src or not state.off_description then return false, "缺少源字段" end

    local p_ptr = u64_at(B, O + state.off_payload)
    local p_cnt = u64_at(B, O + state.off_payload + 8)
    if not p_ptr or not p_cnt or p_cnt < 1 then return false, "payload 描述符读不出来" end

    local elem0 = read_at(p_ptr, 8)
    if not elem0 then return false, "payload 数组不可读" end
    local desc_now = u32_at(B, O + state.off_description)
    local cd_now = u32_at(B, O + state.off_cd)
    local want_addl = CONFIG.eagle_rearm and CONFIG.eagle_rearm_type or 0
    local addl_ok = (u32_at(B, O + OFF_ADDL_STRAT) == want_addl)
    local flight_ok = (CONFIG.flight_size < 2) or (state.donor ~= nil and p_cnt >= CONFIG.flight_size)
    local ci_now = f32_from_bits(u32_at(B, O + OFF_CALL_IN) or 0)
    if is_our_strike(elem0) and desc_now == src.description and cd_now == CD_BITS
        and math.abs(ci_now - CONFIG.call_in_time) < 0.01
        and addl_ok and flight_ok then
        return true, "already"
    end

    backup_record("hijack_" .. tostring(CONFIG.hijack_id), rec.addr, RECORD_SIZE,
        string.format("id=%d addr=0x%X", CONFIG.hijack_id, rec.addr))

    local wrote = {}
    -- 名字 / 名字(小写) / 描述 / fluff —— 4 个 u32 连在一起,从 description 往前 8 个字节开始
    local ident_off = state.off_description - 8
    if ident_off >= 8 then
        local ok = write_bytes(rec.addr + ident_off, src.identity)
        if ok then wrote[#wrote + 1] = "name/description/fluff <- CARPET BOMB" end
    end
    -- uses / 冷却
    write_bytes(rec.addr + state.off_uses, u32_bytes(1))
    wrote[#wrote + 1] = "uses -> 1"
    local okcd = write_bytes(rec.addr + state.off_cd, u32_bytes(CD_BITS))
    if okcd then wrote[#wrote + 1] = string.format("cooldown -> %.1fs(卡面约 %.0fs)",
        CONFIG.cooldown_base, CONFIG.cooldown_seconds) end
    local okci = write_bytes(rec.addr + OFF_CALL_IN, f32_bytes(CONFIG.call_in_time))
    if okci then wrote[#wrote + 1] = string.format("call-in -> %.1fs", CONFIG.call_in_time) end
    -- package:保证投放载具的资源被加载
    write_bytes(rec.addr + state.off_package, EAGLE_PKG_BYTES)
    wrote[#wrote + 1] = "package -> eagle_missile.package"
    -- ★ 鹰系挂架(additional_stratagem = StratagemType_EagleRearm)—— 决定次数用完能否回舰补满。
    -- 挂着它,游戏就把本战备当鹰系战备:次数用完 -> 飞鹰回舰装填 -> 次数补满(和其它飞鹰一样)。
    -- 摘掉它,卡面数字会变成"真冷却",但**次数用完就再也点不动了**(实测反馈)。
    local addl_now = u32_at(B, O + OFF_ADDL_STRAT)
    local dep_now = u32_at(B, O + OFF_DEPENDS_ON)
    if CONFIG.eagle_rearm then
        if addl_now ~= CONFIG.eagle_rearm_type then
            local ok1 = write_bytes(rec.addr + OFF_ADDL_STRAT, u32_bytes(CONFIG.eagle_rearm_type))
            if ok1 then wrote[#wrote + 1] = string.format(
                "additional_stratagem %s -> EagleRearm(%d):次数用完可回舰补满",
                tostring(addl_now), CONFIG.eagle_rearm_type) end
        end
        if dep_now ~= 0 then
            local ok2 = write_bytes(rec.addr + OFF_DEPENDS_ON, u32_bytes(0))
            if ok2 then wrote[#wrote + 1] = string.format("depends_on %s -> None", tostring(dep_now)) end
        end
    else
        -- 关掉挂架 = 回到"用一次进真冷却、次数用完不补"的旧行为
        local src_addl = state.carpet_addl
        if src_addl and src_addl.addl == 0 and src_addl.depend == 0 then
            if addl_now ~= 0 then
                local ok1 = write_bytes(rec.addr + OFF_ADDL_STRAT, u32_bytes(0))
                if ok1 then wrote[#wrote + 1] = string.format("additional_stratagem %s -> None(摘掉鹰系挂架)", tostring(addl_now)) end
            end
            if dep_now ~= 0 then
                local ok2 = write_bytes(rec.addr + OFF_DEPENDS_ON, u32_bytes(0))
                if ok2 then wrote[#wrote + 1] = string.format("depends_on %s -> None", tostring(dep_now)) end
            end
        else
            log("源记录的 depends_on/additional_stratagem 不是 None,跳过摘挂架")
        end
    end

    -- payload:优先借数组(一次给足 3 架),否则只改 [0]
    local used_donor = false
    if CONFIG.flight_size >= 2 and state.donor then
        local okd = repoint_to_donor(rec, wrote)
        if okd then
            used_donor = true
            state.flight = CONFIG.flight_size
            state.flight_reason = tostring(CONFIG.flight_size) .. " 架(借 " .. tostring(state.donor.id) .. " 的 payload 数组)"
        end
    end
    if not used_donor then
        local okp = write_bytes(p_ptr, STRIKE_BYTES[1])
        if okp then wrote[#wrote + 1] = "payload[0] -> " .. EAGLE_STRIKE_HEX end
    end

    -- 回读
    local after = read_at(rec.addr, RECORD_SIZE)
    if not after then return false, "回读失败" end
    local cur_ptr = u64_at(after, state.off_payload + 1)
    local e0 = cur_ptr and read_at(cur_ptr, 8)
    if not e0 or not is_our_strike(e0)
        or u32_at(after, state.off_description + 1) ~= src.description
        or u32_at(after, state.off_uses + 1) ~= 1
        or u32_at(after, state.off_cd + 1) ~= CD_BITS
        or (u32_at(after, OFF_ADDL_STRAT + 1) ~= want_addl) then
        state.refusals = state.refusals + 1
        return false, "借壳回读不匹配"
    end
    state.patched = state.patched + 1
    state.hijacked = (state.hijacked or 0) + 1
    log(string.format("HIJACKED 战备 %d @0x%X -> 地毯式轰炸: %s", CONFIG.hijack_id, rec.addr,
        table.concat(wrote, " | ")))
    return true
end

-- ---------------------------------------------------- 飞鹰打击实体: 打补丁 --
-- EagleComponent(152 字节)字段偏移:typelib 布局 + 7 个现役飞鹰实体实测值交叉验证。
local function apply_eagle(addr)
    local cur = read_at(addr, EAGLE_RECSIZE)
    if not cur then return false, "记录不可读" end
    local function g(off) return u32_at(cur, off + 1) end

    local payload = g(16)
    if payload == EAGLE_PAYLOAD_CARPET and g(108) == f32_bits(CONFIG.run_length)
        and g(24) == CONFIG.projectile_type then
        return true, "already"
    end
    -- 打补丁前必须还是 AIM-9 的原版值,否则说明偏移假设不对
    -- 定位靠的是"实体哈希命中桶索引",本身就是精确的;这里只做**值域守卫**,
    -- 防止万一布局漂移时把别的字段当成了 payload/pattern/projectile。
    local pat = g(20)
    local proj = g(24)
    local run = f32_from_bits(g(108))
    local rad = f32_from_bits(g(36))
    -- ★ 原来这里写死 "payload <= 6 / pattern <= 8 / projectile <= 1200",那是 EaglePayload
    --   枚举在某个构建里的成员数 —— 枚举是会被版本回收/扩充的,拿它当准入闸门 =
    --   构建一变就整份拒绝(而且日志只会说"值域不合理",看不出是构建漂移)。
    --   定位靠的是"实体哈希命中桶索引",本身就是精确的;这里只做**宽值域守卫**防止布局漂移,
    --   并把实测值打进日志,漂移一眼可见。
    if not state.logged_eagle_orig then
        state.logged_eagle_orig = true
        log(string.format("EagleComponent 原版值实测:@0x%X payload=%s pattern=%s projectile=%s run=%.1f radius=%.1f",
            addr, tostring(payload), tostring(pat), tostring(proj), run, rad))
    end
    if payload < 1 or payload > 4096 or pat > 64 or proj > 4096
        or run < -1 or run > 3000 or rad < -1 or rad > 3000 then
        state.refusals = state.refusals + 1
        return false, string.format("原版值域不合理(payload=%s pattern=%s proj=%s run=%.1f radius=%.1f),拒绝写入",
            tostring(payload), tostring(pat), tostring(proj), run, rad)
    end

    backup_record("eagle_component", addr, EAGLE_RECSIZE,
        string.format("entity=%s payload=%d pattern=%d projectile=%d runlen=%d",
            EAGLE_STRIKE_HEX, g(16), g(20), g(24), g(108)))

    local function w32(off, v) return write_bytes(addr + off, u32_bytes(v)) end
    local function wf(off, x) return write_bytes(addr + off, f32_bytes(x)) end

    local steps = {
        { 8,   function() return wf(8, CONFIG.flyby_distance) end },
        { 12,  function() return wf(12, 3.0) end },
        { 16,  function() return w32(16, EAGLE_PAYLOAD_CARPET) end },
        { 20,  function() return w32(20, EAGLE_PATTERN_6Z) end },
        { 24,  function() return w32(24, CONFIG.projectile_type) end },
        { 28,  function() return wf(28, 90.0) end },
        { 36,  function() return wf(36, CONFIG.search_radius) end },
        { 40,  function() return wf(40, CONFIG.fire_duration) end },
        { 44,  function()
            local iv = bomb_interval_for(state.flight)
            local ok = wf(44, iv)
            if ok then
                local planes = CONFIG.bomb_planes
                if not planes or planes <= 0 then planes = state.flight end
                planes = math.max(1, planes or 1)
                log(string.format("  投弹间隔自标定: 按 %d 架反算 -> 每架 %d 发, interval=%.3f s (已写)",
                    planes, math.floor(CONFIG.target_bombs / planes), iv))
            end
            return ok
        end },
        { 48,  function() return wf(48, 0.05) end },
        { 52,  function() return wf(52, CONFIG.approach_distance) end },
        { 56,  function() return wf(56, CONFIG.approach_distance) end },
        { 60,  function() return wf(60, CONFIG.approach_height) end },
        { 76,  function() return wf(76, CONFIG.move_speed) end },
        { 80,  function() return wf(80, CONFIG.move_speed) end },
        { 88,  function() return wf(88, CONFIG.acceleration) end },
        { 92,  function() return wf(92, CONFIG.deceleration) end },
        { 108, function() return wf(108, CONFIG.run_length) end },
        { 112, function() return wf(112, 5.0) end },
        { 116, function() return wf(116, 0.35) end },
        { 120, function() return wf(120, CONFIG.fire_distance) end },
        { 132, function() return w32(132, EAGLE_AUDIO_START) end },
        { 136, function() return w32(136, EAGLE_AUDIO_STOP) end },
    }
    local okcount = 0
    for i = 1, #steps do
        local ok = steps[i][2]()
        if ok then okcount = okcount + 1
        else log(string.format("  EagleComponent +%d 写失败", steps[i][1])) end
    end
    if okcount == 0 then
        state.refusals = state.refusals + 1
        return false, "全部字段写入失败"
    end

    local after = read_at(addr, EAGLE_RECSIZE)
    if not after then return false, "回读失败" end
    if u32_at(after, 17) ~= EAGLE_PAYLOAD_CARPET
        or u32_at(after, 25) ~= CONFIG.projectile_type then
        state.refusals = state.refusals + 1
        return false, "回读校验不匹配(payload/projectile)"
    end
    -- f32 用解码器判,不用自己再编码一遍(否则编码器坏了也看不出来)
    local got_run = f32_from_bits(u32_at(after, 109))
    local got_rad = f32_from_bits(u32_at(after, 37))
    local got_spd = f32_from_bits(u32_at(after, 77))
    if math.abs(got_run - CONFIG.run_length) > 0.01
        or math.abs(got_rad - CONFIG.search_radius) > 0.01
        or math.abs(got_spd - CONFIG.move_speed) > 0.01 then
        state.refusals = state.refusals + 1
        return false, string.format("回读校验不匹配(run=%.3f radius=%.3f speed=%.3f)", got_run, got_rad, got_spd)
    end
    state.patched = state.patched + 1
    state.eagle_patched = (state.eagle_patched or 0) + 1
    log(string.format("PATCHED EagleComponent @0x%X: %d/%d 字段 (payload=CarpetBombing, projectile=%d, run=%.0fm, radius=%.0fm)",
        addr, okcount, #steps, CONFIG.projectile_type, CONFIG.run_length, CONFIG.search_radius))
    return true
end

-- --------------------------------------------------- 飞鹰表: 定位 + 布局 ---
local function ingest_eagle_block(magic_address)
    local head = read_at(magic_address, 40)
    if not head then return nil, "unreadable" end
    if head:sub(1, 4) ~= MAGIC then return nil, "not LDLD" end
    local ver  = u32_at(head, 5)
    local typ  = u32_at(head, 9)
    local size = u32_at(head, 13)
    if ver ~= 1 then return nil, "version" end
    if typ ~= EAGLE_TYPE_HASH then return nil, string.format("type 0x%08X", typ or 0) end
    if not size or size < 32 or size > 65536 then return nil, "size " .. tostring(size) end

    local body = read_at(magic_address + 24, size)
    if not body then return nil, "body unreadable" end

    local best = nil
    for A = 1, math.floor(size / 16) do
        local rem = size - A * 16
        if rem <= 0 then break end
        if rem % EAGLE_RECSIZE == 0 then
            local N = math.floor(rem / EAGLE_RECSIZE)
            if N > 0 then
                local ok = true
                for k = 0, A - 1 do
                    -- 实体哈希是 64 位,>2^53,一律按字节比较,绝不过 number
                    local hv = body:sub(k * 16 + 1, k * 16 + 8)
                    local ix = u32_at(body, k * 16 + 9)
                    local pd = u32_at(body, k * 16 + 13)
                    if not ix or not pd or pd ~= 0 or ix >= N then ok = false; break end
                    if hv == ZERO8 and ix ~= 0 then ok = false; break end
                end
                if ok then
                    local score = math.abs(A - 2 * N)
                    if not best or score < best.score then best = { A = A, N = N, score = score } end
                end
            end
        end
    end
    if not best then return nil, "布局定不出来" end

    -- ★ 诊断:payload 存的是 **EaglePayload 枚举下标**(我们要写的 CarpetBombing 写死成 6)。
    --   枚举下标会被版本回收 —— 把本构建里 EagleComponent 实际出现的枚举值打出来对照一次,
    --   万一 6 变成了别的东西,日志里能看出来(而不是"静默丢错弹")。
    if not state.logged_eagle_enum then
        state.logged_eagle_enum = true
        -- 三个字段都是**枚举下标**(会被版本回收):payload / pattern / projectile。
        -- 把本构建实测到的取值全打出来,和 mod 里写死的常量对照一次。
        local base0 = magic_address + 24 + best.A * 16
        -- strict = 那个枚举很小(几个成员),"不在域内"就值得警告;
        -- 射弹枚举很大,不在这一小张表里很正常,只当参考。
        local function domain(off, want, label, strict)
            local seen, order = {}, {}
            for k = 0, best.N - 1 do
                local head = read_at(base0 + k * EAGLE_RECSIZE, off + 4)
                local v = head and u32_at(head, off + 1)
                if v and not seen[v] then seen[v] = true; order[#order + 1] = v end
            end
            table.sort(order)
            local parts = {}
            for i = 1, math.min(#order, 24) do parts[i] = tostring(order[i]) end
            local tag
            if strict then
                tag = seen[want] and "(域内 ✓)" or "(域里没有 —— 可能是版本回收,核对!)"
            else
                tag = seen[want] and "(这张表里有 ✓)" or "(这张表里没有;射弹枚举很大,不一定是问题)"
            end
            log(string.format("  EagleComponent %-10s 实测域=[%s](%d 个不同值);本 mod 写 %s%s",
                label, table.concat(parts, ","), #order, tostring(want), tag))
        end
        log(string.format("EagleComponent: A=%d N=%d(桶/记录数,由 size 反推)", best.A, best.N))
        domain(16, EAGLE_PAYLOAD_CARPET, "payload", true)
        domain(20, EAGLE_PATTERN_6Z, "pattern", true)
        domain(24, CONFIG.projectile_type, "projectile", false)
    end

    -- 桶里可能同时有我们三个打击实体(它们是不同的 unit),全部收出来
    local idxs = {}
    for k = 0, best.A - 1 do
        local hv = body:sub(k * 16 + 1, k * 16 + 8)
        if is_our_strike(hv) then
            if idxs[hv] then return nil, "同一实体在桶里出现多次" end
            idxs[hv] = u32_at(body, k * 16 + 9)
        end
    end
    local addrs = {}
    for hv, idx in pairs(idxs) do
        addrs[#addrs + 1] = { hash = to_hex(hv), addr = magic_address + 24 + best.A * 16 + idx * EAGLE_RECSIZE }
    end
    if #addrs == 0 then return nil, "桶里没有我们的打击实体" end
    table.sort(addrs, function(x, y) return x.hash < y.hash end)
    return { magic = magic_address, size = size, A = best.A, N = best.N, addrs = addrs }
end

-- ------------------------------------------------------------- 扫描驱动 ----
-- 秒 -> 帧(按 60fps 估),并且给一个 30 帧的下限,免得配个 0.1 秒变成每帧都干重活
local function secs(n) return math.max(30, math.floor(n * 60)) end

local SCAN_CHUNK   = 262144
local SCAN_OVERLAP = 2048
local SCAN_BUDGET  = 0.004      -- 常规:每 2 帧 4ms
local SCAN_EVERY   = 2
-- 启动阶段:游戏可能在我们打补丁之前就把"次数/冷却"算好缓存了,
-- 所以开局用更大的预算 + 每帧都扫,尽快把补丁打上(只在加载界面,一次性代价)。
local SCAN_BUDGET_FAST = 0.003
local FAST_UNTIL_FRAME = 0        -- 禁用启动期 16ms 暴力占用,保持帧率平稳
local START_FRAME      = 5
local MAX_BLOCKS   = 96      -- 同一张表在内存里会有几十份,尽量都收进来
local MAX_HITS     = 128
local DUMP_BYTES   = 1024
local EAGLE_BUDGET = 0.003

local max_scan = 2 ^ 47
local region = ffi.new("DshMemRegion[1]")
local region_size = ffi.sizeof(region[0])

local function is_readable(protection)
    return protection == 2 or protection == 4 or protection == 8
        or protection == 32 or protection == 64 or protection == 128
end

-- 返回 list 和一份统计(统计要写进日志:漏没漏一眼就能看出来)
-- ★ 原来的门槛写死 64KB:那是"某个构建里区块都很大"的假设。最大那个区块实测 19KB,
--   一旦游戏把区块放进 16~64KB 的分配块里就会**整片漏掉**(而且不报错)。
local function collect_regions()
    local list = {}
    local min_size = CONFIG.min_region_bytes or 16384
    local skipped_small, skipped_prot, readable = 0, 0, 0
    local address = 65536
    while address < max_scan do
        if kernel.VirtualQuery(ffi.cast("const void *", address),
                ffi.cast("void *", region), region_size) ~= region_size then break end
        local base = tonumber(ffi.cast("uintptr_t", region[0].base))
        local size = tonumber(region[0].size)
        if not size or size <= 0 then break end
        if tonumber(region[0].state) == 4096 then
            readable = readable + 1
            if not is_readable(tonumber(region[0].protection)) then
                skipped_prot = skipped_prot + 1
            elseif size < min_size then
                skipped_small = skipped_small + 1
            else
                list[#list + 1] = { base = base, size = size }
            end
        end
        local next_address = base + size
        if next_address <= address then break end
        address = next_address
    end
    table.sort(list, function(a, b) return a.size > b.size end)
    return list, { readable = readable, small = skipped_small, prot = skipped_prot, min = min_size }
end

local function add_watch(magic, size)
    local base = magic - 32768
    if base < 65536 then base = 65536 end
    local stop = magic + size + 32768
    local list = state.watch or {}
    for i = 1, #list do
        local w = list[i]
        if base <= w.base + w.size and stop >= w.base then
            if base < w.base then
                w.size = w.size + (w.base - base); w.base = base
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
    local expanding = state.expand and true or false
    local keep_targets, keep_hijack, keep_donor = state.targets, state.hijack_targets, state.donor
    state.blocks = nil
    state.hits = nil
    state.seen = nil
    state.regions = nil

    state.last_records = #records
    state.last_round = string.format("round %d: regions=%d hits=%d blocks=%d records=%d",
        state.scan_round, state.region_count or 0, #hits, #blocks, #records)
    log(string.format("第 %d 轮%s扫描结束:签名命中 %d 处,%d 个 StratagemSettings 区块,%d 条战备记录",
        state.scan_round, expanding and "(补扫)" or "", #hits, #blocks, #records))

    -- 一轮没通过时的统一收场:
    --   * 普通轮 -> refused(硬停,不刷屏)
    --   * 补扫轮 -> **绝不能**把已经打好的补丁状态搞丢(状态回退 = 已打的补丁没人维护),
    --               原样退回 patched 并保留旧副本列表
    local function bail(msg, dump)
        state.refusals = state.refusals + 1
        if expanding then
            state.targets, state.hijack_targets, state.donor = keep_targets, keep_hijack, keep_donor
            state.expand = false
            state.phase = (keep_targets and #keep_targets > 0) and "patched" or "scanning"
            state.last_round = state.last_round .. " | 补扫未通过:" .. tostring(msg)
            log("补扫未通过(" .. tostring(msg) .. "),保留已打好的 " ..
                tostring(keep_targets and #keep_targets or 0) .. " 份副本")
        else
            state.phase = "refused"
            log("REFUSED:" .. tostring(msg))
        end
        if dump then dump_raw_hits(hits, "round" .. state.scan_round) end
    end

    if #blocks == 0 and #hits > 0 then
        bail("签名命中但解析不出记录数组;原始字节已落盘", true)
        return
    end

    if #records < CONFIG.min_records then
        if #blocks > 0 then
            bail("只认出 " .. #records .. " 条战备(< " .. CONFIG.min_records .. ")")
            return
        end
        if expanding then
            bail("这一轮一个区块都没看到(游戏可能正在重载)")
            return
        end
        state.empty_rounds = (state.empty_rounds or 0) + 1
        if state.empty_rounds >= CONFIG.max_empty_rounds then
            state.phase = "gave_up"
            log("连续 " .. state.empty_rounds .. " 轮都没找到 StratagemSettings,停止扫描")
            return
        end
        local delay = math.min(30, 2 ^ state.empty_rounds) * 60
        state.next_round_frame = state.frames + delay
        state.phase = "scanning"
        log(string.format("这一轮没看到区块;约 %d 秒后重扫", math.floor(delay / 60)))
        return
    end

    state.desired_pcount = (CONFIG.flight_size >= 2) and 3 or 1
    state.flight_reason = "n/a"

    dump_watch(records)
    local names = { "uses", "cooldown", "(selectable单列)", "origin", "ctype", "maxload", "cost",
                    "payload_count", "mission(byte列)", "selectable(byte列)", "triggers(byte列)",
                    "description" }
    -- selectable 不在这里反推:它是 byte,见下面的 detect_byte_triple
    local strict = { [1] = true, [2] = true, [4] = true, [5] = true, [8] = true }
    local offs = {}
    local fail = nil
    local desc_score, desc_off, desc_ties, desc_second = 0, nil, 0, 0
    -- 判据说明:
    --   * 分数必须 >= 65% 记录(给构建漂移留余量)
    --   * 并列(同样最高分)必须唯一
    --   * 正常情况下要求"最高分 >= 3 x 第二高分"这种断层
    --   * 例外:origin_type / cooldown_type 在真实数据里几乎完全相关(氏族站的战备同时是
    --     SharedClan),互为第二名是必然的。所以当最高分 >= 85% 记录时也接受 —— 这种
    --     近乎全中的列不可能是巧合,而且两条字段要写的目标值相同(都是 0)。
    for which = 1, 12 do
        if which == 9 or which == 10 or which == 11 or which == 3 then
            -- 9/10/11 是 byte 列,selectable(3) 单独判(见 detect_selectable)
            
            -- selectable 是 byte,交给 detect_byte_triple
        else
        local off, score, ties, second = detect_offset(records, which)
        offs[which] = off
        if which == 12 then desc_off, desc_score, desc_ties, desc_second = off, score, ties, second end
        local gap_ok = score >= second * 3
        local near_perfect = score >= math.floor(#records * 0.85)
        log(string.format("  字段 %-13s -> +%-4s 命中 %d/%d (第二 %d, 并列 %d)%s",
            names[which], tostring(off), score, #records, second, ties,
            gap_ok and "" or (near_perfect and "  [相关性例外]" or "")))
        if strict[which] then
            local floor = math.floor(#records * 0.65)
            if not off or ties ~= 1 or score < floor or not (gap_ok or near_perfect) then
                fail = names[which] .. string.format("(score=%d ties=%d second=%d)", score, ties, second)
            end
        end
        end
    end

    -- description:字符串键失效了(当前构建里查不到),用整表复现定位字段偏移。
    -- 判据不过就**一个字节都不写**(写错偏移会直接把别的字段冲掉)。
    local desc_ok = desc_off ~= nil and desc_off >= 8 and desc_ties == 1
        and desc_score >= math.floor(#records * 0.65)
        and (desc_score >= desc_second * 3 or desc_score >= math.floor(#records * 0.85))
    log(string.format("  字段 %-22s -> +%-4s 命中 %d/%d (第二 %d) %s", "description", tostring(desc_off),
        desc_score, #records, desc_second, desc_ok and "" or " 判据不过,跳过"))
    if desc_ok then
        state.off_description = desc_off
    else
        -- 兜底:实机 dump 对齐出来的偏移是 +48。用它,但必须先验证目标记录那一格
        -- 真的等于原版 CARPET BOMB 的 description 键 —— 不匹配就彻底放弃这一项。
        for i = 1, #records do
            if records[i].id == CARPET_ID then
                if u32_at(records[i].blob, records[i].off + 48) == CARPET_DESC_KEY then
                    state.off_description = 48
                    log("  description 偏移回退到 +48(已用原版键值校验过)")
                end
                break
            end
        end
    end

    -- selectable:两种编码规则都试(见 SEL_RULES)
    local sel = detect_selectable(records)
    log(string.format("  字段 %-13s -> +%-4s 命中 %d/%d (第二 %d, 并列 %d)  规则=%s",
        "selectable", tostring(sel and sel.off), sel and sel.score or 0, #records,
        sel and sel.second or 0, sel and sel.ties or 0, sel and sel.rule.name or "?"))
    if not sel or sel.ties ~= 1 or sel.score < math.floor(#records * 0.65)
        or not (sel.score >= sel.second * 3 or sel.score >= math.floor(#records * 0.85)) then
        fail = "selectable" .. string.format("(rule=%s score=%s ties=%s second=%s)",
            sel and sel.rule.name or "?", sel and sel.score or 0,
            sel and sel.ties or 0, sel and sel.second or 0)
    else
        offs[3] = sel.off
        state.sel_rule = (sel.rule.name == "byte") and 1 or 2
        state.sel_off = sel.off
    end

    local pkg_off, pkg_score, pkg_ties, pkg_second = detect_package_offset(records)
    log(string.format("  字段 %-13s -> +%-4s 命中 %d (并列 %d)", "package",
        tostring(pkg_off), pkg_score, pkg_ties))
    if pkg_off and pkg_ties == 1 and pkg_score >= 40 and pkg_score >= pkg_second * 3 then
        state.off_package = pkg_off
    else
        state.off_package = nil
        log("  警告:package 偏移没反推出来,这一项跳过(非致命)")
    end

    if fail then
        state.last_round = state.last_round .. " | 字段校验失败:" .. tostring(fail)
        bail("字段偏移整表校验没过(" .. tostring(fail) .. "),拒绝写入")
        return
    end
    -- 只对真正会写入的字段要求偏移互不相同(maxload / cost 只做诊断,它们和
    -- selectable 天然相关,撞车不代表出错)
    local seen_off = {}
    for which = 1, 8 do
        if strict[which] then
            if offs[which] and seen_off[offs[which]] then
                bail(string.format("字段 +%d 被两个字段同时选中,拒绝写入", offs[which]))
                return
            end
            seen_off[offs[which]] = true
        end
    end
    if offs[1] ~= 80 or offs[2] ~= 104 then
        log(string.format("注意:uses/cooldown 反推出 +%d/+%d(历史实测 +80/+104),以反推值为准", offs[1], offs[2]))
    end

    state.off_uses       = offs[1]
    state.off_cd         = offs[2]
    state.off_selectable = offs[3]
    state.off_origin     = offs[4]
    state.off_ctype      = offs[5]
    state.off_payload    = offs[8]
    state.records        = records

    -- 图标。组件字段顺序是 payload, package, icon, store_icon;
    -- package 的偏移已经过整表复现验证,icon 就是它后面那个 u64(+8)。
    -- ⚠ 当前构建里 CARPET BOMB 的 icon 是 **0**(图标资源被箭头删掉了),
    --   而实机对比显示:所有在用的战备 icon 都非 0,只有它一个不是 —— 极可能就是列表里看不到的原因。
    --   所以从飞鹰空袭那条记录抄一个现成的图标过来。
    if CONFIG.copy_eagle_icon and state.off_package then
        local cand = state.off_package + 8
        local donor = nil
        for i = 1, #records do
            if records[i].id == EAGLE_AIRSTRIKE_ID then donor = records[i] break end
        end
        if not donor then
            for i = 1, #records do
                local b = records[i].blob:sub(records[i].off + cand, records[i].off + cand + 7)
                if b ~= ZERO8 then donor = records[i] break end
            end
        end
        if donor then
            local b = donor.blob:sub(donor.off + cand, donor.off + cand + 7)
            if b ~= ZERO8 then
                state.off_icon = cand
                state.icon_bytes = b
                log(string.format("图标偏移 = +%d,借用 %d 号的图标 0x%s", cand, donor.id, to_hex(b):upper()))
            else
                log("参照记录的图标也是 0,跳过图标替换")
            end
        else
            log("找不到图标参照记录,跳过图标替换")
        end
    end

    local targets = {}
    for i = 1, #records do
        if records[i].id == CARPET_ID then targets[#targets + 1] = records[i] end
    end
    if #targets == 0 then
        bail("表里没有 id " .. CARPET_ID .. " (CARPET BOMB)")
        return
    end

    -- 最终指纹:用 CARPET BOMB 自己的原版数值反过来验证这四个偏移。
    -- 原版:selectable=0, origin_type=2(ClanStation), cooldown_type=2(SharedClan), payload 1 项;
    -- 打完补丁后是 1/0/0 且 payload 是我们的实体 + 目标架数 —— 两种形态都接受(幂等)。
    for i = 1, #targets do
        local B, O = targets[i].blob, targets[i].off
        local selb = B:byte(O + state.off_selectable)
        local org  = u32_at(B, O + state.off_origin)
        local ct   = u32_at(B, O + state.off_ctype)
        local pcnt = u32_at(B, O + state.off_payload + 8)
        local ok_orig = (sel_is_off(selb) and org == 2 and ct == 2
                         and (pcnt == 1 or pcnt == (state.desired_pcount or 1)))
        local ok_done = (sel_is_on(selb) and org == 0 and ct == 0)
        if not ok_orig and not ok_done then
            bail(string.format("CARPET BOMB 记录指纹不符(selectable=0x%02X 规则=%s origin=%s ctype=%s payload=%s),偏移可能反推错了",
                selb, sel and sel.rule.name or "?", tostring(org), tostring(ct), tostring(pcnt)))
            return
        end
    end
    log(string.format("校验通过:uses=+%d cd=+%d selectable=+%d origin=+%d ctype=+%d package=+%s payload=+%d | CARPET BOMB 共 %d 份副本",
        state.off_uses, state.off_cd, state.off_selectable, state.off_origin,
        state.off_ctype, tostring(state.off_package), state.off_payload, #targets))
    -- ★ 实测:完整的一轮是 16 个区块 / 148 条记录。只看到一半 = 有一整套副本没在
    --   这一轮的 region 列表里(启动太早)。这不是"表变小了",必须继续补扫。
    if #records < (CONFIG.min_records or 40) * 2 then
        log(string.format("注意:本轮只认出 %d 条战备记录 —— 同一张表在内存里实测有**两整套**"
            .. "(区块数/记录数都会翻倍),这里少了一套;会按 expand_seconds 继续补扫并合并。", #records))
    end
    -- 把 CARPET BOMB 的实测原值打进日志:构建一变,这里第一时间就能看出漂移
    do
        local t = targets[1]
        local ob = t.blob
        local oo = t.off
        log(string.format("  实测原值:uses=%s cd=0x%08X(%.0fs) selectable(byte@+%d)=0x%02X origin=%s ctype=%s "
            .. "payload_count=%s package=0x%s description=%s additional_stratagem=%s depends_on=%s",
            tostring(u32_at(ob, oo + state.off_uses)), u32_at(ob, oo + state.off_cd) or 0,
            f32_from_bits(u32_at(ob, oo + state.off_cd) or 0), state.off_selectable,
            ob:byte(oo + state.off_selectable) or 0,
            tostring(u32_at(ob, oo + state.off_origin)), tostring(u32_at(ob, oo + state.off_ctype)),
            tostring(u32_at(ob, oo + state.off_payload + 8)),
            to_hex(ob:sub(oo + state.off_package, oo + state.off_package + 7)):upper(),
            tostring(u32_at(ob, oo + state.off_description)),
            tostring(u32_at(ob, oo + OFF_ADDL_STRAT)), tostring(u32_at(ob, oo + OFF_DEPENDS_ON))))
    end

    -- ★ 枚举下标会被版本回收:additional_stratagem 存的是 StratagemType_EagleRearm 的**枚举值**。
    --   CONFIG 里写死的 48 只是某个构建的快照,所以这里用本构建**实测的现役鹰系战备**反推:
    --   空袭/集束/500kg/... 这些现役鹰系战备的 additional_stratagem 必然都指向 EagleRearm,
    --   取它们的非 0 众数值当权威值;与配置不一致就以实测为准(并写进日志)。
    if CONFIG.eagle_rearm then
        local EAGLE_STANDARD_IDS = { 1238358532, 2040137691, 3656370131, 4119049995,
                                     929878807, 1979913877, 2808191861, 3001049275 }
        local tally, total = {}, 0
        for i = 1, #records do
            local rec = records[i]
            for k = 1, #EAGLE_STANDARD_IDS do
                if rec.id == EAGLE_STANDARD_IDS[k] then
                    local v = u32_at(rec.blob, rec.off + OFF_ADDL_STRAT)
                    if v and v ~= 0 then tally[v] = (tally[v] or 0) + 1; total = total + 1 end
                    break
                end
            end
        end
        local best_v, best_n, ties = nil, 0, 0
        for v, n in pairs(tally) do
            if n > best_n then best_v, best_n, ties = v, n, 1
            elseif n == best_n then ties = ties + 1 end
        end
        if best_v and ties == 1 then
            state.rearm_observed = { value = best_v, hits = best_n, total = total }
            if best_v ~= CONFIG.eagle_rearm_type then
                log(string.format("★ EagleRearm 枚举漂移:配置写死 %d,本构建实测 %d(%d/%d 条现役鹰系战备一致)—— 按实测值走",
                    CONFIG.eagle_rearm_type, best_v, best_n, total))
                CONFIG.eagle_rearm_type = best_v
            else
                log(string.format("EagleRearm 枚举校验通过:%d(本构建 %d/%d 条现役鹰系战备一致)",
                    best_v, best_n, total))
            end
        else
            log(string.format("EagleRearm 枚举没能在本构建里交叉验证(样本 %d 条,众数 %s 命中 %d,并列 %d),沿用配置值 %d",
                total, tostring(best_v), best_n, ties, CONFIG.eagle_rearm_type))
        end
    end

    -- 抓一份"地毯式轰炸"的身份字节(名字/描述),借壳时要抄过去
    do
        local t = targets[1]
        local ib = state.off_description - 8
        if ib >= 8 then
            state.carpet_identity = {
                identity = t.blob:sub(t.off + ib, t.off + ib + 15),
                description = u32_at(t.blob, t.off + state.off_description),
            }
            state.carpet_addl = {
                addl = u32_at(t.blob, t.off + OFF_ADDL_STRAT) or 0,
                depend = u32_at(t.blob, t.off + OFF_DEPENDS_ON) or 0,
            }
            log(string.format("源 depends_on=%s additional_stratagem=%s (期望都是 0)",
                tostring(state.carpet_addl.depend), tostring(state.carpet_addl.addl)))
            log(string.format("源身份:description=%s name_cased=%s",
                tostring(state.carpet_identity.description),
                tostring(u32_at(t.blob, t.off + ib + 4))))
        end
    end
    -- 找一个"没人用、payload 数组够长"的战备当数组提供者
    state.donor = nil
    if CONFIG.flight_size >= 2 and CONFIG.donor_payload_id and CONFIG.donor_payload_id ~= 0 then
        for i = 1, #records do
            local rec = records[i]
            if rec.id == CONFIG.donor_payload_id then
                local dp = u64_at(rec.blob, rec.off + state.off_payload)
                local dc = u64_at(rec.blob, rec.off + state.off_payload + 8)
                if dp and dc and dc >= CONFIG.flight_size then
                    if state.donor and state.donor.ptr ~= dp then
                        log("  警告:donor 出现在多处,取第一份")
                    end
                    if not state.donor then
                        local probe = read_at(dp, 8 * dc)
                        if probe then
                            state.donor = { id = rec.id, ptr = dp, count = dc }
                            log(string.format("  借数组来源 id=%d payload ptr=0x%X count=%d", rec.id, dp, dc))
                        else
                            log("  donor 数组不可读,放弃借用")
                        end
                    end
                else
                    log(string.format("  donor id=%d 的 payload 项数不够(count=%s),放弃借用",
                        CONFIG.donor_payload_id, tostring(dc)))
                end
            end
        end
        if not state.donor then
            log("  没找到可用的 donor(可能在别的内存副本里),这一轮不借数组")
        end
    end

    state.hijack_targets = {}
    if CONFIG.hijack_id and CONFIG.hijack_id ~= 0 then
        for i = 1, #records do
            if records[i].id == CONFIG.hijack_id then
                state.hijack_targets[#state.hijack_targets + 1] = records[i]
            end
        end
        log(string.format("借壳目标 %d:找到 %d 份副本", CONFIG.hijack_id, #state.hijack_targets))
    end

    -- ★ 补扫轮:把新发现的副本**并**进已有列表(而不是替换)。
    --   这样"稍后才加载出来的那一整套"也会被打上补丁,而已经打过的副本保留原对象
    --   (它们身上的 rec.orig_cd / rec.used_donor_array 等记录还在)。
    if expanding then
        local known, merged, added = {}, {}, 0
        for i = 1, #(keep_targets or {}) do
            local r = keep_targets[i]
            merged[#merged + 1] = r
            known[r.addr] = true
        end
        for i = 1, #targets do
            if not known[targets[i].addr] then
                known[targets[i].addr] = true
                merged[#merged + 1] = targets[i]
                added = added + 1
            end
        end
        targets = merged
        local hknown, hmerged, hadded = {}, {}, 0
        for i = 1, #(keep_hijack or {}) do
            hmerged[#hmerged + 1] = keep_hijack[i]
            hknown[keep_hijack[i].addr] = true
        end
        for i = 1, #(state.hijack_targets or {}) do
            local r = state.hijack_targets[i]
            if not hknown[r.addr] then
                hknown[r.addr] = true
                hmerged[#hmerged + 1] = r
                hadded = hadded + 1
            end
        end
        state.hijack_targets = hmerged
        if not state.donor then state.donor = keep_donor end
        log(string.format("补扫合并:战备副本新增 %d 份(共 %d 份);借壳目标新增 %d 份(共 %d 份)",
            added, #targets, hadded, #hmerged))
    end
    state.expand = false

    state.watch = {}
    for i = 1, #blocks do add_watch(blocks[i].magic, blocks[i].size) end
    state.targets = targets
    state.phase = "located"
    state.last_round = state.last_round .. string.format(" | offs u=%d cd=%d sel=%d org=%d ct=%d pay=%d pkg=%s",
        state.off_uses, state.off_cd, state.off_selectable, state.off_origin,
        state.off_ctype, state.off_payload, tostring(state.off_package))
end

local function begin_round()
    state.scan_round = state.scan_round + 1
    local list, rst = collect_regions()
    state.regions = list
    state.region_bases = {}
    for i = 1, #list do state.region_bases[list[i].base] = true end
    state.region_collected_at = state.frames
    state.region_index = 1
    state.region_offset = 0
    state.previous = ""
    state.blocks = {}
    state.hits = {}
    state.seen = {}
    state.logged_rejections = 0
    state.scanned = 0
    state.region_count = #state.regions
    log(string.format("第 %d 轮%s:共 %d 个可读内存区(可读 %d 个;跳过 %d 个 < %d 字节、%d 个不可读)",
        state.scan_round, state.expand and "(补扫)" or "", #state.regions,
        (rst and rst.readable) or 0, (rst and rst.small) or 0, (rst and rst.min) or 0,
        (rst and rst.prot) or 0))
end

local function scan_step()
    if not state.regions then
        if state.frames < (state.next_round_frame or 0) then return end
        begin_round()
        return
    end
    -- ★ 一轮扫描可能持续十几秒,而游戏在这期间还会**继续分配内存**(实测第二批副本就是
    --   启动之后才出现的)。所以 region 列表要周期性重收,把新出现的内存区补到队尾 ——
    --   "启动阶段只收集一次 region 列表"正是漏掉一半区块的直接原因。
    if (state.frames - (state.region_collected_at or 0)) >= secs(CONFIG.region_refresh_sec) then
        state.region_collected_at = state.frames
        local list = collect_regions()
        local known = state.region_bases or {}
        local fresh = {}
        for i = 1, #list do
            if not known[list[i].base] then
                known[list[i].base] = true
                fresh[#fresh + 1] = list[i]
            end
        end
        state.region_bases = known
        table.sort(fresh, function(a, b) return a.size > b.size end)
        for i = 1, #fresh do
            state.regions[#state.regions + 1] = fresh[i]
        end
        if #fresh > 0 then
            state.region_count = #state.regions
            log(string.format("  region 列表刷新:新增 %d 个可读内存区(本轮共 %d 个)",
                #fresh, #state.regions))
        end
    end
    local budget = SCAN_BUDGET
    if state.frames < FAST_UNTIL_FRAME then budget = SCAN_BUDGET_FAST end
    local deadline = os.clock() + budget
    while os.clock() < deadline do
        local r = state.regions[state.region_index]
        if not r then finish_round(); return end
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
                        elseif state.hits and not state.warned_max_hits then
                            state.warned_max_hits = true
                            log("注意:签名命中已达上限 " .. MAX_HITS .. " 处,后面的命中不再记录(收全会漏)")
                        end
                        local ok, blk, why = pcall(ingest_strat_block, abs)
                        if ok and blk then
                            if #(state.blocks or {}) < MAX_BLOCKS then
                                state.blocks[#state.blocks + 1] = blk
                                log(string.format("区块 magic=0x%X count=%d hits=%d/%d via %s",
                                    blk.magic, blk.count, blk.hits, blk.count, blk.tag))
                            elseif not state.warned_max_blocks then
                                state.warned_max_blocks = true
                                log("注意:区块数已达上限 " .. MAX_BLOCKS .. " 个,后面的区块不再收(收全会漏)")
                            end
                        elseif CONFIG.verbose or (state.logged_rejections or 0) < 6 then
                            state.logged_rejections = (state.logged_rejections or 0) + 1
                            log(string.format("候选 0x%X 被拒:%s", abs, tostring(why)))
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

-- ----------------------------------------------- 飞鹰表扫描(时间切片) ------
local function eagle_begin()
    state.eagle_regions = collect_regions()
    state.eagle_ri = 1
    state.eagle_off = 0
    log(string.format("开始找 EagleComponentData(%d 个内存区)", #state.eagle_regions))
end

local function eagle_step()
    if state.eagle_found then return end
    if not state.eagle_regions then
        eagle_begin()
        return
    end
    local deadline = os.clock() + EAGLE_BUDGET
    local hits, found = 0, 0
    while os.clock() < deadline do
        local r = state.eagle_regions[state.eagle_ri]
        if not r then
            state.eagle_regions = nil
            state.last_eagle = string.format("hits=%d blocks=%d targets=%d", state.eagle_hits or 0,
                state.eagle_blocks or 0, state.eagle_targets and #state.eagle_targets or 0)
            if not state.eagle_found then
                log("这一轮没找到 EagleComponentData(实体表在飞船里常常不在,进任务后就有)")
            end
            return
        end
        local remaining = r.size - state.eagle_off
        if remaining <= 0 then
            state.eagle_ri = state.eagle_ri + 1
            state.eagle_off = 0
        else
            local want = SCAN_CHUNK
            if want > remaining then want = remaining end
            local buf = read_at(r.base + state.eagle_off, want)
            if buf then
                local from = 1
                while true do
                    local k = string.find(buf, EAGLE_SIG, from, true)
                    if not k then break end
                    local abs = r.base + state.eagle_off + k - 1
                    if not is_self(abs) then
                        hits = hits + 1
                        local ok, blk, why = pcall(ingest_eagle_block, abs)
                        if ok and blk then
                            found = found + #blk.addrs
                            state.eagle_targets = state.eagle_targets or {}
                            log(string.format("EagleComponentData magic=0x%X A=%d N=%d 命中 %d 个打击实体",
                                blk.magic, blk.A, blk.N, #blk.addrs))
                            for ai = 1, #blk.addrs do
                                local ent = blk.addrs[ai]
                                local dup = false
                                for i = 1, #state.eagle_targets do
                                    if state.eagle_targets[i].addr == ent.addr then dup = true; break end
                                end
                                if not dup then
                                    state.eagle_targets[#state.eagle_targets + 1] = ent
                                    local ok2, err = apply_eagle(ent.addr)
                                    if not ok2 and err ~= "already" then
                                        log(string.format("  打击实体 %s 打补丁失败:%s", ent.hash, tostring(err)))
                                    elseif ok2 then
                                        state.eagle_patched_entities = (state.eagle_patched_entities or 0) + 1
                                    end
                                end
                            end
                        elseif CONFIG.verbose or (state.eagle_rejections or 0) < 6 then
                            state.eagle_rejections = (state.eagle_rejections or 0) + 1
                            log(string.format("Eagle 候选 0x%X 被拒:%s", abs, tostring(why)))
                        end
                    end
                    from = k + 1
                end
            end
            state.eagle_off = state.eagle_off + want
        end
    end
    state.eagle_hits = (state.eagle_hits or 0) + hits
    if state.eagle_targets and #state.eagle_targets > 0 then
        state.eagle_found = true
        state.eagle_regions = nil
    end
end

-- ------------------------------------------------------------- loader 闸门 --
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

local function sync_status()
    local elapsed = "?"
    if state.t0 and os.time then
        local ok, now = pcall(os.time)
        if ok and now then elapsed = tostring(now - state.t0) end
    end
    local verdict
    if state.phase == "patched" then
        -- 注意:这里报的是"**实际会升空的架数**"(观测值),不是 payload 里写了几项 ——
        -- 实测引擎一次呼叫只升空 1 架,写 3 项也没用,所以 STATUS 不能骗人。
        local planes = CONFIG.bomb_planes
        if not planes or planes <= 0 then planes = state.flight end
        planes = math.max(1, planes or 1)
        verdict = "OK - Eagle Carpet Bomb ready (" .. tostring(planes) .. " aircraft x "
                  .. tostring(CONFIG.target_bombs or 0) .. " bombs; "
                  .. ((state.hijacked or 0) > 0 and ("slot " .. tostring(CONFIG.hijack_id) .. " converted)") or "own slot only)")
    elseif state.phase == "refused" then
        verdict = "FAILED - refused to write (send the log)"
    elseif state.phase == "gave_up" then
        verdict = "FAILED - StratagemSettings table never found (send the log)"
    elseif state.phase == "no_update" then
        verdict = "FAILED - global update() unavailable (Bingus Shared Loader too old?)"
    elseif state.phase == "bad_encoder" then
        verdict = "FAILED - internal f32 self-test failed (this build is broken, do not use)"
    elseif state.phase == "bad_loader" then
        verdict = "FAILED - Bingus Shared Loader too old: API " ..
                  tostring(state.loader and state.loader.api or "?") ..
                  "; this mod needs API 1 (loader v15+). Update it and restart the game."
    elseif state.phase == "located" then
        verdict = "WORKING - table found, applying the patch"
    else
        verdict = "WORKING - still scanning memory (check elapsed_s; right after launch this means nothing yet)"
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
        "aircraft_per_call=" .. tostring(state.flight) .. "  (" .. tostring(state.flight_reason) .. ")",
        "aircraft_actually_flying=" .. tostring(CONFIG.bomb_planes or state.flight)
            .. "  (引擎上限:一次呼叫只升空 1 架)",
        "warhead=" .. tostring(CONFIG.projectile_type)
            .. (CONFIG.projectile_type == 237 and " (500kg BOMB, 写死的值)" or CONFIG.projectile_type == 192 and " (200KG BOMB)" or ""),
        "warhead_resolved=" .. (state.warhead and state.warhead.id
            and (tostring(state.warhead.id) .. string.format(" (name 0x%08X, record %d, 得分 %d/%d, 物性 %d/%d)",
                 WARHEAD_NAME, state.warhead.record, state.warhead.score, WARHEAD_SCORE_MAX,
                 state.warhead.phys or 0, WARHEAD_PHYS_TOTAL))
            or ((state.warhead_done or state.warhead_failed)
                and ("FAILED - 还没解析出来,暂用写死的 " .. tostring(CONFIG.projectile_type)
                     .. " (每 " .. tostring(CONFIG.warhead_slow_retry_seconds or 120) .. " 秒重试;看日志)")
                or ("(解析中 —— 写死的 " .. tostring(CONFIG.projectile_type) .. " 暂用)"))),
        "warhead_scan=" .. tostring(state.last_warhead or "(scanning)"),
        "bombs_per_call=" .. tostring(CONFIG.target_bombs or 0)
            .. "  interval=" .. string.format("%.3f", bomb_interval_for(CONFIG.bomb_planes or state.flight)) .. "s",
        "carpet_geometry=run " .. string.format("%.0f", CONFIG.run_length) .. "m"
            .. "  length=speed*window=" .. string.format("%.0f", CONFIG.move_speed)
            .. "x" .. string.format("%.1f", CONFIG.fire_duration) .. "="
            .. string.format("%.0f", CONFIG.move_speed * CONFIG.fire_duration) .. "m"
            .. "  drop_starts " .. string.format("%.0f", CONFIG.fire_distance) .. "m before the beacon",
        "eagle_rearm=" .. tostring(CONFIG.eagle_rearm) .. "  (true = 次数用完飞鹰回舰装填,次数补满)",
        "payload_donor=" .. (state.donor
            and (tostring(state.donor.id) .. " @0x" .. string.format("%X", state.donor.ptr)
                 .. " count=" .. tostring(state.donor.count)
                 .. (state.donor.prepared and " (已写入)" or " (未写入)"))
            or "none"),
        "cooldown_target_display=" .. tostring(CONFIG.cooldown_seconds) .. "s",
        "cooldown_written_base=" .. string.format("%.1f", CONFIG.cooldown_base or 0) .. "s"
            .. "  (upgrade_factor=" .. tostring(CONFIG.upgrade_factor) .. ")",
        "hijacked_slot=" .. (CONFIG.hijack_id ~= 0
            and (tostring(CONFIG.hijack_id) .. " (copies=" ..
                 tostring(state.hijack_targets and #state.hijack_targets or 0) ..
                 ", patched=" .. tostring(state.hijacked or 0) .. ")")
            or "off"),
        "rounds=" .. tostring(state.scan_round or 0),
        "last_round=" .. tostring(state.last_round or "(no full scan finished yet)"),
        "records_last_round=" .. tostring(state.last_records or "?"),
        "scan_note=" .. (((state.last_records or 0) < (CONFIG.min_records or 40) * 2)
            and "只看到一套副本(实测完整是两套,16 区块/148 条);正在补扫" or "正常"),
        "expand_rounds=" .. tostring(state.expand_rounds or 0) .. "/" .. tostring(CONFIG.max_expand_rounds or 4),
        "regions=" .. tostring(state.region_count or 0) .. "  (最后收集于 frame "
            .. tostring(state.region_collected_at or 0) .. ")",
        "eagle_rearm_enum=" .. tostring(CONFIG.eagle_rearm_type)
            .. (state.rearm_observed and ("  (本构建实测 " .. tostring(state.rearm_observed.value) .. ", "
                .. tostring(state.rearm_observed.hits) .. "/" .. tostring(state.rearm_observed.total)
                .. " 条现役鹰系战备一致)") or "  (未交叉验证)"),
        "eagle_table=" .. tostring(state.last_eagle or "(scanning)"),
        "off_uses=" .. (state.off_uses and ("+" .. tostring(state.off_uses)) or "unknown"),
        "off_cd=" .. (state.off_cd and ("+" .. tostring(state.off_cd)) or "unknown"),
        "off_selectable=" .. (state.off_selectable and ("+" .. tostring(state.off_selectable)) or "unknown")
            .. (state.sel_rule and ("  rule=" .. SEL_RULES[state.sel_rule].name) or ""),
        "off_origin=" .. (state.off_origin and ("+" .. tostring(state.off_origin)) or "unknown"),
        "off_ctype=" .. (state.off_ctype and ("+" .. tostring(state.off_ctype)) or "unknown"),
        "off_payload=" .. (state.off_payload and ("+" .. tostring(state.off_payload)) or "unknown"),
        "off_package=" .. (state.off_package and ("+" .. tostring(state.off_package)) or "unknown"),
        "copies=" .. tostring(state.targets and #state.targets or 0),
        "patched_writes=" .. tostring(state.patched),
        "refusals=" .. tostring(state.refusals),
        "log=" .. tostring(out_dir) .. "/EagleCarpetBomb.log",
    }, NL) .. NL)
end

-- ============================================================================
--  弹头解析:到**活的** ProjectileSettings 表里按 name_upper 反查 ProjectileType
--
--  背景(实机 20:02-20:08 那次):飞机起飞了但一颗炸弹都不落。已证实同一台机器、
--  同一次更新之后 ProjectileType 201 变成了另一个完全不同的射弹 —— 枚举下标会被
--  版本回收(技能文档 6.26)。写死的 237 极可能也已经被回收,引擎拿到无效射弹 id
--  就生成不出炸弹。
--
--  name_upper 是本地化键的哈希,跨构建稳定,所以按它反查。
--  float 一律用纯 Lua 解码(绝不用 uint32_t[1] 走 "float*" 别名指针 —— 那种 type
--  punning 在记录热循环里会被 LuaJIT 缓存成陈旧值,实测把打分算错)。
-- ============================================================================

local function proj_f32_at(s, i)
    local bits = u32_at(s, i)
    if not bits then return nil end
    return f32_from_bits(bits)
end

-- 读出来的记录数组像不像真的:抽几条看 id 是不是小整数
local function proj_probe(ptr, cnt, stride)
    if ptr < 0x10000 or ptr >= 2 ^ 47 then return false, "指针越界" end
    local samples, sane = 6, 0
    for k = 0, samples - 1 do
        local idx = math.floor(k * cnt / samples)
        local rec = read_at(ptr + idx * stride, 8)
        if rec then
            local t = u32_at(rec, 1)
            if t and t < 20000 then sane = sane + 1 end
        end
    end
    if sane < samples - 1 then return false, "记录像噪声(" .. sane .. "/" .. samples .. ")" end
    return true
end

-- 接受一个 ProjectileSettings 块:只认 magic + ver + typeHash,步长从它自己的
-- DLArray 描述符**反推** —— 不再要求任何写死的表大小/记录数。
-- 描述符两种形态都试:内存里第一个 u64 是绝对指针,磁盘镜像里是相对偏移。
local function proj_validate_block(magic_address)
    local head = read_at(magic_address, 24)
    if not head then return nil, "不可读" end
    if head:sub(1, 4) ~= MAGIC then return nil, "不是 LDLD" end
    if u32_at(head, 5) ~= 1 then return nil, "version=" .. tostring(u32_at(head, 5)) end
    local typ = u32_at(head, 9)
    if typ ~= PROJ_TYPE_HASH then return nil, string.format("type=0x%08X", tonumber(typ) or 0) end
    local size = u32_at(head, 13)
    if not size or size < 1024 or size > 16777216 then return nil, "size=" .. tostring(size) end
    local desc = read_at(magic_address + PROJ_DESC_OFF, 16)
    if not desc then return nil, "描述符不可读" end
    local f1 = u64_at(desc, 1)
    local cnt = u64_at(desc, 9)
    if not f1 or not cnt then return nil, "描述符是 nil" end
    if cnt < PROJ_REC_MIN or cnt > PROJ_REC_MAX then return nil, "count=" .. tostring(cnt) end
    if (size - 16) % cnt ~= 0 then return nil, "步长除不尽" end
    local stride = math.floor((size - 16) / cnt)
    if stride < PROJ_STRIDE_MIN or stride > PROJ_STRIDE_MAX then return nil, "stride=" .. tostring(stride) end
    local cands = { f1, magic_address + PROJ_DESC_OFF + f1 }
    for i = 1, #cands do
        if proj_probe(cands[i], cnt, stride) then
            return { magic = magic_address, ptr = cands[i], count = cnt, stride = stride,
                     size = size, form = (i == 1 and "abs" or "rel") }
        end
    end
    return nil, "记录数组探测失败"
end

-- 一条记录对 "500kg BOMB" 的吻合度。-1 = name 对不上(直接否)。
-- 满分 16:name 是 pin,其余 6 项给出断层。
-- 返回 得分, 物性命中数, 不吻合项的说明。-1 分 = name 对不上(直接否)。
local function warhead_score(data, base)
    local function u32(o) return u32_at(data, base + o + 1) end
    local function f32(o) return proj_f32_at(data, base + o + 1) end
    local name = u32(P_NAME)
    if not name or name ~= WARHEAD_NAME then return -1, 0, "name 不符" end
    local speed, mass = f32(P_SPEED), f32(P_MASS)
    local drag, grav = f32(P_DRAG), f32(P_GRAV)
    local cal = f32(P_CALIBRE)
    local dmg, expl = u32(P_DAMAGE), u32(P_EXPL_IMPACT)
    local s, phys, parts = 0, 0, {}
    if speed and math.abs(speed - WARHEAD_IDENT.speed) < 0.5 then s = s + 3; phys = phys + 1
    else parts[#parts + 1] = "speed=" .. tostring(speed) end
    if mass and math.abs(mass - WARHEAD_IDENT.mass) < 0.5 then s = s + 3; phys = phys + 1
    else parts[#parts + 1] = "mass=" .. tostring(mass) end
    if cal and math.abs(cal - WARHEAD_IDENT.calibre) < 0.5 then s = s + 2; phys = phys + 1
    else parts[#parts + 1] = "calibre=" .. tostring(cal) end
    if drag and math.abs(drag - WARHEAD_IDENT.drag) < 0.01 then s = s + 1; phys = phys + 1
    else parts[#parts + 1] = "drag=" .. tostring(drag) end
    if grav and math.abs(grav - WARHEAD_IDENT.grav) < 0.01 then s = s + 1; phys = phys + 1
    else parts[#parts + 1] = "grav=" .. tostring(grav) end
    -- 弱提示:枚举会漂移,失配只丢 1 分,不算"不吻合"
    if dmg ~= WARHEAD_HINT.damage then
        parts[#parts + 1] = "dmg=" .. tostring(dmg) .. "(漂移,忽略)"
    else s = s + 1 end
    if expl ~= WARHEAD_HINT.expl then
        parts[#parts + 1] = "expl=" .. tostring(expl) .. "(漂移,忽略)"
    else s = s + 1 end
    return s, phys, (#parts > 0 and table.concat(parts, " ") or "全中")
end

local function proj_describe(data, base)
    return string.format("id=%s name=0x%08X speed=%s mass=%s drag=%s grav=%s calibre=%s damage=%s expl=%s",
        tostring(u32_at(data, base + P_ID + 1)),
        tonumber(u32_at(data, base + P_NAME + 1)) or 0,
        tostring(proj_f32_at(data, base + P_SPEED + 1)),
        tostring(proj_f32_at(data, base + P_MASS + 1)),
        tostring(proj_f32_at(data, base + P_DRAG + 1)),
        tostring(proj_f32_at(data, base + P_GRAV + 1)),
        tostring(proj_f32_at(data, base + P_CALIBRE + 1)),
        tostring(u32_at(data, base + P_DAMAGE + 1)),
        tostring(u32_at(data, base + P_EXPL_IMPACT + 1)))
end

-- 一次性把整张表落盘。
-- 下一步要靠它对答案:哪条是 500kg、写死的 237 现在指向谁、物性有没有一起漂移。
local function write_projectile_table(info)
    if state.proj_dump_done then return end
    local total = info.count * info.stride
    if total > 1048576 then return end
    local data = read_at(info.ptr, total)
    if not data then return end
    state.proj_dump_done = true
    local lines = {
        string.format("# ProjectileSettings @0x%X count=%d stride=%d size=%d via %s",
            info.magic, info.count, info.stride, info.size, info.form),
        "# idx\ttype_id\tname_upper\tcalibre\tspeed\tmass\tdrag\tgravity\tdamage\texpl_impact",
    }
    for i = 0, info.count - 1 do
        local b = i * info.stride
        lines[#lines + 1] = string.format("%d\t%s\t0x%08X\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
            i,
            tostring(u32_at(data, b + P_ID + 1)),
            tonumber(u32_at(data, b + P_NAME + 1)) or 0,
            tostring(proj_f32_at(data, b + P_CALIBRE + 1)),
            tostring(proj_f32_at(data, b + P_SPEED + 1)),
            tostring(proj_f32_at(data, b + P_MASS + 1)),
            tostring(proj_f32_at(data, b + P_DRAG + 1)),
            tostring(proj_f32_at(data, b + P_GRAV + 1)),
            tostring(u32_at(data, b + P_DAMAGE + 1)),
            tostring(u32_at(data, b + P_EXPL_IMPACT + 1)))
    end
    write_file("projectile_table.txt", table.concat(lines, NL) .. NL)
    log(string.format("  已导出整张射弹表 -> projectile_table.txt (%d 条,%d 字节)", info.count, total))
end

-- 在一张表里找 500kg 记录,判据:name 必须命中 + 物性主导 + 唯一最高分
local function warhead_pick(info)
    -- 注意:info.ptr 就是**记录数组本身**的地址(描述符里的指针),记录 0 在 data 的 +0,
    -- 不要再加描述符那 16 字节 —— 加了就会整体偏移一条,一条都匹配不上。
    local total = info.count * info.stride
    if total > 1048576 then return nil, "表太大(" .. tostring(total) .. ")" end
    local data = read_at(info.ptr, total)
    if not data then return nil, "记录区读不出来" end
    local id_map = {}
    local best_i, best, best_phys, best_detail, ties = nil, -1, 0, "", 0
    local named = {}
    for i = 0, info.count - 1 do
        local base = i * info.stride
        local s, phys, detail = warhead_score(data, base)
        local rid = u32_at(data, base + P_ID + 1)
        if rid then id_map[rid] = base end
        if s >= 0 then
            named[#named + 1] = { i = i, score = s, phys = phys, desc = proj_describe(data, base) }
            if s > best then
                best, best_i, best_phys, best_detail, ties = s, i, phys, detail, 1
            elseif s == best then
                ties = ties + 1
            end
        end
    end
    if best_i == nil then
        return nil, "没有任何记录带 name 0x" .. string.format("%08X", WARHEAD_NAME), id_map
    end
    if ties > 1 then
        local lines = {}
        for k = 1, #named do lines[#lines + 1] = string.format("  候选 record %d 得分 %d: %s",
            named[k].i, named[k].score, named[k].desc) end
        write_file("warhead_candidates.txt", table.concat(lines, NL) .. NL)
        return nil, ties .. " 条记录并列(候选清单已落盘 warhead_candidates.txt)", id_map
    end
    if best_phys < WARHEAD_PHYS_MIN or best < WARHEAD_SCORE_MIN then
        local lines = {}
        for k = 1, #named do lines[#lines + 1] = string.format("  候选 record %d 得分 %d (物性 %d/%d): %s",
            named[k].i, named[k].score, named[k].phys, WARHEAD_PHYS_TOTAL, named[k].desc) end
        write_file("warhead_candidates.txt", table.concat(lines, NL) .. NL)
        return nil, string.format(
            "最高分 %d/%d、物性 %d/%d,不到阈值(需 分>=%d、物性>=%d);不吻合的是: %s(候选清单已落盘)",
            best, WARHEAD_SCORE_MAX, best_phys, WARHEAD_PHYS_TOTAL,
            WARHEAD_SCORE_MIN, WARHEAD_PHYS_MIN, tostring(best_detail)), id_map
    end
    local rec_base = best_i * info.stride
    local rid = u32_at(data, rec_base + P_ID + 1)
    return { id = rid, record = best_i, score = best, phys = best_phys, detail = best_detail,
             desc = proj_describe(data, rec_base),
             count = info.count, stride = info.stride, magic = info.magic, form = info.form,
             data = data, id_map = id_map }
end

local function warhead_done_success(w)
    state.warhead_done = true
    state.warhead = w
    local old = CONFIG.projectile_type
    CONFIG.projectile_type = w.id
    log(string.format("弹头解析:name 0x%08X -> ProjectileType %d (record %d, 得分 %d/%d, 物性 %d/%d) " ..
        "@table 0x%X count=%d stride=%d via %s",
        WARHEAD_NAME, w.id, w.record, w.score, WARHEAD_SCORE_MAX,
        w.phys or 0, WARHEAD_PHYS_TOTAL, w.magic, w.count, w.stride, w.form))
    log("  实测: " .. w.desc)
    log("  判据: " .. tostring(w.detail))
    if w.id == old then
        log(string.format("  => 写死的 %d 至今仍然对得上 —— 枚举**没有**被回收,弹头 id 不是本次问题的原因", old))
    else
        log(string.format("  ★ 写死的 %d 已经对不上了;真正 500kg BOMB 的 id 是 %d,已改用它", old, w.id))
        if w.id_map and w.id_map[old] then
            log("     写死那个 id 现在指向: " .. proj_describe(w.data, w.id_map[old]))
        end
        state.warhead_reapply = true
    end
    pcall(sync_status)
end

local function warhead_begin()
    local list = collect_regions()
    state.warhead_regions = list
    state.warhead_ri = 1
    state.warhead_off = 0
    state.warhead_round = (state.warhead_round or 0) + 1
    state.warhead_hits = 0
    state.warhead_blocks_at_round_start = state.warhead_blocks or 0
    log(string.format("弹头解析:第 %d/%d 轮,扫 ProjectileSettings(0x%08X)…",
        state.warhead_round, CONFIG.warhead_max_rounds or 3, PROJ_TYPE_HASH))
end

local function warhead_step()
    if state.warhead_done or not state.warhead_regions then return end
    local deadline = os.clock() + WARHEAD_BUDGET
    local hits = 0
    while os.clock() < deadline do
        local r = state.warhead_regions[state.warhead_ri]
        if not r then
            state.warhead_regions = nil
            state.last_warhead = string.format("第 %d 轮:hits=%d blocks=%d",
                state.warhead_round or 0, (state.warhead_hits or 0) + hits, state.warhead_blocks or 0)
            if not state.warhead_done then
                local seen = (state.warhead_blocks or 0) - (state.warhead_blocks_at_round_start or 0)
                if seen > 0 then
                    -- 表找到了、只是没挑出 500kg 记录 —— 和"表根本不在内存里"是两回事,
                    -- 日志必须分清楚,否则下一轮又要重新侦察一遍。
                    log(string.format("弹头解析:第 %d 轮看到了 %d 张 ProjectileSettings,但没挑出 500kg 记录(拒绝原因见上)",
                        state.warhead_round or 0, seen))
                else
                    log(string.format("弹头解析:第 %d 轮根本没看到 ProjectileSettings(签名命中 %d 处)",
                        state.warhead_round or 0, (state.warhead_hits or 0) + hits))
                end
            end
            return
        end
        local remaining = r.size - state.warhead_off
        if remaining <= 0 then
            state.warhead_ri = state.warhead_ri + 1
            state.warhead_off = 0
        else
            local want = SCAN_CHUNK
            if want > remaining then want = remaining end
            local buf = read_at(r.base + state.warhead_off, want)
            if buf then
                local from = 1
                while true do
                    local k = string.find(buf, PROJ_SIG, from, true)
                    if not k then break end
                    local abs = r.base + state.warhead_off + k - 1
                    if not is_self(abs) then
                        hits = hits + 1
                        local info, why = proj_validate_block(abs)
                        if info then
                            state.warhead_blocks = (state.warhead_blocks or 0) + 1
                            log(string.format("  弹头表 magic=0x%X count=%d stride=%d via %s",
                                info.magic, info.count, info.stride, info.form))
                            pcall(write_projectile_table, info)
                            local w, why2 = warhead_pick(info)
                            if w then
                                state.warhead_hits = (state.warhead_hits or 0) + hits
                                warhead_done_success(w)
                                return
                            end
                            if not state.logged_warhead_reject then
                                state.logged_warhead_reject = true
                                log("  这张表没用: " .. tostring(why2))
                            end
                        elseif CONFIG.verbose or (state.warhead_rejections or 0) < 6 then
                            state.warhead_rejections = (state.warhead_rejections or 0) + 1
                            log(string.format("  弹头候选 0x%X 被拒:%s", abs, tostring(why)))
                        end
                    end
                    from = k + 1
                end
            end
            state.warhead_off = state.warhead_off + want
        end
    end
    state.warhead_hits = (state.warhead_hits or 0) + hits
end

-- 每个 tick 推进一步。解析完之后,如果已经用旧 id 打过 EagleComponent 就重打一遍。
local function warhead_tick()
    if not CONFIG.resolve_warhead then return end
    if state.warhead_done then
        if state.warhead_reapply then
            state.warhead_reapply = false
            local n = 0
            for i = 1, #(state.eagle_targets or {}) do
                local ok = apply_eagle(state.eagle_targets[i].addr)
                if ok then n = n + 1 end
            end
            if n > 0 then
                log(string.format("弹头 id 变更后,重打了 %d 个 EagleComponent(projectile=%d)",
                    n, CONFIG.projectile_type))
            end
        end
        return
    end
    if state.warhead_regions then
        warhead_step()
        return
    end
    local rounds = state.warhead_round or 0
    local fast = CONFIG.warhead_max_rounds or 8
    if rounds >= fast then
        -- ★ 不在飞船里放弃:ProjectileSettings 常要到任务里才常驻。
        -- 第一次越线时大声自查一次,之后限流 + 放慢,但**一直重试**。
        if not state.warhead_failed then
            state.warhead_failed = true
            log(string.format(
                "★ 弹头解析失败:扫了 %d 轮都没解析出 500kg(name 0x%08X)。最近一次: %s",
                rounds, WARHEAD_NAME, tostring(state.last_warhead or "?")))
            log("   自查: blocks=0 → 表不在内存里(在飞船里正常,进任务再看);" ..
                "blocks>0 却没挑出 → 判据问题,看 warhead_candidates.txt")
            log(string.format("   临时仍用写死的 %d;改为每 %d 秒慢速重试,不放弃",
                CONFIG.projectile_type, CONFIG.warhead_slow_retry_seconds or 120))
            pcall(sync_status)
        end
        local wait = secs(CONFIG.warhead_slow_retry_seconds or 120)
        if (state.frames - (state.last_warhead_round or -1e9)) >= wait then
            state.last_warhead_round = state.frames
            if (rounds % 5) == 0 then
                log(string.format("弹头解析:慢速重试第 %d 轮(最近一次 %s)",
                    rounds + 1, tostring(state.last_warhead or "?")))
            end
            warhead_begin()
        end
        return
    end
    if (state.frames - (state.last_warhead_round or -1e9)) >= secs(CONFIG.warhead_retry_seconds or 20) then
        state.last_warhead_round = state.frames
        warhead_begin()
    end
end

-- (注:secs() 定义已上移到"扫描驱动"一节开头 —— scan_step 也要用它算 region 刷新间隔,
--  而 Lua 的 local 必须先声明后使用,留在原地会让 scan_step 里读到一个 nil 全局。)

local function do_apply()
    local done, total = 0, 0
    for i = 1, #(state.targets or {}) do
        total = total + 1
        local rec = state.targets[i]
        local cur = read_at(rec.addr, RECORD_SIZE)
        if cur then
            rec.blob = cur
            rec.off = 1
            local ok, err = patch_carpet(rec)
            if ok then done = done + 1
            else log(string.format("战备副本 0x%X 失败:%s", rec.addr, tostring(err))) end
        else
            log(string.format("战备副本 0x%X 不可读", rec.addr))
        end
    end
    for i = 1, #(state.hijack_targets or {}) do
        local rec = state.hijack_targets[i]
        local cur = read_at(rec.addr, RECORD_SIZE)
        if cur then
            rec.blob = cur
            rec.off = 1
            local ok, err = apply_hijack(rec)
            if not ok and err ~= "already" then
                log(string.format("借壳副本 0x%X 失败:%s", rec.addr, tostring(err)))
            end
        end
    end
    -- 打完补丁立刻再 dump 一次:证明"我们写进去的"和"运行期内存里真实存在的"一致
    if done > 0 then dump_watch(state.records, "_after") end
    if total > 0 and done == total then
        state.phase = "patched"
        state.failed_apply = 0
    elseif done == 0 then
        -- 连续失败就停手,别每 5 秒刷一次日志、也别一直重试
        state.failed_apply = (state.failed_apply or 0) + 1
        if state.failed_apply >= 40 and state.patched == 0 then
            state.phase = "refused"
            log("连续 " .. state.failed_apply .. " 轮打补丁都没成功,停止重试(见上面的失败原因)")
        end
    else
        state.failed_apply = 0
    end
    return done, total
end

local function recheck()
    local targets = state.targets
    if not targets or #targets == 0 then
        state.phase = "scanning"
        state.regions = nil
        return
    end
    local alive = {}
    for i = 1, #targets do
        if read_at(targets[i].addr, RECORD_SIZE) then alive[#alive + 1] = targets[i] end
    end
    if #alive == 0 then
        log("所有战备副本都失效了,重新全量扫描")
        state.targets = {}
        state.phase = "scanning"
        state.regions = nil
        return
    end
    state.targets = alive

    -- ★ 这里原来是"一串 need = true",日志里只说"重新打上 N 份",**看不出是哪个字段**。
    --   现在把每条判据的原因收集起来,每个副本**只打印一次**(判据组合变了才再打印),
    --   下一轮实机直接看这一行就知道是谁在恒为真。
    local redone, already = 0, 0
    for i = 1, #alive do
        local rec = alive[i]
        local cur = read_at(rec.addr, RECORD_SIZE)
        if cur then
            local why = {}
            local selb = cur:byte(state.off_selectable + 1)
            local p_ptr = u64_at(cur, state.off_payload + 1)
            if p_ptr then
                local e0 = read_at(p_ptr, 8)
                local cnt = u32_at(cur, state.off_payload + 9)
                if not is_our_strike(e0) then
                    why[#why + 1] = string.format("payload[0]=%s 期望 %s(我们的打击实体)",
                        (e0 and to_hex(e0):upper()) or "读不到", EAGLE_STRIKE_HEX)
                end
                if cnt ~= state.flight and cnt ~= state.desired_pcount then
                    why[#why + 1] = string.format("payload_count=%s 期望 %s",
                        tostring(cnt), tostring(state.desired_pcount or state.flight))
                end
                -- ★ 恒为真的元凶就在这一条:原来只写 state.donor.prepared,于是"**自己数组**"
                --   的那份副本(它故意不指向 donor)永远判成"需要重打";而 patch_carpet 的准入
                --   条件里没这一条,所以它每次都回 "already" —— 什么都不写、却每 5 秒刷一行。
                --   现在只有"这份副本确实被重指向到 donor 数组"才要求 p_ptr == donor.ptr。
                if rec.used_donor_array and state.donor and p_ptr ~= state.donor.ptr then
                    why[#why + 1] = string.format("payload_ptr=0x%X 期望 donor 0x%X", p_ptr, state.donor.ptr)
                end
            else
                why[#why + 1] = "payload 描述符指针读不出来(NULL/越界)"
            end
            if CONFIG.enable_stratagem and not sel_is_on(selb) then
                why[#why + 1] = string.format("selectable=0x%02X 未打开(规则 %s)",
                    selb or 0, SEL_RULES[state.sel_rule or 1].name)
            end
            local org_now = u32_at(cur, state.off_origin + 1)
            if CONFIG.make_ship_available and org_now ~= 0 then
                why[#why + 1] = string.format("origin_type=%s 期望 0", tostring(org_now))
            end
            local ct_now = u32_at(cur, state.off_ctype + 1)
            if CONFIG.individual_cooldown and ct_now ~= 0 then
                why[#why + 1] = string.format("cooldown_type=%s 期望 0", tostring(ct_now))
            end
            if #why > 0 then
                rec.blob = cur
                rec.off = 1
                local ok, res = patch_carpet(rec)
                if ok then
                    if res == "already" then already = already + 1 else redone = redone + 1 end
                end
                local key = table.concat(why, " + ")
                state.need_logged = state.need_logged or {}
                if state.need_logged[rec.addr] ~= key then
                    state.need_logged[rec.addr] = key
                    state.need_log_lines = (state.need_log_lines or 0) + 1
                    if state.need_log_lines <= (CONFIG.need_log_limit or 64) then
                        log(string.format("复查:副本 0x%X 需要重打 —— %s => %s", rec.addr, key,
                            ok and (res == "already" and "patch_carpet 判定已经打过(**没写入**;说明判据不一致)"
                                or "已重写") or ("失败:" .. tostring(res))))
                    end
                end
            else
                if state.need_logged then state.need_logged[rec.addr] = nil end
            end
        end
    end
    if redone > 0 then log("复查:重新打上 " .. redone .. " 份战备副本") end
    if already > 0 and not state.warned_already then
        state.warned_already = true
        log(string.format("复查:有 %d 份副本被判成「需要重打」,但 patch_carpet 认为已经打过(没写入)—— "
            .. "看上一行的原因,那是判据不一致,不是游戏把它改回去了", already))
    end

    -- 借壳那边也要复查(同样带原因诊断)
    for i = 1, #(state.hijack_targets or {}) do
        local rec = state.hijack_targets[i]
        local cur = read_at(rec.addr, RECORD_SIZE)
        if cur and state.carpet_identity then
            local hwhy = {}
            local p_ptr = u64_at(cur, state.off_payload + 1)
            if not p_ptr then
                hwhy[#hwhy + 1] = "payload 描述符指针读不出来(NULL/越界)"
            else
                local e0 = read_at(p_ptr, 8)
                if not is_our_strike(e0) then
                    hwhy[#hwhy + 1] = string.format("payload[0]=%s 不是我们的打击实体",
                        (e0 and to_hex(e0):upper()) or "读不到")
                end
            end
            local desc = state.off_description and u32_at(cur, state.off_description + 1)
            if desc ~= state.carpet_identity.description then
                hwhy[#hwhy + 1] = string.format("description=%s 期望 %s",
                    tostring(desc), tostring(state.carpet_identity.description))
            end
            local cd_now = u32_at(cur, state.off_cd + 1)
            if cd_now ~= CD_BITS then
                hwhy[#hwhy + 1] = string.format("cooldown=0x%08X 期望 0x%08X", cd_now or 0, CD_BITS or 0)
            end
            local want_addl = CONFIG.eagle_rearm and CONFIG.eagle_rearm_type or 0
            local addl_now = u32_at(cur, OFF_ADDL_STRAT + 1)
            if addl_now ~= want_addl then
                hwhy[#hwhy + 1] = string.format("additional_stratagem=%s 期望 %s",
                    tostring(addl_now), tostring(want_addl))
            end
            if #hwhy > 0 then
                rec.blob = cur
                rec.off = 1
                local ok, res = apply_hijack(rec)
                local key = table.concat(hwhy, " + ")
                state.need_logged = state.need_logged or {}
                if state.need_logged[rec.addr] ~= key then
                    state.need_logged[rec.addr] = key
                    log(string.format("复查:借壳副本 0x%X 需要重打 —— %s => %s", rec.addr, key,
                        ok and (res == "already" and "已经打过(没写入)" or "已重写")
                        or ("失败:" .. tostring(res))))
                end
            else
                if state.need_logged then state.need_logged[rec.addr] = nil end
            end
        end
    end

    -- 飞鹰打击实体快速复查(直接读 4 字节 payload 枚举,开销 < 100 纳秒)
    for i = 1, #(state.eagle_targets or {}) do
        local ent = state.eagle_targets[i]
        local cur = read_at(ent.addr + 16, 4)
        if cur and u32_at(cur, 1) ~= EAGLE_PAYLOAD_CARPET then
            apply_eagle(ent.addr)
        end
    end
    if state.patched > 0 then state.phase = "patched" end
end

local function tick()
    if state.phase == "bad_loader" or state.phase == "no_update" then return end

    if state.status_phase ~= state.phase then
        state.last_status = state.frames
        state.status_phase = state.phase
        sync_status()
    end

    -- ★ 弹头 id 必须先解析出来再谈打补丁:写死的枚举下标可能已被版本回收。
    --   放在最前面,是因为它在 gave_up / refused 状态下也要继续推进 ——
    --   "主表没找到" 和 "弹头 id 对不对" 是两件独立的事。
    if not state.warhead_done or state.warhead_reapply then
        pcall(warhead_tick)
    end

    -- ★ "放弃"不再是终点:实测表是**分批加载**的,启动太早的那一轮很容易一无所获。
    --   保留 gave_up 这个状态(不刷屏、不扫),但按 deep_seconds 的节奏重新开一轮 ——
    --   重新打开时必须清掉 regions(强制重新收集 region 列表)。
    if state.phase == "gave_up" then
        if (state.frames - (state.last_retry or 0)) >= secs(CONFIG.deep_seconds) then
            state.last_retry = state.frames
            state.remap_round = (state.remap_round or 0) + 1
            state.empty_rounds = 0
            state.next_round_frame = nil
            state.regions = nil
            state.phase = "scanning"
            log("gave_up 之后重新开一轮扫描(第 " .. state.remap_round .. " 次重试)")
        end
        return
    end

    -- refused 也是硬停(不刷屏),但"表还没加载出来"这种情况下一轮可能就有了:
    -- 每 deep_seconds 允许重试一次,最多 3 次。真正危险的"命中却解析不出"那一种,
    -- finish_round 已经把原始字节落盘,重试不会更糟。
    if state.phase == "refused" then
        if (state.remap_round or 0) < 3
            and (state.frames - (state.last_retry or 0)) >= secs(CONFIG.deep_seconds) then
            state.last_retry = state.frames
            state.remap_round = (state.remap_round or 0) + 1
            state.regions = nil
            state.phase = "scanning"
            log("refused 之后重试一轮扫描(第 " .. state.remap_round .. "/3 次)")
        end
        return
    end

    if state.phase == "patched" or state.phase == "located" then
        if (state.frames - (state.last_recheck or 0)) >= secs(CONFIG.recheck_seconds) then
            state.last_recheck = state.frames
            if state.phase == "located" then do_apply() else recheck() end
        end
        if not state.eagle_found then
            if state.eagle_regions then
                eagle_step()          -- 正在扫:一直推进,别按冷却等
            elseif not state.last_eagle_try or (state.frames - state.last_eagle_try) >= secs(CONFIG.maintain_seconds or 10) then
                state.last_eagle_try = state.frames
                state.eagle_rounds = (state.eagle_rounds or 0) + 1
                eagle_step()
            end
        end
        -- 全字段复查(补 recheck 覆盖不到的字段:description / 图标 / 冷却 / call-in)
        if state.phase == "patched"
            and (state.frames - (state.last_sweep or 0)) >= secs(CONFIG.sweep_seconds) then
            state.last_sweep = state.frames
            local sd, st_total = do_apply()
            if sd > 0 and sd < (st_total or 0) then
                log(string.format("全字段复查:%d/%d 份副本被重写", sd, st_total))
            end
            -- 别把 do_apply 的"连续失败就停手(refused)"给覆盖掉:只有确实打过补丁才留在 patched
            if state.phase ~= "patched" and (state.patched or 0) > 0
                and (state.targets and #state.targets or 0) > 0 then
                state.phase = "patched"
            end
        end
        -- ★ 打上补丁**不等于**结束:另一整套副本往往是稍后才加载出来的(实测:一轮只看到
        --   8 个区块/74 条记录,完整的是 16 个/148 条)。先按 expand_seconds 连做几轮补扫,
        --   把新副本并进来一起打;之后交给 deep_seconds 全量兜底。补扫轮**不会**丢掉已打的副本。
        if state.phase == "patched" then
            local deep_due = CONFIG.deep_seconds and CONFIG.deep_seconds > 0
                and (state.frames - (state.last_deep or 0)) >= secs(CONFIG.deep_seconds)
            local expand_due = CONFIG.expand_seconds and CONFIG.expand_seconds > 0
                and (not deep_due)
                and (state.expand_rounds or 0) < (CONFIG.max_expand_rounds or 4)
                and (state.frames - (state.last_expand or 0)) >= secs(CONFIG.expand_seconds)
            if deep_due or expand_due then
                if deep_due then
                    state.last_deep = state.frames
                    state.expand_rounds = 0
                    log("定期全量重扫(兜底)")
                else
                    state.expand_rounds = (state.expand_rounds or 0) + 1
                    log(string.format("补扫 %d/%d 轮:找后加载出来的副本(已打 %d 份)",
                        state.expand_rounds, CONFIG.max_expand_rounds or 4,
                        state.targets and #state.targets or 0))
                end
                state.last_expand = state.frames
                state.expand = true
                state.regions = nil
                state.phase = "scanning"
            end
        end
    elseif state.phase ~= "refused" then
        scan_step()
    end
end

-- 反算:游戏显示 = 基础 x 系数,所以要让显示等于目标就得写 目标/系数
local cd_factor = tonumber(CONFIG.upgrade_factor) or 1.0
if cd_factor <= 0.05 then cd_factor = 1.0 end
CONFIG.cooldown_base = CONFIG.cooldown_seconds / cd_factor
CD_BITS = f32_bits(CONFIG.cooldown_base)
if not CD_BITS then
    print("[EagleCarpetBomb] 冷却位模式算不出来,退出")
    return
end

state.t0 = os.time and os.time() or nil
state.loader = probe_loader()
state.phase = "scanning"

do
    local okc, why = selftest_f32()
    if not okc then
        state.phase = "bad_encoder"
        log("REFUSED:f32 编码自检没过(" .. tostring(why) .. "),不写任何内存")
        pcall(function() sync_status() end)
        return { revision = state.revision, state = state }
    end
end

if state.loader.api ~= nil and state.loader.api < 1 then
    state.phase = "bad_loader"
    log(string.format("REFUSED:Bingus Shared Loader API = %d,本 mod 需要 API 1", state.loader.api))
    log("  请升级到 v15 或更新版本,然后完全退出游戏再重开。")
    pcall(function() sync_status() end)
    return { revision = state.revision, state = state }
end
if state.loader.api == nil then
    log("警告:没能确认 loader 的 API 等级,继续尝试。")
end

local original_update = update
if type(original_update) == "function" then
    local my_update
    my_update = function(...)
        state.frames = state.frames + 1
        local ready = (state.phase == "patched" and state.eagle_found)
        local cadence = ready and 60 or SCAN_EVERY
        local due = (state.frames % cadence) == 0
        if not state.retired and CONFIG.enabled and state.frames >= START_FRAME and due then
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
    log(state.revision .. ": 平稳扫描模式 (每步 2ms, frame >= " .. tostring(START_FRAME) .. ")")
    log(state.revision .. " armed; out_dir=" .. tostring(out_dir) ..
        "; flight_size=" .. tostring(CONFIG.flight_size) ..
        "; projectile=" .. tostring(CONFIG.projectile_type))
else
    state.phase = "no_update"
    log("全局 update 不可用,无法运行")
end
pcall(function() sync_status() end)

return { revision = state.revision, state = state }
