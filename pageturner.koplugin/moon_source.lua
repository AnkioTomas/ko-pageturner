--[[--
月读拓展登记：让月读把「翻页器」认成自己的扩展，并在月读设置的「阅读」组里放一页「翻页器」。

页内三项：翻页器状态、绑定翻页器按键、两个开关（翻页器连着时不息屏 / 蓝牙开了自动连翻页器）。
设置值仍由插件存在 KOReader 的 `pageturner` 配置里，月读页只读写它；绑定、状态、开关都经广播事件
（PageTurnerBind / PageTurnerStatus / PageTurnerToggle）交给插件实例，插件本身不依赖月读。
没装月读时这个文件不会被读，菜单在 KOReader：齿轮 → 网络 → 翻页器。

守护进程不用管：装了月读由月读的蓝牙开关拉起。

@module pageturner.moon_source
--]]

-- KOReader 只在加载那一刻把插件目录加进 package.path，月读之后回调里 require 要靠这一句。
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

    local function action(title, icon, event)
        return function(iw)
            return Row.widget({
                width = iw, chevron = false, kind = "action", icon = icon, title = title,
                callback = function() broadcast(event) end,
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
                    -- 事件同步派发，插件已写完配置
                    desktop:updateView()
                end,
            })
        end
    end

    return { {
        group = "reader",
        order = 19,
        id = "main",
        icon = "bluetooth",
        title = T("翻页器"),
        page = {
            title = T("翻页器"),
            sections = function()
                return {
                    { title = T("按键"), rows = {
                        action(T("翻页器状态"), "info", "PageTurnerStatus"),
                        action(T("绑定翻页器按键"), "keyboard", "PageTurnerBind"),
                    } },
                    { title = T("连接"), rows = {
                        toggle(T("翻页器连着时不息屏"), "brightness_high", "keep_awake"),
                        toggle(T("蓝牙开了自动连翻页器"), "bluetooth_connected", "auto_connect"),
                    } },
                }
            end,
        },
    } }
end

return {
    api = 1,
    id = "ext.pageturner",
    provides = {
        source = false,
        features = { setting = { entries = settingEntries } },
    },
}
