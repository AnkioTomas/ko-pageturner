--[[--
翻译：源字符串是简体中文，按 KOReader 当前语言查表。简体中文原样返回，繁体中文用 zh_TW，其余（含未设置）用 en。
带 %s / %d 的字符串，T 的额外参数按 string.format 填进去。

不并进 KOReader 的全局 gettext：全局表里多塞中文键只会污染别的插件。
--]]

local TW = {
    ["翻页器"] = "翻頁器",
    ["使用翻页器时不息屏"] = "使用翻頁器時不熄屏",
    ["翻页器连着时不息屏"] = "使用翻頁器時不熄屏", -- 旧键兼容
    ["蓝牙开了自动连翻页器"] = "藍牙開了自動連翻頁器",
    ["下一个"] = "下一個",
    ["上一个"] = "上一個",
    ["确认"] = "確認",
    ["未绑定"] = "未綁定",
    ["清除全部按键绑定"] = "清除全部按鍵綁定",
    ["已清除全部按键绑定"] = "已清除全部按鍵綁定",
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
    ["开"] = "開",
    ["按键"] = "按鍵",
    ["连接"] = "連接",
    ["关"] = "關",
    ["翻页器（%s）"] = "翻頁器（%s）",
    ["更新"] = "更新",
    ["自动检查更新"] = "自動檢查更新",
    ["每天最多一次，有新版本时提示"] = "每天最多一次，有新版本時提示",
    ["检查更新"] = "檢查更新",
    ["正在检查或安装更新，请稍候"] = "正在檢查或安裝更新，請稍候",
    ["更新信息无效，请稍后再试"] = "更新資訊無效，請稍後再試",
    ["新版本缺少插件包，请稍后再试"] = "新版本缺少插件包，請稍後再試",
    ["更新包校验失败，请稍后再试"] = "更新包校驗失敗，請稍後再試",
    ["更新包过大，已中止下载"] = "更新包過大，已中止下載",
    ["正在下载翻页器更新…"] = "正在下載翻頁器更新…",
    ["更新完成，正在重启 KOReader…"] = "更新完成，正在重啟 KOReader…",
    ["翻页器更新失败：%s"] = "翻頁器更新失敗：%s",
    ["正在安装翻页器更新…"] = "正在安裝翻頁器更新…",
    ["发现翻页器 %s（当前 %s）。下载并完整替换插件目录？"] =
        "發現翻頁器 %s（目前 %s）。下載並完整替換插件目錄？",
    ["更新日志"] = "更新日誌",
    ["稍后"] = "稍後",
    ["下载并安装"] = "下載並安裝",
    ["正在检查翻页器更新…"] = "正在檢查翻頁器更新…",
    ["检查更新失败：%s"] = "檢查更新失敗：%s",
    ["已是最新版本（%s）"] = "已是最新版本（%s）",
}

local EN = {
    ["翻页器"] = "Page turner",
    ["使用翻页器时不息屏"] = "Keep screen awake while using the page turner",
    ["翻页器连着时不息屏"] = "Keep screen awake while using the page turner",
    ["蓝牙开了自动连翻页器"] = "Auto-connect when Bluetooth is on",
    ["下一个"] = "Next",
    ["上一个"] = "Previous",
    ["确认"] = "Confirm",
    ["未绑定"] = "not bound",
    ["清除全部按键绑定"] = "Clear all key bindings",
    ["已清除全部按键绑定"] = "All key bindings cleared",
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
    ["开"] = "on",
    ["按键"] = "Keys",
    ["连接"] = "Connection",
    ["关"] = "off",
    ["翻页器（%s）"] = "Page turner (%s)",
    ["更新"] = "Updates",
    ["自动检查更新"] = "Auto-check for updates",
    ["每天最多一次，有新版本时提示"] = "At most daily; prompts when a new version exists",
    ["检查更新"] = "Check for updates",
    ["正在检查或安装更新，请稍候"] = "An update check or install is in progress, please wait",
    ["更新信息无效，请稍后再试"] = "Invalid update info, try again later",
    ["新版本缺少插件包，请稍后再试"] = "Release has no plugin archive, try again later",
    ["更新包校验失败，请稍后再试"] = "Update checksum mismatch, try again later",
    ["更新包过大，已中止下载"] = "Update archive too large, download aborted",
    ["正在下载翻页器更新…"] = "Downloading page turner update…",
    ["更新完成，正在重启 KOReader…"] = "Update complete, restarting KOReader…",
    ["翻页器更新失败：%s"] = "Page turner update failed: %s",
    ["正在安装翻页器更新…"] = "Installing page turner update…",
    ["发现翻页器 %s（当前 %s）。下载并完整替换插件目录？"] =
        "Page turner %s found (current %s). Download and replace the plugin folder?",
    ["更新日志"] = "Release notes",
    ["稍后"] = "Later",
    ["下载并安装"] = "Download and install",
    ["正在检查翻页器更新…"] = "Checking for page turner updates…",
    ["检查更新失败：%s"] = "Update check failed: %s",
    ["已是最新版本（%s）"] = "Already up to date (%s)",
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
