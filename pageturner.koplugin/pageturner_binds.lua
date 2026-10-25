--[[--
三个动作与手势的显示名，main.lua 与 moon_source.lua（月读设置页）共用。
--]]

local T = require("pageturner_l10n")

local Binds = {}

Binds.ACTIONS = {
    { key = "next", label = T("下一个"), step = 1 },
    { key = "prev", label = T("上一个"), step = -1 },
    { key = "ok",   label = T("确认") },
}

---@param b { code: integer, kind: integer|string }|nil
function Binds.gestureName(b)
    if not b then return T("未绑定") end
    local how = b.kind == "long" and T("长按") or (b.kind == 1 and T("单击") or T("连按%d下", b.kind))
    return T("键 %d %s", b.code, how)
end

--- 当前保存的某个动作的手势显示名（月读设置页在插件实例之外读配置用）。
function Binds.savedName(key)
    local saved = G_reader_settings:readSetting("pageturner") or {}
    return Binds.gestureName(saved.binds and saved.binds[key])
end

return Binds
