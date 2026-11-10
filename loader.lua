-- Bridge Builder loader: fetches each module from src/ and runs them. No bundle needed.
-- Set getgenv().BridgeBase to the folder URL (ending in /) that holds loader.lua and src/.
-- Set getgenv().BridgeLocal = "BridgeBuilder/" to read from the executor workspace instead.
local env = getgenv and getgenv() or _G
local BASE = env.BridgeBase or "https://raw.githubusercontent.com/scrdsx/BridgeBuilder/main/"
local LOCAL = env.BridgeLocal
local MODULES = { "logo", "icons", "ui", "bridgebot", "main" } -- main last

-- raw.githubusercontent.com caches files for ~5 minutes (and some executors cache on top), so a plain
-- fetch can hand back an old release. Pin to the latest commit SHA instead: those URLs never go stale.
-- The update watcher and "Update now" always use the BRANCH (main), even when you started from a commit-pinned link,
-- so pressing "Update now" in Settings always gets the newest version and you never have to change the script again.
local POLL_BASE = BASE
do
	local o, r = BASE:match("raw%.githubusercontent%.com/([^/]+)/([^/]+)/")
	if o then POLL_BASE = ("https://raw.githubusercontent.com/%s/%s/main/"):format(o, r) end
end
local commit
if not LOCAL then
	local owner, repo, branch = BASE:match("raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/")
	if owner then
		local ok, body = pcall(function()
			return game:HttpGet(("https://api.github.com/repos/%s/%s/commits/%s"):format(owner, repo, branch))
		end)
		if ok then
			local okj, data = pcall(function() return game:GetService("HttpService"):JSONDecode(body) end)
			if okj and type(data) == "table" and type(data.sha) == "string" then
				commit = data.sha
				BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(owner, repo, commit)
			end
		end
	end
end
env.BridgeCommit = commit and commit:sub(1, 7) or "unpinned"

local sources, cache = {}, {}

-- version check support: main.lua polls this to notice a new release
local function fetchVersion()
	local v
	if LOCAL then v = readfile(LOCAL .. "version.txt")
	else v = game:HttpGet(POLL_BASE .. "version.txt?t=" .. os.time()) end
	return (v:gsub("%s+", ""))
end
env.BridgeFetchVersion = fetchVersion
local okv, ver
if commit then okv, ver = pcall(function() return (game:HttpGet(BASE .. "version.txt"):gsub("%s+", "")) end)
else okv, ver = pcall(fetchVersion) end
env.BridgeVersion = okv and ver or "unknown"
env.BridgeReload = function() -- re-run this loader (used by "Update now")
	if LOCAL then return loadstring(readfile(LOCAL .. "loader.lua"))() end
	env.BridgeBase = POLL_BASE -- the new loader resolves the latest commit itself
	return loadstring(game:HttpGet(POLL_BASE .. "loader.lua?t=" .. os.time()))()
end

local function fetch(name)
	local path = "src/" .. name .. ".lua"
	if LOCAL then return readfile(LOCAL .. path) end
	return game:HttpGet(BASE .. path .. "?t=" .. os.time()) -- bust caches while developing
end

local function req(name)
	if cache[name] == nil then
		local src = sources[name]
		assert(src, "unknown module: " .. tostring(name))
		-- inject `__import` on the first line so error line numbers stay correct (never shadow Roblox's require)
		local fn, err = loadstring("local __import = ...;" .. src, "=" .. name)
		assert(fn, name .. ": " .. tostring(err))
		cache[name] = fn(req)
		if cache[name] == nil then cache[name] = true end
	end
	return cache[name]
end

for _, name in ipairs(MODULES) do
	local ok, res = pcall(fetch, name)
	assert(ok, "failed to load " .. name .. ": " .. tostring(res))
	sources[name] = res
end

return req("main")
