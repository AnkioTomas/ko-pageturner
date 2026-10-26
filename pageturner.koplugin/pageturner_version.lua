--[[--
插件版本号。发布时 CI 把占位符换成真实版本；源码里运行显示 0.0.0-dev。
--]]
local VERSION = "@VERSION@"

if VERSION == "" or VERSION:find("@", 1, true) then return "0.0.0-dev" end
return VERSION
