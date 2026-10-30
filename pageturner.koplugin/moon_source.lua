--[[--
月读拓展登记：让月读把「翻页器」认成自己的扩展，并在设置「系统 → 本机」里放一页「翻页器」。

页内：下一个 / 上一个 / 确认三个按键（点哪个录哪个）、两个开关（使用翻页器时不息屏 / 蓝牙开了自动连翻页器）、
自动检查更新与手动检查（月读 UI）。
设置值：按键/连接在 KOReader 的 `pageturner` 配置；更新开关在月读 `ext.pageturner` 源配置。
绑定、清除、开关经广播事件交给插件实例。没装月读时这个文件不会被读。

本机分类靠月读 `GROUP_FOLDERS.system` 的 match（`feature:ext.pageturner`）；条目本身挂 `group = "system"`。

@module pageturner.moon_source
--]]

local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
if dir and not package.path:find(dir, 1, true) then
    package.path = dir .. "/?.lua;" .. package.path
end

local function broadcast(name, ...)
    local UIManager = require("ui/uimanager")
    UIManager:broadcastEvent(require("ui/event"):new(name, ...))
end

local function enabled(key)
    local saved = G_reader_settings:readSetting("pageturner") or {}
    return saved[key] ~= false
end

local function settingEntries(desktop)
    local T = require("pageturner_l10n")
    local Row = require("ui.themes.widgets.row")
    local Update = require("pageturner_update")

    local Binds = require("pageturner_binds")
    local function action(title, icon, event)
        return function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "action", icon = icon, title = title,
                callback = function() broadcast(event) end,
            })
        end
    end

    local function bindRow(a)
        return function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "action", icon = "keyboard", title = a.label,
                status = Binds.savedName(a.key),
                callback = function() broadcast("PageTurnerBind", a.key) end,
            })
        end
    end

    local function toggle(title, icon, key)
        return function(iw)
            local on = enabled(key)
            return Row.widget({
                width = iw, chevron = false, kind = "toggle", icon = icon, title = title,
                status = on and T("开") or T("关"), status_on = on,
                callback = function()
                    broadcast("PageTurnerToggle", key)
                    desktop:updateView()
                end,
            })
        end
    end

    local title = T("翻页器（%s）", Update.version())
    -- 系统组独立导航页（三级：根 → 系统/本机 → 翻页器）；本机归类见月读 match。
    return { {
        group = "system",
        order = 55,
        id = "main",
        icon = "bluetooth",
        title = title,
        subtitle = T("按键绑定与连接"),
        page = {
            title = title,
            sections = function()
                return {
                    { title = T("按键"), rows = {
                        bindRow(Binds.ACTIONS[1]), bindRow(Binds.ACTIONS[2]), bindRow(Binds.ACTIONS[3]),
                        action(T("清除全部按键绑定"), "delete", "PageTurnerClear"),
                    } },
                    { title = T("连接"), rows = {
                        toggle(T("使用翻页器时不息屏"), "brightness_high", "keep_awake"),
                        toggle(T("蓝牙开了自动连翻页器"), "bluetooth_connected", "auto_connect"),
                    } },
                    { title = T("更新"), rows = {
                        function(iw)
                            local on = Update.autoEnabled()
                            return Row.widget({
                                width = iw, chevron = false, kind = "toggle", icon = "update",
                                title = T("自动检查更新"),
                                subtitle = T("每天最多一次，有新版本时提示"),
                                status = on and T("开") or T("关"), status_on = on,
                                callback = function()
                                    Update.setAuto(not on)
                                    desktop:updateView()
                                end,
                            })
                        end,
                        function(iw)
                            return Row.widget({
                                width = iw, chevron = false, kind = "action", icon = "system_update",
                                title = T("检查更新"),
                                status = Update.version(), status_on = true,
                                callback = function() Update.manualCheck() end,
                            })
                        end,
                    } },
                }
            end,
        },
    } }
end

-- 首页组件没有入口时，设置页被扫到 / 插件加载后稍等再查更新，不和首屏抢网络。
require("ui/uimanager"):scheduleIn(5, function()
    pcall(function() require("pageturner_update").autoCheck() end)
end)

return {
    api = 1,
    id = "ext.pageturner",
    provides = {
        source = false,
        features = { setting = { entries = settingEntries } },
    },
}
