--[[--
月读联动：翻页器跟着月读的蓝牙开关走；本会话用过翻页器时不让 Kindle 自己息屏。

只经月读公开的 features.bluetooth 的 current/watch/setConnected，不改月读任何函数。

它做的事：

  月读蓝牙开  -> 清掉历史遗留的「关过」标记、补位拉起守护进程、接管翻页器设备
  月读蓝牙关  -> 什么都不做（进程生死交给月读），只恢复自动息屏
  翻页器连上过一次（本 BT 开着的会话）-> 挡住自动息屏，直到蓝牙关掉

翻页器（Kindle Click 等）空闲几分钟会自己断 BLE。旧逻辑「连着才不息屏」在断连瞬间
松开 pause_auto_suspend，KOReader AutoSuspend（常 10 分钟）就会按上次触摸入睡——
人还在看书、只是 Click 睡了。所以不息屏改成会话闩，不跟瞬时连接态绑死。

断了之后要能尽快连回来：短退避重试，用户摸一下屏幕就立刻再试；不要锁死 5 分钟——
设备睡着时连不上是常态，醒过来却还在冷却窗口里，表现就是「屏亮着、蓝牙开着、按了没反应」。
--]]

local logger = require("logger")

-- 自动重连退避：失败后 15s → 30s → 60s（封顶）。用户触摸 / HID 掉线会清退避立刻再试。
local CONNECT_RETRY_MIN = 15
local CONNECT_RETRY_MAX = 60
-- 触摸狂点不要每下都打一次 connect。
local ACTIVITY_KICK_GAP = 3

local Moon = {
    _bt = nil,          -- 月读的蓝牙模块（拿到了才谈得上联动）
    _owner = nil,       -- 当前订阅月读状态的插件实例
    _watch = nil,
    _awake = false,     -- 当前是不是被我们按住不让息屏
    _session_awake = false, -- 本 BT 开着期间是否已经连上过翻页器（不息屏闩）
    _hooked = false,
    _last_connect_try = nil,
    _connect_backoff = nil,
    _activity_kick_at = nil,
}

--- 拿月读蓝牙模块的那个表。
-- 必须拿月读已经加载好的同一个表：自己 dofile 一份会生成新表，
-- 改新表的 setEnabled 对月读毫无作用。
local function bt()
    if Moon._bt then return Moon._bt end
    local loaded = package.loaded and package.loaded["features.bluetooth"]
    if type(loaded) == "table" and type(loaded.setEnabled) == "function" then
        Moon._bt = loaded
        return Moon._bt
    end
    local ok, m = pcall(require, "features.bluetooth")
    if ok and type(m) == "table" and type(m.setEnabled) == "function" then
        Moon._bt = m
        return Moon._bt
    end
    return nil
end

function Moon:available()
    return bt() ~= nil
end

--- 月读那边现在是开还是关
function Moon:isOn()
    local m = bt()
    if not m then return nil end
    local ok, st = pcall(function() return m.current() end)
    if not (ok and type(st) == "table") then return nil end
    return st.state == "on", st
end

--- 翻页器是不是真的连着（光开着蓝牙但没连上设备不算「在用」）
function Moon:isConnected()
    local on, st = self:isOn()
    if on == nil or not st then return false end
    local conns = st.connections
    return type(conns) == "table" and #conns > 0
end

--- 清掉重连退避，下次 ensureConnected 可以立刻跑。
function Moon:resetConnectBackoff()
    self._connect_backoff = nil
    self._last_connect_try = nil
end

