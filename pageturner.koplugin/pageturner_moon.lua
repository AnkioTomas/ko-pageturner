--[[--
月读联动：翻页器跟着月读的蓝牙开关走，翻页器连着的时候不让 Kindle 自己息屏。

只经月读公开的 features.bluetooth 的 current/watch/setConnected，不改月读任何函数。

它做的事：

  月读蓝牙开  -> 清掉历史遗留的「关过」标记、补位拉起守护进程、接管翻页器设备、不息屏
  月读蓝牙关  -> 什么都不做（进程生死交给月读），只恢复自动息屏
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local Moon = {
    _bt = nil,          -- 月读的蓝牙模块（拿到了才谈得上联动）
    _owner = nil,       -- 当前订阅月读状态的插件实例
    _watch = nil,
    _awake = false,     -- 当前是不是被我们按住不让息屏
    _hooked = false,
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

------------------------------------------------------------------------------
-- 补上最后一公里：蓝牙开了，就让翻页器真的连上
------------------------------------------------------------------------------
-- 月读那边把蓝牙射频打开、把已配对设备列出来（/status 的 devices 字段），
-- 但「连」这个动作是留给用户在面板里点的 —— 也就是用户看到的
-- 「蓝牙已连接，翻页器未连接」，还得手动重启一次守护进程才真连上。
--
-- 我们要的就是「月读显示已开启 = 翻页器真的能翻」，所以这里替他把这一下按了。
function Moon:ensureConnected(plugin)
    if not plugin.settings.auto_connect then return false end
    local m = bt()
    if not m or type(m.setConnected) ~= "function" then return false end

    local on, st = self:isOn()
    if not on or not st then return false end

    -- 已经连着了就什么都不用做，顺便记住是哪台
    local conns = st.connections
    if type(conns) == "table" and #conns > 0 then
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

    -- 别太勤快。连不上基本不是多试几次能解决的（翻页器关机 / 连着别的主机 /
    -- 不在附近），而我们每戳一次，守护进程就要 resume 一次去连、失败再 suspend ——
    -- 在 BTmanager 里看着就是一直在重连，越戳越乱。
    -- 所以：两次尝试至少隔 30 秒；失败过一次就老实 5 分钟再说。
    local now = os.time()
    if self._last_connect_try and (now - self._last_connect_try) < 30 then
        return false
    end
    if self._connect_failed_at and (now - self._connect_failed_at) < 300 then
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
                self._connect_failed_at = os.time()
                logger.warn("[pageturner] failed to connect pager: " .. tostring(err)
                    .. "（5 分钟内不再自动重试，请在月读面板或 BTmanager 里手动连）")
                return
            end
            self._connect_failed_at = nil
            logger.info("[pageturner] pager connected")
            -- 连上了输入设备才会出现，这时候接管才有意义
            pcall(function() plugin:takeOverAll() end)
        end)
    end)
    return true
end

------------------------------------------------------------------------------
-- 不让 Kindle 自己息屏
------------------------------------------------------------------------------
-- KOReader 的这两个是配对的计数式调用，多调一次 prevent 就得配一次 allow。
function Moon:setAwake(on)
    if on == self._awake then return end
    pcall(function()
        if on then UIManager:preventStandby() else UIManager:allowStandby() end
    end)
    self._awake = on
    logger.info("[pageturner] keep awake: " .. tostring(on))
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
        -- 不然就是「显示连上了，按了没反应」。没有轮询，全靠月读的状态变化触发这里。
        pcall(function()
            if Moon:isConnected() then
                plugin:healFd()
                plugin:takeOverAll(true)
            end
        end)
    end

    -- 翻页器连着的时候不让息屏：翻页间隔可能很长（一页看几分钟），
    -- 但人就在跟前，这时候黑屏很烦。断了就放开，别白耗电。
    if plugin.settings.keep_awake then
        self:setAwake(self:isConnected())
    end
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
    self:setAwake(false)
end

return Moon
