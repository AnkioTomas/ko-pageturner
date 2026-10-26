--[[--
翻页器自更新：复用月读的 GitHub 更新管线（Release 接口、直连与镜像竞速下载、Job 子进程、进度窗），
只把仓库、包名与换目录逻辑换成自己的。只在月读里可用，月读依赖都在用到时才 require。

包体唯一信任根是 Release 接口给的资产 sha256；镜像只搬运字节，校验不过回落直连。
旧版 Release 资产名带 v（pageturner.koplugin-v0.2.0.zip），新版不带；两边都认。
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local T = require("pageturner_l10n")

local Update = { _job = nil, _offered = nil }

local ID = "ext.pageturner"
local REPO = "AnkioTomas/ko-pageturner"
local API_URL = "https://api.ankio.net/gh/repos/" .. REPO .. "/releases/latest"
local GITHUB = "https://github.com"
local ASSET_PREFIX = "^https://github%.com/" .. REPO:gsub("%-", "%%-") .. "/releases/download/"
local DIR_NAME = "pageturner.koplugin"
local CHECK_INTERVAL = 24 * 60 * 60
local MAX_BYTES = 20 * 1024 * 1024
local PROBE_MIRRORS = 5

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

function Update.version()
    local v = require("pageturner_version")
    if v and v ~= "0.0.0-dev" then return v end
    -- CI 若只注入了 _meta.lua（workflow 改动未推上时），从那儿读。
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and type(meta.version) == "string"
        and meta.version ~= "" and not meta.version:find("dev", 1, true) then
        return meta.version
    end
    return v or "0.0.0-dev"
end

local function settings()
    return require("utils.settings").getSource(ID)
end

local function save()
    require("utils.settings").saveSource(ID)
end

function Update.autoEnabled()
    return settings().auto_update_check ~= false
end

function Update.setAuto(on)
    settings().auto_update_check = on and true or false
    save()
end

local function newer(candidate, installed)
    local left = { candidate:match("^(%d+)%.(%d+)%.(%d+)") }
    local right = { installed:match("^(%d+)%.(%d+)%.(%d+)") }
    if #right == 0 then return true end
    for i = 1, 3 do
        local l, r = tonumber(left[i]), tonumber(right[i])
        if l ~= r then return l > r end
    end
    return false
end

local function parseRelease(body)
    local ok, release = pcall(require("json").decode, body)
    if not ok or type(release) ~= "table" or release.draft or release.prerelease then
        return nil, "invalid release response"
    end
    local tag = release.tag_name
    local version = type(tag) == "string" and tag:match("^v?(%d+%.%d+%.%d+[%w%.%+%-]*)$")
    if not version then return nil, "invalid release version" end
    -- 新包名不带 v；旧 Release（v0.2.0）带 v，两边都认。
    local want = {
        [DIR_NAME .. "-" .. version .. ".zip"] = true,
        [DIR_NAME .. "-v" .. version .. ".zip"] = true,
    }
    local zip
    for _i, asset in ipairs(release.assets or {}) do
        local url = asset.browser_download_url
        if want[asset.name] and type(url) == "string" and url:match(ASSET_PREFIX) then
            zip = asset
            break
        end
    end
    if not zip then return nil, "release has no plugin archive" end
    local digest = (zip.digest or ""):match("^sha256:(" .. ("%x"):rep(64) .. ")$")
    if not digest then return nil, "release has no plugin checksum" end
    return {
        version = version,
        url = zip.browser_download_url,
        size = tonumber(zip.size),
        sha256 = digest:lower(),
        notes = type(release.body) == "string" and release.body:gsub("^%s+", ""):gsub("%s+$", "") or nil,
        available = newer(version, Update.version()),
    }
end

function Update.check(cb)
    if Update._job then return cb(nil, "busy") end
    Update._job = require("http.request").get(API_URL, {
        timeout = require("http.timeout").net(1),
        headers = { Accept = "application/vnd.github+json", ["X-GitHub-Api-Version"] = "2022-11-28" },
    }, function(body, err)
        Update._job = nil
        if err then return cb(nil, err) end
        local release, parse_err = parseRelease(body)
        if not release then return cb(nil, parse_err) end
        settings().update_last_checked_at = os.time()
        save()
        cb(release)
    end)
end

local function removeTree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local ok, err = removeTree(path .. "/" .. name)
            if not ok then return nil, err end
        end
    end
    return lfs.rmdir(path)
end

local function fileSha256(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local hash = require("ffi/sha2").sha256()
    for chunk in function() return file:read(256 * 1024) end do hash(chunk) end
    file:close()
    return hash()
end

local function extract(archive, staging)
    if not lfs.mkdir(staging) then return nil, "cannot create update staging directory" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(archive) then return nil, reader.err or "cannot open update archive" end
    local ok = true
    for entry in reader:iterate() do
        ok = reader:extractToPath(entry.path, staging .. "/" .. entry.path)
        if not ok then break end
    end
    local err = reader.err
    reader:close()
    if not ok or err then return nil, err or "archive extraction failed" end
    return true
end

local function installArchive(archive, sha256)
    local digest, err = fileSha256(archive)
    if not digest then return nil, err end
    if digest ~= sha256 then return nil, "update checksum mismatch" end
    local parent = PLUGIN_DIR:match("^(.*)/[^/]+$")
    local staging = parent .. "/.pageturner.koplugin-update"
    local backup = parent .. "/.pageturner.koplugin-backup"
    local ok
    ok, err = removeTree(staging)
    if ok then ok, err = extract(archive, staging) end
    if ok and lfs.attributes(staging .. "/" .. DIR_NAME .. "/main.lua", "mode") ~= "file" then
        ok, err = nil, "not a pageturner plugin archive"
    end
    if ok then ok, err = removeTree(backup) end
    if ok then ok, err = os.rename(PLUGIN_DIR, backup) end
    if not ok then
        removeTree(staging)
        return nil, err
    end
    ok, err = os.rename(staging .. "/" .. DIR_NAME, PLUGIN_DIR)
    if not ok then
        local restored, restore_err = os.rename(backup, PLUGIN_DIR)
        removeTree(staging)
        if not restored then return nil, "install failed and rollback failed: " .. tostring(restore_err) end
        return nil, err
    end
    removeTree(staging)
    return true
end

local function pickDownloadUrl(release, cb)
    local Request = require("http.request")
    local path = release.url:sub(#GITHUB + 1)
    local pool = { unpack(require("http.mirror").RELEASE_PROXIES) }
    local prefixes = { GITHUB }
    for i = 1, math.min(PROBE_MIRRORS, #pool) do
        local j = math.random(i, #pool)
        pool[i], pool[j] = pool[j], pool[i]
        prefixes[#prefixes + 1] = pool[i]
    end
    local jobs, pending, settled = {}, #prefixes, false
    local function cancelAll()
        settled = true
        for _i, job in ipairs(jobs) do job:cancel() end
    end
    local function settle(url)
        if settled then return end
        cancelAll()
        cb(url)
    end
    local guard = require("ui.guard")
    for i, prefix in ipairs(prefixes) do
        jobs[i] = Request.stream({
            url = prefix .. path, timeout = require("http.timeout").net(1 / 3), allow_redirects = true,
        }, {
            on_headers = function(code, headers)
                if code ~= 200 then return end
                local length = tonumber((headers:get("Content-Length", true)))
                if length and release.size and length ~= release.size then return end
                local mime = headers:get("Content-Type", true)
                if mime and mime:lower():find("text/html", 1, true) then return end
                UIManager:nextTick(guard.wrap("pageturner update settle", function() settle(prefix .. path) end))
            end,
            on_done = function()
                pending = pending - 1
                if pending == 0 then
                    UIManager:nextTick(guard.wrap("pageturner update settle", function() settle(release.url) end))
                end
            end,
        })
    end
    return { cancel = cancelAll }
end

local function installFrom(url, release, done, on_progress, on_installing)
    local function fail(err)
        if url == release.url then return done(false, err) end
        installFrom(release.url, release, done, on_progress, on_installing)
    end
    local Paths = require("utils.paths")
    Paths.ensureDir(Paths.root())
    local archive = Paths.root() .. "/pageturner-update.zip"
    os.remove(archive)
    Update._job = require("http.request").download({
        url = url, timeout = require("http.timeout").net(10), allow_redirects = true,
        max_bytes = MAX_BYTES, on_progress = on_progress,
    }, archive, function(ok, err)
        if not ok then return fail(err) end
        if on_installing then on_installing() end
        Update._job = require("workers.job").run(function()
            local installed, install_err = installArchive(archive, release.sha256)
            if not installed then error(install_err, 0) end
        end, {
            name = "pageturner.update", kind = "heavy", timeout = 120,
            on_done = function()
                os.remove(archive)
                done(true)
            end,
            on_failed = function(install_err)
                os.remove(archive)
                if tostring(install_err):find("update checksum mismatch", 1, true) then
                    fail(install_err)
                else
                    done(false, install_err)
                end
            end,
        })
    end)
end

function Update.cancel()
    if Update._job then Update._job:cancel() end
    Update._job = nil
end

local function errorText(err)
    local text = tostring(err)
    local known = {
        { "^busy$", T("正在检查或安装更新，请稍候") },
        { "^invalid release", T("更新信息无效，请稍后再试") },
        { "^release has no", T("新版本缺少插件包，请稍后再试") },
        { "update checksum mismatch", T("更新包校验失败，请稍后再试") },
        { "download too large", T("更新包过大，已中止下载") },
    }
    for _i, entry in ipairs(known) do
        if text:find(entry[1]) then return entry[2] end
    end
    return text:match("[^\n]*")
end

local function toast(text, timeout)
    require("ui.themes.widgets.toast"):new{ text = text, timeout = timeout }:show()
end

local function startInstall(release)
    local ProgressDialog = require("ui.themes.widgets.progress_dialog")
    local dialog = ProgressDialog:new{
        title = T("正在下载翻页器更新…"), dismissable = false, on_cancel = Update.cancel,
    }
    dialog:show()
    local function done(ok, err)
        Update._job = nil
        if ok then
            dialog:set(T("更新完成，正在重启 KOReader…"), 100)
            UIManager:nextTick(function()
                UIManager:broadcastEvent(require("ui/event"):new("Restart"))
            end)
            return
        end
        dialog:close()
        toast(T("翻页器更新失败：%s", errorText(err)), 5)
    end
    if Update._job then return done(false, "busy") end
    Update._job = pickDownloadUrl(release, function(url)
        installFrom(url, release, done, function(bytes)
            if release.size and release.size > 0 then dialog:bytes(bytes, release.size) end
        end, function()
            dialog:close()
            dialog = ProgressDialog:new{ title = T("正在安装翻页器更新…"), dismissable = false }
            dialog:show()
        end)
    end)
end

local function promptInstall(release)
    if Update._offered == release.version then return end
    Update._offered = release.version
    local header = T("发现翻页器 %s（当前 %s）。下载并完整替换插件目录？",
        release.version, Update.version())
    local dialog
    dialog = require("ui.themes.widgets.text_viewer"):new{
        title = T("更新日志"),
        text = release.notes and release.notes ~= "" and (header .. "\n\n" .. release.notes) or header,
        buttons = {
            { text = T("稍后"), callback = function() dialog:close() end },
            { text = T("下载并安装"), variant = "primary", callback = function()
                dialog:close()
                startInstall(release)
            end },
        },
    }
    dialog:show()
end

function Update.manualCheck()
    local loading = require("ui.themes.widgets.progress_dialog"):new{
        title = T("检查更新"), text = T("正在检查翻页器更新…"), dismissable = false,
    }
    loading:show()
    Update.check(function(release, err)
        loading:close()
        if err then
            toast(T("检查更新失败：%s", errorText(err)), 4)
        elseif release.available then
            Update._offered = nil
            promptInstall(release)
        else
            toast(T("已是最新版本（%s）", Update.version()), 3)
        end
    end)
end

local autoChecked = false

--- 每个进程最多一次；距上次成功检查满 24h、已联网才发请求；只提示，不静默安装。
function Update.autoCheck()
    if autoChecked or not Update.autoEnabled() then return end
    autoChecked = true
    if os.time() - (settings().update_last_checked_at or 0) < CHECK_INTERVAL then return end
    if not require("ui/network/manager"):isConnected() then return end
    Update.check(function(release)
        if release and release.available then promptInstall(release) end
    end)
end

return Update