------------------------------------------------------------------------------
-- 补上最后一公里：蓝牙开了，就让翻页器真的连上
------------------------------------------------------------------------------
-- 月读那边把蓝牙射频打开、把已配对设备列出来（/status 的 devices 字段），
-- 但「连」这个动作是留给用户在面板里点的 —— 也就是用户看到的
-- 「蓝牙已连接，翻页器未连接」，还得手动重启一次守护进程才真连上。
--
-- 我们要的就是「月读显示已开启 = 翻页器真的能翻」，所以这里替他把这一下按了。
---@param plugin table
---@param force boolean|nil 无视退避（用户触摸 / HID 掉线后）
---@return boolean 是否发起了连接请求
function Moon:ensureConnected(plugin, force)
    if not plugin.settings.auto_connect then return false end
    local m = bt()
    if not m or type(m.setConnected) ~= "function" then return false end

    local on, st = self:isOn()
    if not on or not st then return false end

    -- 已经连着了就什么都不用做，顺便记住是哪台，并闩住不息屏会话
    local conns = st.connections
    if type(conns) == "table" and #conns > 0 then
        self:resetConnectBackoff()
        self:markSessionAwake()
        local first = conns[1]
        if type(first) == "table" and first.address
            and first.address ~= plugin.settings.last_pager_addr then
            plugin.settings.last_pager_addr = first.address
            pcall(function() plugin:saveSettings() end)
        end
        return false
    end

    local devices = st.devices
    if type(devices) ~= "table" or #devices == 0 then return false end

    -- 翻页器睡着时连不上是常态；短退避避免把 BTmanager 打成重连风暴，
    -- 但绝不能锁死几分钟——设备一醒（用户按翻页器 / 摸屏）要马上再试。
    local now = os.time()
    local wait = self._connect_backoff or CONNECT_RETRY_MIN
    if not force and self._last_connect_try and (now - self._last_connect_try) < wait then
        return false
    end
    self._last_connect_try = now

    -- 只配了一台就直接连；配了多台优先连上次连过的那台
    local dev = devices[1]
    local last = plugin.settings.last_pager_addr
    if #devices > 1 and last and last ~= "" then
        for _, d in ipairs(devices) do
            if d.address == last then dev = d break end
        end
    end

    logger.info("[pageturner] Bluetooth is on but the pager is not connected, connecting it: "
        .. tostring(dev and (dev.name or dev.address)))
    pcall(function()
        m.setConnected(dev, true, function(ok, err)
            if not ok then
                local prev = self._connect_backoff or CONNECT_RETRY_MIN
                self._connect_backoff = math.min(CONNECT_RETRY_MAX, prev * 2)
                logger.warn("[pageturner] failed to connect pager: " .. tostring(err)
                    .. "（" .. tostring(self._connect_backoff) .. "s 后重试；触摸屏幕或按翻页器可立刻再试）")
                return
            end
            self:resetConnectBackoff()
            self:markSessionAwake()
            logger.info("[pageturner] pager connected")
            -- 连上了输入设备才会出现，这时候接管才有意义；顺手收敛不息屏
            pcall(function() plugin:takeOverAll() end)
            self:applyAwake(plugin)
        end)
    end)
    return true
end

--- 用户摸了屏幕：翻页器按键在断连后进不来，触摸是「人还在」的信号。
-- 状态已断 → 清退避强制再连；状态仍显示连着 → 可能只是 HID/fd 死了，立刻 heal + 接管。
function Moon:onUserActivity(plugin)
    if not plugin then return end
    local on = self:isOn()
    if not on then return end
    local now = os.time()
    if self._activity_kick_at and (now - self._activity_kick_at) < ACTIVITY_KICK_GAP then
        return
    end
    self._activity_kick_at = now
    if self:isConnected() then
        pcall(function()
            plugin:healFd()
            plugin:takeOverAll(true)
        end)
        return
    end
    if not plugin.settings.auto_connect then return end
    self:resetConnectBackoff()
    self:ensureConnected(plugin, true)
end

--- HID 节点没了（翻页器休眠断连）：清退避并立刻按当前状态同步。
-- 不息屏闩不在这里清——Click 空闲断 BLE / 换章重建节点都是常态，人还在看书。
function Moon:onDeviceLost(plugin)
    if not plugin then return end
    self:resetConnectBackoff()
    self:sync(plugin)
end

------------------------------------------------------------------------------
-- 使用翻页器时不息屏（会话闩，不跟瞬时连接态绑死）
------------------------------------------------------------------------------
-- 以前用 UIManager:preventStandby，那只挡 CPU 轻待机，挡不住 AutoSuspend 息屏。
-- 后来改成「连着才 pause_auto_suspend」，Click 空闲断 BLE 立刻松手，照样睡。
-- 正确做法：本 BT 开着期间一旦连上过就闩住：
--   全平台: PluginShare.pause_auto_suspend（AutoSuspend 不走到 suspend）
--   Kindle: PluginShare.keepalive（AutoSuspend 跳过 t1 重置；月读 tasks 降旗时也不清 pause）
-- 不要写 lipc preventScreenSaver=1：那是 keepalive.koplugin 的「系统绝不睡」，
-- powerd 会连电源键 / UIManager:suspend（也是 powerButton）一并拒掉。
-- 蓝牙关掉才松手（用户明确结束），别在短暂断连上抖。

