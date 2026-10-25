--[[--
翻译：源字符串是简体中文，按 KOReader 当前语言查表。简体中文原样返回，繁体中文用 zh_TW，其余（含未设置）用 en。
带 %s / %d 的字符串，T 的额外参数按 string.format 填进去。

不并进 KOReader 的全局 gettext：全局表里多塞中文键只会污染别的插件。
--]]

local TW = {
    ["翻页器"] = "翻頁器",
    ["翻页器状态"] = "翻頁器狀態",
    ["翻页器连着时不息屏"] = "翻頁器連著時不熄屏",
    ["蓝牙开了自动连翻页器"] = "藍牙開了自動連翻頁器",
    ["下一个"] = "下一個",
    ["上一个"] = "上一個",
    ["确认"] = "確認",
    ["未绑定"] = "未綁定",
    ["单击"] = "單擊",
    ["长按"] = "長按",
    ["连按%d下"] = "連按%d下",
    ["键 %d %s"] = "鍵 %d %s",
    ["%s：%s"] = "%s：%s",
    ["这个手势已经绑给「%s」了，请换一个"] = "這個手勢已經綁給「%s」了，請換一個",
    ["「%s」= %s"] = "「%s」= %s",
    ["请在翻页器上做出「%s」的动作\n单击 / 连按 2~3 下 / 长按都行，做完稍等"] =
        "請在翻頁器上做出「%s」的動作（%d/%d）\n單擊 / 連按 2~3 下 / 長按都行，做完稍等",
    ["本页没有想法"] = "本頁沒有想法",
    ["守护进程：%s"] = "守護行程：%s",
    ["在跑"] = "在跑",
    ["没跑"] = "沒跑",
    ["已接管设备：%s"] = "已接管裝置：%s",
    ["（无）"] = "（無）",
    ["月读蓝牙：%s"] = "月讀藍牙：%s",
    ["开"] = "開",
    ["按键"] = "按鍵",
    ["连接"] = "連接",
    ["关"] = "關",
    ["翻页器：%s"] = "翻頁器：%s",
    ["已连上"] = "已連上",
    ["没连上"] = "沒連上",
    ["月读：没装（翻页器照常用，只是不联动它的蓝牙开关）"] = "月讀：沒裝（翻頁器照常用，只是不聯動它的藍牙開關）",
}

local EN = {
    ["翻页器"] = "Page turner",
    ["翻页器状态"] = "Page turner status",
    ["翻页器连着时不息屏"] = "Keep screen awake while connected",
    ["蓝牙开了自动连翻页器"] = "Auto-connect when Bluetooth is on",
    ["下一个"] = "Next",
    ["上一个"] = "Previous",
    ["确认"] = "Confirm",
    ["未绑定"] = "not bound",
    ["单击"] = "click",
    ["长按"] = "long press",
    ["连按%d下"] = "%d clicks",
    ["键 %d %s"] = "key %d, %s",
    ["%s：%s"] = "%s: %s",
    ["这个手势已经绑给「%s」了，请换一个"] = "This gesture is already bound to \"%s\", try another",
    ["「%s」= %s"] = "\"%s\" = %s",
    ["请在翻页器上做出「%s」的动作\n单击 / 连按 2~3 下 / 长按都行，做完稍等"] =
        "Do the gesture for \"%s\" on the page turner (%d/%d)\nA click, 2-3 quick clicks or a long press all work. Wait a moment when done.",
    ["本页没有想法"] = "No thoughts on this page",
    ["守护进程：%s"] = "Daemon: %s",
    ["在跑"] = "running",
    ["没跑"] = "not running",
    ["已接管设备：%s"] = "Attached devices: %s",
    ["（无）"] = "(none)",
    ["月读蓝牙：%s"] = "Moon Bluetooth: %s",
    ["开"] = "on",
    ["按键"] = "Keys",
    ["连接"] = "Connection",
    ["关"] = "off",
    ["翻页器：%s"] = "Page turner: %s",
    ["已连上"] = "connected",
    ["没连上"] = "not connected",
    ["月读：没装（翻页器照常用，只是不联动它的蓝牙开关）"] =
        "Moon: not installed (the page turner works as usual, just without Moon's Bluetooth switch)",
}

local lang = tostring(G_reader_settings:readSetting("language") or os.getenv("LANG") or "")
local dict
if lang:match("^zh_TW") or lang:match("^zh_HK") then
    dict = TW
elseif not lang:match("^zh") then
    dict = EN
end

return function(s, ...)
    s = dict and dict[s] or s
    if select("#", ...) > 0 then return string.format(s, ...) end
    return s
end
