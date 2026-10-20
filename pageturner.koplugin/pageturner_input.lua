--[[--
翻页器的「设备接管」：找到翻页器这个输入设备、打开它、交给 KOReader 的输入系统（键码绑定在 main.lua，由用户自己绑）。

这段能力原来在 externalkeyboard.koplugin（KOReader 自带的外接键盘插件，
这台机器上被改造过）里，翻页器要能用必须靠它，所以以前是两个插件配套安装。
现在搬进翻页器插件自己，装一个就够。

一页翻页器要能翻页，链子是这样的：
    翻页器按键 -> KHP 守护进程变成虚拟键盘设备(/dev/input/eventX)
              -> 这里把设备打开、注册进 KOReader 输入系统
              -> 翻页生效

去掉的部分：原插件里那套 USB OTG 主机/从机角色切换，那是给「插 USB 线的实体键盘」
用的（Kobo 上才有）。Kindle 上没有对应接口，翻页器走蓝牙 + KHP 的虚拟设备，
根本用不到，留着只会多一堆写 /sys 的动作。
--]]

local Device = require("device")
local logger = require("logger")
local ffi = require("ffi")
require("ffi/posix_h")
require("ffi/fbink_input_h")

local Input = {}

-- 已经打开的设备：路径 -> fd。findEventPaths() 会来这里取路径。
Input.keyboard_fds = {}
Input.connected_keyboards = 0

-- 翻页器就这三个键（70 ScrollLock / 104 PageUp / 109 PageDown）。
-- KOReader 在 handleKeyBoardEv 里查 event_map 查不到就直接把事件丢掉 ——
-- 表现就是「按了等于没按」。插件自己的钩子会先接走这些键，这张表是兜底：
-- 钩子没接住的时候（不在阅读页、手势没凑成）KOReader 至少还认得这些键。
local PAGER_EVENT_MAP = {
    [70]  = "ScrollLock",
    [104] = "LPgBack",   -- PageUp
    [109] = "LPgFwd",    -- PageDown
}
local event_map_merged = false

--- 把翻页器键码并进 KOReader 的按键映射：只补空缺，不动机身已有的键。
function Input:ensureEventMap()
    if event_map_merged then return end
    local em = Device.input and Device.input.event_map
    if type(em) ~= "table" then return end
    for k, v in pairs(PAGER_EVENT_MAP) do
        if em[k] == nil then em[k] = v end
    end
    event_map_merged = true
    logger.info("[pageturner/input] pager event map merged")
end

-- 机身自带的那些输入设备，别去动（翻页器是后插进来的）。
-- 名字按真机上看到的写：Kindle 上电源键叫 bd71828-pwrkey、触摸屏叫 goodix-ts，
-- 光靠 "power" / "touchscreen" 匹配不上，结果这俩也被当成翻页器接管了 ——
-- 状态里显示「已接管 3 个设备」，其实只有一个是真翻页器。
local BUILTIN_PATTERNS = {
    "volume", "power", "pwrkey", "bd71828", "goodix", "cover", "hall", "button",
    "gpio", "touchscreen", "accelerometer",
}

local function isBuiltin(name)
    if not name then return false end
    local low = name:lower()
    for _, p in ipairs(BUILTIN_PATTERNS) do
        if low:find(p, 1, true) then return true end
    end
    return false
end

pcall(ffi.cdef, "int open(const char *pathname, int flags);")
local O_RDONLY   = 0
local O_NONBLOCK = 2048   -- Linux 上 ARM / x86 都是 0x800