--- 要不要撑着不息屏：设置开 +（已闩住或当前连着）；蓝牙明确关了才清闩。
---@param plugin table
---@return boolean
function Moon:shouldStayAwake(plugin)
    if not plugin or not plugin.settings.keep_awake then
        self._session_awake = false
        return false
    end
    local on = self:isOn()
    if on == nil then
        -- 刚醒 / 轮询中状态未知：有闩先撑着，别把会话清掉
        return self._session_awake == true
    end
    if not on then
        self._session_awake = false
        return false
    end
    if self:isConnected() then
        self._session_awake = true
    end
    return self._session_awake == true
end

--- 记一次「本会话已用过翻页器」（连接成功回调里也会打）。
function Moon:markSessionAwake()
    self._session_awake = true
end

---@param on boolean
---@param force boolean|nil 休眠唤醒后强制再写一遍
function Moon:setAwake(on, force)
    on = on and true or false
    if on == self._awake and not force then return end
    self._awake = on
    local Device = require("device")
    local share = require("pluginshare")
    -- 旧版写过 preventScreenSaver=1 会卡死电源键；每次收敛都清掉，绝不置 1。
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    share.keepalive = on
    share.pause_auto_suspend = on
    logger.info("[pageturner] keep awake: " .. tostring(on))
end

--- 按 shouldStayAwake 收敛息屏闩（设置关或蓝牙关 → 松开）。
---@param plugin table
---@param force boolean|nil
function Moon:applyAwake(plugin, force)
    local want = self:shouldStayAwake(plugin)
    if want then
        self:setAwake(true, force)
    elseif self._awake then
        self:setAwake(false)
    end
end

--- 休眠唤醒：系统可能拆了 BLE。立刻刷状态、重连、接管。
-- 不能干等月读 30s 轮询——用户体感会超过一分钟。
function Moon:onResume(plugin)
    if not plugin then return end
    self:resetConnectBackoff()
    -- 睡前用过翻页器：先强制写回自动不息屏闩，等 BT 恢复后再由 sync 收敛（未知态不拆闩）
    if plugin.settings.keep_awake and self._session_awake then
        self:setAwake(true, true)
    end
    local m = bt()
    local function after()
        self:sync(plugin)
        pcall(function()
            plugin:healFd()
            plugin:takeOverAll()
        end)
        if plugin.settings.auto_connect then
            self:ensureConnected(plugin, true)
        end
    end
    if m and type(m.refresh) == "function" then
        pcall(function() m.refresh(after) end)
    else
        after()
    end
end

------------------------------------------------------------------------------
-- 同步：按月读的蓝牙状态决定守护进程 / 接管 / 息屏
------------------------------------------------------------------------------
function Moon:sync(plugin)
    local m = bt()
    if not m then return end
    local on = self:isOn()
    if on == nil then return end

    -- 这里只跟进「开」要做的事（拉起、接管、不息屏）。
    -- 关的事一概不管：进程生死是月读自己的设计（它的 /stop 只关射频、进程常驻，
    -- 方便下次秒连），我们不要去动它。插件是拐杖，不是绊脚石。
    if on then
        plugin:onMoonBluetoothOn()
        -- 蓝牙「开了」不等于翻页器「连上了」：月读只把射频打开、把已配对设备列出来，
        -- 连这一步是留给用户点的。这里替他按一下，让「月读显示已开启」真的等于
        -- 「翻页器能翻」。
        pcall(function() Moon:ensureConnected(plugin) end)
        -- 连着时重新接管：翻页器待机重连会重建输入节点，旧 fd 要换掉，
        -- 不然就是「显示连上了，按了没反应」。cheap 轮询也会补这一枪。
        pcall(function()
            if Moon:isConnected() then
                plugin:healFd()
                plugin:takeOverAll(true)
            end
        end)
    end

    self:applyAwake(plugin)
end

------------------------------------------------------------------------------
-- 订阅月读蓝牙状态变化
------------------------------------------------------------------------------
function Moon:startWatch(plugin)
    local m = bt()
    if not m then return end
    self:stopWatch(self._owner)
    self._owner = plugin
    -- 月读那边状态一变（手动开关、轮询发现设备掉了）就同步一次
    self._watch = m.watch(function() Moon:sync(plugin) end)
end

--- 只有订阅者自己能取消：文件管理器实例关闭时，不能把阅读页刚建的订阅取消掉。
function Moon:stopWatch(plugin)
    if not plugin or self._owner ~= plugin then return end
    self._watch.cancel()
    self._watch, self._owner = nil, nil
    -- 阅读页实例关掉不等于结束翻页会话；FM 侧还会再 startWatch。
    -- 真要松手走 applyAwake（蓝牙关 / 设置关），这里只撤订阅。
end

return Moon
