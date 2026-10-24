--[[--
翻页器 (pageturner.koplugin)：蓝牙翻页器 + 想法选择器。首次使用先在菜单里「绑定翻页器按键」，
依次为三个动作各录一个手势：下一个、上一个、确认。手势 = 翻页器的某个键 + 怎么按：
单击 / 连按两次 / 连按三次 / 长按。几个键、怎么分配由你自己定，例如：
  三键翻页器   三个键各按一下
  双键翻页器   两个键各按一下，确认录成某个键连按两次
  单键翻页器   单击=下一个，双击=上一个，三击=确认
长按只在翻页器按住期间真的不松开时才有（不少翻页器按下松开是同时发的，录不到长按）。
同一个键上绑了连按的话，单击要多等一小会儿才能确认不是连按。

  确认      进入选择模式 → 当前页第一条想法（段评 / 带笔记的划线）高亮
  下一个    选下一条
  上一个    选上一条
  确认      打开选中项
  弹窗里：下一个 / 上一个滚动内容，确认关闭并回到正常读书

翻页自动退出选择模式。菜单：齿轮 -> 网络 -> 翻页器
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Device = require("device")
local logger = require("logger")
local util = require("ffi/util")
local ffi = require("ffi")

pcall(ffi.cdef, "int getpid(void);")
pcall(ffi.cdef, "int close(int);")

-- 模块名必须带 pageturner_ 前缀：require 先查 package.loaded，撞上 KOReader 自带的
-- 同名模块（如 input）会直接返回那个表，不报错但方法一个都没有。
local Input = require("pageturner_input")
local Moon = require("pageturner_moon")
local T = require("pageturner_l10n")
local Thoughts = require("pageturner_thoughts")

local PageTurner = WidgetContainer:extend{
    name = "pageturner",
    is_doc_only = false,
}

local DEFAULTS = {
    auto_connect     = true,
    keep_awake       = true,
    last_pager_addr  = "",
    binds            = {},   -- 动作 -> 手势 { code = 键码, kind = 1 / 2 / 3（连按次数）或 "long" }
}

local KHP_DIR = "/mnt/us/kindle_hid_passthrough"
local BT_LOG = "/var/log/hid_passthrough.log"
local HEAL_COOLDOWN = 60

-- 翻页器的按键由用户在菜单里「学习」绑定：对每个动作录一次手势（键码 + 单击 / 连按 / 长按）。
-- 所有绑定的键都由我们的钩子接管（不进 event_map）：下一个 / 上一个在正常读书时就是翻页。
local ACTIONS = {
    { key = "next", label = T("下一个"), step = 1 },
    { key = "prev", label = T("上一个"), step = -1 },
    { key = "ok",   label = T("确认") },
}
local TAP_GAP = 0.5      -- 连按判定窗口：两次按下间隔在这个数以内算连按
local LONG_PRESS = 0.5
local DEBOUNCE = 0.08    -- 见 feed()：一个动作被发成两次按下时只算一次
local MAX_TAPS = 3
local LEARN = { max = MAX_TAPS, long = true } -- 录手势时什么都认

local current -- 当前阅读页上的实例，按键钩子只服务它
local gestures = {} -- 键码 -> { max = 最大连按数, long = 有没有长按, act = { [kind] = 动作 } }
local capture -- 绑定向导等待下一个手势的回调
local states = {} -- 键码 -> 手势识别状态
local hooked, rescanning, healing = false, false, false
local last_taken -- 上次接管到几个设备，只在变化时写日志

------------------------------------------------------------------------------
-- 设置
------------------------------------------------------------------------------

function PageTurner:loadSettings()
    local saved = G_reader_settings:readSetting("pageturner") or {}
    self.settings = {}
    for k, v in pairs(DEFAULTS) do
        if saved[k] ~= nil then self.settings[k] = saved[k] else self.settings[k] = v end
    end
    local old = saved.keys
    if saved.binds == nil and old and next(old) then -- 旧版：按类型 + 键码
        local b = self.settings.binds
        if saved.mode == "single" then
            local c = old.main
            b.next, b.prev, b.ok = { code = c, kind = 1 }, { code = c, kind = 2 }, { code = c, kind = 3 }
        else
            b.next, b.prev = { code = old.next, kind = 1 }, { code = old.prev, kind = 1 }
            if saved.mode == "dual" then
                b.ok = { code = old.next, kind = 2 }
            else
                b.ok = { code = old.ok or old.double, kind = 1 }
            end
        end
    end
end

function PageTurner:saveSettings()
    G_reader_settings:saveSetting("pageturner", self.settings)
end

function PageTurner:toggle(key)
    self.settings[key] = not self.settings[key]
    self:saveSettings()
end

--- 按设置重建手势表。
function PageTurner:applyBindings()
    gestures, states = {}, {}
    for _idx, a in ipairs(ACTIONS) do
        local b = self.settings.binds[a.key]
        if b and b.code then
            local g = gestures[b.code] or { max = 0, act = {} }
            gestures[b.code] = g
            g.act[b.kind] = a.key
            if b.kind == "long" then g.long = true else g.max = math.max(g.max, b.kind) end
        end
    end
end

local function gestureName(b)
    if not b then return T("未绑定") end
    local how = b.kind == "long" and T("长按") or (b.kind == 1 and T("单击") or T("连按%d下", b.kind))
    return T("键 %d %s", b.code, how)
end

--- 绑定向导：逐个动作录手势；走完才整体生效，中途放弃不改旧绑定。
function PageTurner:bind(step, binds)
    local a = ACTIONS[step]
    if not a then
        capture = nil
        self.settings.binds = binds
        self:applyBindings()
        self:saveSettings()
        UIManager:show(InfoMessage:new{ text = T("按键绑定完成"), timeout = 2 })
        return
    end
    local msg
    capture = function(code, kind)
        capture = nil
        UIManager:close(msg)
        for _idx, taken in pairs(binds) do
            if taken.code == code and taken.kind == kind then
                UIManager:show(InfoMessage:new{ text = T("这个手势已经绑过了，请换一个"), timeout = 2 })
                return self:bind(step, binds)
            end
        end
        binds[a.key] = { code = code, kind = kind }
        UIManager:show(InfoMessage:new{ text = T("「%s」= %s", a.label, gestureName(binds[a.key])), timeout = 1.5 })
        UIManager:scheduleIn(1.6, function() self:bind(step + 1, binds) end)
    end
    local mine = capture
    msg = InfoMessage:new{
        text = T("请在翻页器上做出「%s」的动作（%d/%d）\n单击 / 连按 2~3 下 / 长按都行，做完稍等", a.label, step, #ACTIONS),
        timeout = 20,
        dismiss_callback = function() if capture == mine then capture = nil end end,
    }
    states = {}
    UIManager:show(msg)
end

------------------------------------------------------------------------------
-- 守护进程与设备接管
------------------------------------------------------------------------------

function PageTurner:daemonRunning()
    local p = io.popen("ps -ef | grep -c '[m]ain.bin'")
    local out = p:read("*a")
    p:close()
    return (tonumber(out) or 0) > 0
end

function PageTurner:ensureDaemon()
    local bin = io.open(KHP_DIR .. "/dist/main.bin", "r")
    if not bin then return end
    bin:close()
    if self:daemonRunning() then return end
    os.execute("cd " .. KHP_DIR .. " && setsid ./dist/ld-linux-armhf.so.3" ..
        " --library-path ./dist ./dist/main.bin --daemon >>" .. BT_LOG .. " 2>&1 &")
    logger.info("[pageturner] daemon started")
end

--- 月读里开了蓝牙：守护进程由月读拉起（不能两边同时拉，两个进程会抢蓝牙），
-- 这里只等它起来（5 秒）再接管设备。
function PageTurner:onMoonBluetoothOn()
    if self._moon_on_pending then return end
    self._moon_on_pending = true
    UIManager:scheduleIn(5, function()
        self._moon_on_pending = false
        self:takeOverAll()
    end)
end

function PageTurner:takeOverAll(cheap)
    local ok, n = pcall(Input.findAndSetupKeyboards, Input, cheap)
    if not ok then
        logger.warn("[pageturner] takeover failed: " .. tostring(n))
        return 0
    end
    if n ~= last_taken then logger.info("[pageturner] took over " .. n .. " device(s)") end
    last_taken = n
    return n
end

function PageTurner:hasDevice()
    return #Input:openPaths() > 0
end

-- KHP 在翻页器待机 / 重连时会删掉再重建虚拟键盘设备，跟着重新接管。
function PageTurner:onEvdevInputInsert(path) Input:onInsert(path) end
function PageTurner:onEvdevInputRemove(path) Input:onRemove(path) end

--- 每 10 秒扫一遍：清掉死掉的 fd、把重新出现的翻页器接上。
-- 不能「接到一个就停」：机身自带的设备会让第一次扫描结果 >0，循环立刻退出，
-- 之后翻页器一待机重连就再也没人接管了 —— 只剩状态里那行「已接管 N 个设备」在骗人。
-- 走 cheap 扫描（不开 fd），一轮就一两次 readlink，可以一直跑。
function PageTurner:startRescanLoop()
    if rescanning then return end
    rescanning = true
    local function loop()
        UIManager:scheduleIn(10, function()
            self:takeOverAll(true)
            loop()
        end)
    end
    loop()
end

--- 设备被重建后，我们手里的 fd 还指向已删除的节点：关掉它并重新接管。
function PageTurner:healFd()
    local now = os.time()
    if self._last_heal_at and now - self._last_heal_at < HEAL_COOLDOWN then return end
    local pid = ffi.C.getpid()
    for _idx, dev in ipairs(Input:findKeyboards(true)) do
        local path = dev.event_path
        local cmd = string.format(
            'for f in /proc/%d/fd/*; do t=$(readlink "$f" 2>/dev/null); ' ..
            'case "$t" in *"%s (deleted)"*) echo "${f##*/}";; esac; done 2>/dev/null',
            pid, path:match("[^/]+$"))
        local p = io.popen(cmd)
        local fds = {}
        for line in p:lines() do fds[#fds + 1] = tonumber(line) end
        p:close()
        if #fds > 0 then
            for _idx2, fd in ipairs(fds) do ffi.C.close(fd) end
            if Device.input.opened_devices then Device.input.opened_devices[path] = nil end
            Input:onRemove(path)
            UIManager:broadcastEvent(Event:new("EvdevInputInsert", path))
            self._last_heal_at = now
            logger.info("[pageturner] healed " .. path)
        end
    end
end

function PageTurner:startFdHealLoop()
    if healing then return end
    healing = true
    local function loop()
        UIManager:scheduleIn(30, function()
            self:healFd()
            loop()
        end)
    end
    loop()
end

------------------------------------------------------------------------------
-- 想法选择器
------------------------------------------------------------------------------

local function unionGeom(boxes)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _idx, b in ipairs(boxes) do
        x0, y0 = math.min(x0, b.x), math.min(y0, b.y)
        x1, y1 = math.max(x1, b.x + b.w), math.max(y1, b.y + b.h)
    end
    return Geom:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

--- 只刷高亮涉及的那一块，整屏标脏会闪。
function PageTurner:refresh(boxes)
    if boxes then UIManager:setDirty("all", "ui", unionGeom(boxes)) end
end

--- 选中项反白（底黑字白）；昼夜、颜色都不用管。
function PageTurner:paintSelection(bb)
    for _idx, b in ipairs(self.boxes or {}) do bb:invertRect(b.x, b.y, b.w, b.h) end
end

function PageTurner:select(idx)
    local old = self.boxes
    self.idx = idx
    self.boxes = self.items[idx].boxes
    self:refresh(old)
    self:refresh(self.boxes)
end

--- 回到正常读书：清高亮、清状态。
function PageTurner:exit()
    local old = self.boxes
    self.mode, self.items, self.idx, self.boxes, self.base = nil, nil, nil, nil, nil
    self:refresh(old)
end

--- 弹窗：打开想法那一刻之后新增的最上层窗口。
function PageTurner:popup()
    local stack = UIManager._window_stack
    if #stack > self.base then return stack[#stack].widget end
end

function PageTurner:closePopup()
    local stack = UIManager._window_stack
    local widgets = {}
    for i = #stack, self.base + 1, -1 do widgets[#widgets + 1] = stack[i].widget end
    for _idx, w in ipairs(widgets) do
        if w.onClose then w:onClose() else UIManager:close(w) end
    end
end

--- 滚动弹窗：月读段评窗是分页的（turn），TextViewer 是滚动的。
---@return boolean 接住了没有
function PageTurner:scrollPopup(dir)
    local w = self:popup()
    if not w then return false end
    if w.turn and w.pages then
        w:turn(dir)
    elseif w.scroll_widget then
        w.scroll_widget:scrollText(dir)
    else
        return false
    end
    return true
end

--- 下一个 / 上一个。返回 true 表示按键已被消费（别去翻页）。
function PageTurner:step(dir)
    if self.mode == "select" then
        self:select((self.idx - 1 + dir) % #self.items + 1)
        return true
    end
    return self.mode == "view" and self:scrollPopup(dir)
end

--- 确认：正常读书 → 选想法 → 开想法 → 关闭，循环。
function PageTurner:confirm()
    if self.mode == "view" then
        self:closePopup()
        self:exit()
    elseif self.mode == "select" then
        self.mode = "view"
        self.base = #UIManager._window_stack
        self.items[self.idx].open()
    else
        local items = Thoughts.collect(self.ui)
        if not items then
            UIManager:show(InfoMessage:new{ text = T("本页没有想法"), timeout = 2 })
            return
        end
        self.mode, self.items, self.base = "select", items, 0
        self:select(1)
    end
end

-- 翻页 / 跳转自动退出选择模式；弹窗被手动关掉后也一并收尾。
function PageTurner:onPageUpdate()
    if self.mode == "select" or (self.mode == "view" and not self:popup()) then self:exit() end
end
PageTurner.onPosUpdate = PageTurner.onPageUpdate

------------------------------------------------------------------------------
-- 按键钩子
------------------------------------------------------------------------------

--- 落单的一次：选择 / 弹窗里是上一个 / 下一个，正常读书就是翻页。
local function onSolo(action)
    if not current then return end
    if not current:step(action) then UIManager:sendEvent(Event:new("GotoViewRel", action)) end
end

--- 手势识别：键码 + 连按次数（TAP_GAP 内算连按，到 max 立即出手，否则等间隔结束）或长按。
-- 这个键上绑了长按才看松开时长，否则只数按下事件（有的翻页器松开事件不可靠）。
local function emit(code, kind)
    if capture then return capture(code, kind) end
    local g = gestures[code]
    local key = g and g.act[kind]
    if not key or not current then return end
    if key == "ok" then return current:confirm() end
    for _idx, a in ipairs(ACTIONS) do
        if a.key == key then return onSolo(a.step) end
    end
end

--- 同一个键上 80ms 内重复来的事件当成抖动丢掉。
-- 有些翻页器一次按下会发两遍（按键本身抖也算），不滤的话一次单击被数成连按两下，
-- 真的连按两下又变成三四下 —— 而三四下一般没绑，表现就是「双击按了没反应」。
local function bounce(st, slot, now)
    if st[slot] and now - st[slot] < DEBOUNCE then return true end
    st[slot] = now
    return false
end

local function feed(code, ev, g)
    local st = states[code] or { n = 0 }
    states[code] = st
    local now = util.getTimestamp()
    local function tap()
        st.n, st.stamp = st.n + 1, now
        local function fire()
            local n = st.n
            st.n = 0
            emit(code, n)
        end
        if st.n >= g.max then return fire() end
        UIManager:scheduleIn(TAP_GAP, function()
            if st.stamp == now and st.n > 0 then fire() end
        end)
    end
    if not g.long then
        if ev.value == 1 and not bounce(st, "last_down", now) then tap() end
    elseif ev.value == 1 then
        if bounce(st, "last_down", now) then return end
        local h = { at = now }
        st.down = h
        UIManager:scheduleIn(LONG_PRESS, function()
            if st.down ~= h or h.done then return end
            h.done, st.n = true, 0
            emit(code, "long")
        end)
    elseif ev.value == 0 then
        if bounce(st, "last_up", now) then return end
        local h = st.down
        st.down = nil
        if not h or h.done then return end
        h.done = true
        if now - h.at >= LONG_PRESS then st.n = 0 emit(code, "long") else tap() end
    end
end

-- 翻页键会先被翻页模块吃掉，插件收不到，只能在最早的入口 Input.handleKeyBoardEv 拦。
local function hookKeys()
    if hooked then return end
    hooked = true
    local Dev = Device.input
    -- 取真正的原始处理函数：启动早期 inhibitInput 会把 handleKeyBoardEv 临时换成只管电源键的函数。
    local orig = Dev._key_ev_handler or Dev.handleKeyBoardEv
    Dev.handleKeyBoardEv = function(self, ev)
        local g = ev and (capture and LEARN or (current and gestures[ev.code]))
        if g then
            feed(ev.code, ev, g)
            return nil
        end
        return orig(self, ev)
    end
    -- restoreInput 会用 _key_ev_handler 覆盖 handleKeyBoardEv，一起指过来才不会被冲掉。
    if Dev._key_ev_handler then Dev._key_ev_handler = Dev.handleKeyBoardEv end
end

------------------------------------------------------------------------------
-- 菜单
------------------------------------------------------------------------------

function PageTurner:statusText()
    local paths = Input:openPaths()
    local bound = {}
    for _idx, a in ipairs(ACTIONS) do
        bound[#bound + 1] = T("%s：%s", a.label, gestureName(self.settings.binds[a.key]))
    end
    local lines = {
        table.concat(bound, "\n"),
        T("守护进程：%s", self:daemonRunning() and T("在跑") or T("没跑")),
        T("已接管设备：%s", #paths > 0 and table.concat(paths, ", ") or T("（无）")),
    }
    if Moon:available() then
        lines[#lines + 1] = T("月读蓝牙：%s", Moon:isOn() and T("开") or T("关"))
        lines[#lines + 1] = T("翻页器：%s", Moon:isConnected() and T("已连上") or T("没连上"))
    else
        lines[#lines + 1] = T("月读：没装（翻页器照常用，只是不联动它的蓝牙开关）")
    end
    return table.concat(lines, "\n")
end

-- 月读设置页（moon_source.lua）经广播事件驱动这三个入口，设置值仍由插件自己存。
function PageTurner:onPageTurnerBind() self:bind(1, {}) return true end
function PageTurner:onPageTurnerStatus()
    UIManager:show(InfoMessage:new{ text = self:statusText() })
    return true
end
function PageTurner:onPageTurnerToggle(key) self:toggle(key) return true end

function PageTurner:addToMainMenu(menu_items)
    local function toggleItem(text, key)
        return {
            text = text,
            checked_func = function() return self.settings[key] end,
            callback = function() self:toggle(key) end,
        }
    end
    menu_items.bt_pager = {
        text = T("翻页器"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = T("翻页器状态"),
                keep_menu_open = true,
                callback = function() UIManager:show(InfoMessage:new{ text = self:statusText() }) end,
            },
            {
                text = T("绑定翻页器按键"),
                keep_menu_open = true,
                callback = function() self:bind(1, {}) end,
            },
            toggleItem(T("翻页器连着时不息屏"), "keep_awake"),
            toggleItem(T("蓝牙开了自动连翻页器"), "auto_connect"),
        },
    }
end

------------------------------------------------------------------------------
-- 生命周期
------------------------------------------------------------------------------

function PageTurner:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
    self:takeOverAll()
    self:startRescanLoop()
    self:startFdHealLoop()

    self:applyBindings()
    hookKeys()
    if self.ui.document then
        current = self
        -- 单独的小对象：插件本身是阅读页子控件，直接登记会每帧画两遍。
        self.ui.view:registerViewModule("pageturner", { paintTo = function(_p, bb) self:paintSelection(bb) end })
    end

    if Moon:available() then
        Moon:startWatch(self)
        Moon:sync(self)
    else
        self:ensureDaemon()
    end
end

function PageTurner:onCloseWidget()
    if current == self then current = nil end
    Moon:stopWatch(self)
    Moon:setAwake(false)
end

return PageTurner