--- 扫一遍系统里的键盘类输入设备。
-- 翻页器经 KHP 会变成一个 UHID 设备，混在这里面。
--
-- 两条路：先试 FBInk（原来 externalkeyboard 就是这么干的），
-- 拿不到就退回解析 /proc/bus/input/devices —— FBInk 只有电子墨水设备上才有，
-- 模拟器 / 某些机型上没有，那时候 FBInkInput 这个符号压根不存在，
-- 一访问就 "missing declaration for symbol"，整个接管就悄悄失败了。
-- cheap=true 只走 /proc/bus（不打开设备）：FBInk 的 scan 会把扫到的设备都 open 一遍，
-- 定时重扫用它的话每扫一轮就漏几个 fd。留给首次接管用。
function Input:findKeyboards(cheap)
    if not cheap then
        local ok, list = pcall(function() return self:scanWithFBInk() end)
        if ok and type(list) == "table" and #list > 0 then return list end
    end
    return self:scanProcBus()
end

function Input:scanWithFBInk()
    local FBInkInput = ffi.C.FBInkInput
    local devices = FBInkInput.scan("INPUT_KEYBOARD")
    if not devices then return {} end
    local out = {}
    local n = tonumber(devices.count) or 0
    for i = 0, n - 1 do
        local dev = devices.devices[i]
        if dev then
            local name = ffi.string(dev.name)
            -- FBInk 会把机身自带的电源键、触摸屏一起报上来，这里同样要滤掉：
            -- 不然它们照样被接管（还多占一个 fd），状态里又变成好几个设备。
            if not isBuiltin(name) then
                out[#out + 1] = {
                    event_path = ffi.string(dev.path),
                    event_fd = tonumber(dev.fd) or -1,
                    name = name,
                }
            end
        end
    end
    return out
end

--- 兜底：读 /proc/bus/input/devices，挑出带 event 节点、又不是机身自带的设备。
function Input:scanProcBus()
    local out = {}
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then return out end
    local name
    for line in f:lines() do
        local n = line:match('^N:%s*Name="([^"]*)"')
        if n then name = n end
        local h = line:match("^H:%s*Handlers=(.*)")
        if h then
            local ev = h:match("(event%d+)")
            if ev and name and not isBuiltin(name) then
                out[#out + 1] = {
                    event_path = "/dev/input/" .. ev,
                    event_fd = -1,
                    name = name,
                }
            end
        end
    end
    f:close()
    return out
end

--- 这个 fd 还活着吗？
-- 关蓝牙 / 翻页器待机时 KHP 会把虚拟设备删掉，路径（/dev/input/event2）还在、
-- 我们表里的记录也还在，但那个 fd 早就是死的了。不验一下的话，
-- 再开蓝牙时新设备用同一个路径建出来，我们却以为「已经打开过」直接跳过，
-- 结果按键一个都收不到 —— 表现就是「显示连上了，按了没反应」。
pcall(ffi.cdef, "ssize_t readlink(const char *path, char *buf, size_t bufsiz);")

local function fdAlive(fd)
    if type(fd) ~= "number" or fd <= 0 then return false end
    -- 用 ffi 直接 readlink，不要 io.popen：那会 fork 一个 shell，
    -- 而这个检查每轮扫描对每个设备都要做一次，fork 出来的动静
    -- （日志里刷屏的 "Unknown HZ value!" 就是它）比检查本身贵多了。
    local buf = ffi.new("char[256]")
    local n = ffi.C.readlink("/proc/self/fd/" .. tostring(fd), buf, 256)
    if not n or n <= 0 then return false end
    local target = ffi.string(buf, n)
    -- "(deleted)" = 设备已经被删了，这个 fd 是具尸
    if target:find("(deleted)", 1, true) then return false end
    return true
end

--- 把已经失效的记录清掉（设备被删了但我们还记着）
function Input:pruneDead()
    local n = 0
    for path, fd in pairs(self.keyboard_fds) do
        if not fdAlive(fd) then
            self.keyboard_fds[path] = nil
            n = n + 1
        end
    end
    if n > 0 then
        local alive = 0
        for _ in pairs(self.keyboard_fds) do alive = alive + 1 end
        self.connected_keyboards = alive
        logger.info("[pageturner/input] pruned " .. n .. " dead device(s)")
    end
    return n
end

--- 打开一个设备并登记到 KOReader 的输入系统。
function Input:setupKeyboard(data)
    if not data or not data.event_path then return false end
    local path = data.event_path

    local old = self.keyboard_fds[path]
    if old then
        if fdAlive(old) then return true end      -- 真的还开着，不用重复开
        -- 记录还在但 fd 已经死了：清掉，下面重新开一遍
        self.keyboard_fds[path] = nil
        self.connected_keyboards = math.max(0, (self.connected_keyboards or 1) - 1)
        -- KOReader 那边也别再以为这个设备还开着
        if Device.input and Device.input.opened_devices then
            Device.input.opened_devices[path] = nil
        end
    end

    self:ensureEventMap()

    -- FBInk 那条路会顺便带一个已经打开的 fd；从 /proc/bus 兜底扫出来的只有路径，
    -- 得自己开一个。
    local fd = data.event_fd
    if type(fd) ~= "number" or fd <= 0 then
        fd = ffi.C.open(path, O_RDONLY + O_NONBLOCK)
    end
    if type(fd) ~= "number" or fd < 0 then
        logger.warn("[pageturner/input] 打不开设备 " .. tostring(path))
        return false
    end

    local ok, err = pcall(function() Device.input:fdopen(fd, path, data.name) end)
    if not ok then
        logger.warn("[pageturner/input] fdopen 失败 " .. tostring(path) .. ": " .. tostring(err))
        return false
    end

    self.keyboard_fds[path] = fd
    self.connected_keyboards = (self.connected_keyboards or 0) + 1
    logger.info(string.format("[pageturner/input] device attached: %s (%s) fd=%s",
        tostring(path), tostring(data.name), tostring(fd)))

    -- 让 Device 知道自己现在有键盘了（否则 KOReader 某些地方不认按键）
    Device.hasKeyboard = function() return true end
    Device.hasKeys = function() return true end
    if not Device.canKeyRepeat then
        Device.canKeyRepeat = function() return false end
    end
    if not Device.hasDPad then
        Device.hasDPad = function() return false end
    end
    if not Device.hasExitOptions then
        Device.hasExitOptions = function() return true end
    end
    return true
end

--- 扫一遍，把还没接管的设备接上。启动时、守护进程拉起后、自愈时都会调。
function Input:findAndSetupKeyboards(cheap)
    self:pruneDead()
    local found = self:findKeyboards(cheap)
    local n = 0
    for _, data in ipairs(found) do
        if self:setupKeyboard(data) then n = n + 1 end
    end
    return n, #found
end

--- 设备热插拔：翻页器待机/重连时会被 KHP 删掉再建出来。
function Input:onInsert(path)
    if not path then return end
    local old = self.keyboard_fds[path]
    if old then
        -- 记着这个路径不代表设备还活着：翻页器待机重连时 KHP 会把设备删掉再建出来，
        -- 我们手里的 fd 已经是死的。以前这里直接 return，新建出来的设备就再也没人
        -- 接管 —— 状态里还挂着这个设备，按下去却一个反应都没有。
        if fdAlive(old) then return end
        self.keyboard_fds[path] = nil
        if Device.input and Device.input.opened_devices then
            Device.input.opened_devices[path] = nil
        end
    end
    -- KHP 建出设备到它可用之间有点延迟，等一下再扫
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.5, function()
        for _, data in ipairs(self:findKeyboards(true)) do
            if data.event_path == path then
                self:setupKeyboard(data)
                break
            end
        end
    end)
end

function Input:onRemove(path)
    if not path then return end
    if self.keyboard_fds[path] then
        self.keyboard_fds[path] = nil
        self.connected_keyboards = math.max(0, (self.connected_keyboards or 1) - 1)
        logger.info("[pageturner/input] device detached: " .. tostring(path))
    end
end

--- 给外部（自愈循环、状态显示）用的查询
function Input:openPaths()
    local paths = {}
    for path in pairs(self.keyboard_fds) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    return paths
end

function Input:isOpen(path)
    return path ~= nil and self.keyboard_fds[path] ~= nil
end

return Input
