-- bridge_dump.lua : ONE dump for Last Bridge Standing (place 88943954655371). Run it in the lobby / at your build plot.
-- Writes to  workspace/BridgeDump/  (read from disk, nothing to copy):
--   index.txt          summary
--   scripts_index.txt  every LocalScript / ModuleScript
--   src/*.lua          decompiled client code (building, materials, budget, trucks, rounds)
--   keyword_hits.txt   lines with budget / price / strength / limit / cost / template ... in that code
--   replicated.txt     ReplicatedStorage tree (templates, materials, prices, strength) with attributes + values
--   templates.txt      everything named template / preset / blueprint / design / level / map anywhere
--   workspace.txt      Workspace tree (plots, anchors, build area, river, trucks) depth 4 + tags
--   gui.txt            every text on screen (budget, prices, buttons, material names)
--   remotes.txt        every remote
--   player.txt         your attributes, leaderstats, character, gc tables that look like materials/budget
--   remote_log.txt     (phase 2) every remote YOU fire while you build ONE bridge by hand + press start: the exact build protocol
-- Phase 2 listens for REC_SECONDS: after "[dump] RECORDING" appears, place a few pieces by hand (each material once), delete one, start the round.
-- Stop early:  getgenv().BridgeDump.Stop()
local REC_SECONDS = 150
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local lp = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G
if env.BridgeDump then pcall(env.BridgeDump.Stop) end
local running = true
env.BridgeDump = { Stop = function() running = false end }

local DIR = "BridgeDump"
pcall(function() if makefolder then makefolder(DIR); makefolder(DIR .. "/src") end end)
local NL = string.char(10)
local function save(name, text) pcall(function() writefile(DIR .. "/" .. name, text) end) end
local function full(i) local ok, r = pcall(game.GetFullName, i); return ok and r or tostring(i) end
local function v3(v) return ("(%.2f,%.2f,%.2f)"):format(v.X, v.Y, v.Z) end
local function posOf(i)
	if i:IsA("BasePart") then return i.Position end
	if i:IsA("Model") then local ok, cf = pcall(function() return i:GetPivot() end); if ok then return cf.Position end end
	if i:IsA("Attachment") then return i.WorldPosition end
end
local function attrs(i)
	local t = {}
	for k, v in pairs(i:GetAttributes()) do t[#t + 1] = k .. "=" .. tostring(v):sub(1, 60) end
	table.sort(t)
	return #t > 0 and (" [" .. table.concat(t, ", ") .. "]") or ""
end
local function valueOf(i)
	if i:IsA("ValueBase") then local ok, v = pcall(function() return i.Value end); if ok then return " = " .. tostring(v):sub(1, 80) end end
	return ""
end
local index = {}
local function note(s) index[#index + 1] = s; print("[dump] " .. s) end
note("started " .. os.date("%H:%M:%S") .. "  place=" .. tostring(game.PlaceId) .. "  you=" .. lp.Name)

-- generic tree writer: groups same-name siblings, shows attributes, values, sizes, prompts
local function tree(inst, depth, maxDepth, indent, out)
	if depth > maxDepth then return end
	local groups, order = {}, {}
	for _, k in ipairs(inst:GetChildren()) do
		local key = k.Name .. "|" .. k.ClassName
		if not groups[key] then groups[key] = { n = 0, first = k }; order[#order + 1] = key end
		groups[key].n = groups[key].n + 1
	end
	for _, key in ipairs(order) do
		local g = groups[key]
		local k = g.first
		local p = posOf(k)
		local extra = ""
		if k:IsA("BasePart") then extra = (" size%s"):format(v3(k.Size)) end
		if k:IsA("ProximityPrompt") then extra = (" PROMPT '%s'/'%s'"):format(k.ObjectText, k.ActionText) end
		if k:IsA("TextLabel") or k:IsA("TextButton") then extra = " '" .. k.Text:sub(1, 50) .. "'" end
		out[#out + 1] = indent .. k.Name .. " (" .. k.ClassName .. ")" .. (g.n > 1 and (" x" .. g.n) or "") .. (p and (" " .. v3(p)) or "") .. extra .. valueOf(k) .. attrs(k)
		if #out < 20000 then tree(k, depth + 1, maxDepth, indent .. "  ", out) end
	end
end

-- 1) scripts --------------------------------------------------------------------------------------------------------
local scripts, seen = {}, {}
-- getscripts() also returns Roblox's own CorePackages / CoreGui / PlayerModule (tens of thousands): skip those, they are not the game
local SKIP = { "CorePackages", "CoreGui", "PlayerModule", "RbxCharacterSounds", "Packages._Index", "%.Animate$", "%.Health$" }
local function addScript(s)
	if seen[s] or not (s:IsA("LocalScript") or s:IsA("ModuleScript")) then return end
	seen[s] = true
	local p = full(s)
	for _, k in ipairs(SKIP) do if p:find(k) then return end end
	scripts[#scripts + 1] = s
end
pcall(function() for _, s in ipairs(getscripts()) do addScript(s) end end)
pcall(function() for _, s in ipairs(getloadedmodules()) do addScript(s) end end)
for _, root in ipairs({ RS, lp, game:GetService("ReplicatedFirst"), workspace, game:GetService("StarterPlayer"), game:GetService("StarterGui") }) do
	pcall(function() for _, d in ipairs(root:GetDescendants()) do addScript(d) end end)
end
local lines = {}
for _, s in ipairs(scripts) do lines[#lines + 1] = s.ClassName .. "  " .. full(s) end
table.sort(lines)
save("scripts_index.txt", table.concat(lines, NL))
note(#scripts .. " scripts found")

-- 2) decompile ------------------------------------------------------------------------------------------------------
local KEYS = { "build", "beam", "bridge", "part", "piece", "material", "wood", "steel", "cable", "road", "budget", "price", "cost", "strength", "stress",
	"load", "weight", "truck", "wave", "round", "plot", "anchor", "node", "joint", "weld", "constraint", "place", "delete", "undo", "template", "preset",
	"design", "level", "map", "coin", "upgrade", "network", "remote", "service", "controller", "client", "data", "config", "setting", "physics", "chaos" }
local ranked = {}
for _, s in ipairs(scripts) do
	local p = full(s):lower()
	if not p:find("rbxts_include", 1, true) and not p:find("react", 1, true) then
		local score = 0
		for _, k in ipairs(KEYS) do if p:find(k, 1, true) then score = score + 1 end end
		ranked[#ranked + 1] = { s = s, score = score, path = full(s) }
	end
end
table.sort(ranked, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.path < b.path end)
local MAX = 600
local hits, done, failed = {}, 0, 0
local HITWORDS = { "budget", "price", "cost", "strength", "maxforce", "breakforce", "limit", "max_", "template", "preset", "blueprint", "FireServer", "InvokeServer",
	"kick", "exploit", "cheat", "magnitude >", "length", "thickness", "snap" }
if decompile then
	local t0 = os.clock()
	for i = 1, math.min(#ranked, MAX) do
		if not running or os.clock() - t0 > 600 then break end
		local r = ranked[i]
		local src
		local finished = false
		task.spawn(function() local ok, res = pcall(decompile, r.s); if ok then src = res end; finished = true end)
		local w = os.clock()
		while not finished and os.clock() - w < 12 do task.wait(0.05) end
		if src and #src > 0 then
			done = done + 1
			local name = (("%03d_"):format(i) .. r.path:gsub("[^%w]", "_")):sub(1, 150) .. ".lua"
			save("src/" .. name, "-- " .. r.path .. NL .. src:sub(1, 400000))
			local ln = 0
			for line in (src .. NL):gmatch("(.-)" .. NL) do
				ln = ln + 1
				local low = line:lower()
				for _, w2 in ipairs(HITWORDS) do
					if low:find(w2:lower(), 1, true) then
						if #hits < 900 then hits[#hits + 1] = ("%s:%d: %s"):format(r.path, ln, line:gsub("^%s+", ""):sub(1, 170)) end
						break
					end
				end
			end
		else
			failed = failed + 1
		end
		if i % 20 == 0 then print(("[dump] decompiled %d / %d"):format(i, math.min(#ranked, MAX))) end
	end
	note(("decompiled %d scripts (%d failed or empty)"):format(done, failed))
else
	note("this executor has no decompile(): script sources were NOT dumped")
end
save("keyword_hits.txt", table.concat(hits, NL))

-- 3) ReplicatedStorage tree + templates -----------------------------------------------------------------------------
local out = {}
tree(RS, 1, 6, "", out)
save("replicated.txt", table.concat(out, NL))
note("ReplicatedStorage written (" .. #out .. " lines)")

out = {}
local TKEYS = { "template", "preset", "blueprint", "design", "level", "map", "example", "tutorial", "solution", "ghost" }
for _, root in ipairs({ RS, workspace, lp, game:GetService("StarterGui"), game:GetService("ReplicatedFirst"), game:GetService("Lighting") }) do
	pcall(function()
		for _, d in ipairs(root:GetDescendants()) do
			local low = d.Name:lower()
			for _, k in ipairs(TKEYS) do
				if low:find(k, 1, true) then
					if #out < 1500 then out[#out + 1] = ("%s (%s) %d children%s%s"):format(full(d), d.ClassName, #d:GetChildren(), valueOf(d), attrs(d)) end
					break
				end
			end
		end
	end)
end
for _, tag in ipairs(CS:GetAllTags()) do
	local l = tag:lower()
	for _, k in ipairs(TKEYS) do if l:find(k, 1, true) then out[#out + 1] = "TAG " .. tag .. " (" .. #CS:GetTagged(tag) .. ")"; break end end
end
save("templates.txt", table.concat(out, NL))
note(#out .. " template-looking things")

-- 4) workspace + tags ----------------------------------------------------------------------------------------------
out = {}
out[#out + 1] = "workspace attrs" .. attrs(workspace) .. "  Gravity=" .. workspace.Gravity
tree(workspace, 1, 4, "", out)
out[#out + 1] = "######## TAGS"
for _, tag in ipairs(CS:GetAllTags()) do
	local list = CS:GetTagged(tag)
	out[#out + 1] = ("== %s (%d)"):format(tag, #list)
	for i = 1, math.min(#list, 12) do local o = list[i]; local p = posOf(o); out[#out + 1] = ("   %s %s%s"):format(full(o), p and v3(p) or "", attrs(o)) end
end
save("workspace.txt", table.concat(out, NL))
note("workspace written (" .. #out .. " lines)")

-- 5) gui text -------------------------------------------------------------------------------------------------------
out = {}
local seenText = {}
for _, d in ipairs(lp.PlayerGui:GetDescendants()) do
	if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
		local key = d.Name .. "|" .. d.Text
		if not seenText[key] and #out < 1200 then seenText[key] = true; out[#out + 1] = ("%s  '%s'%s"):format(full(d), d.Text:sub(1, 80), d.Visible and "" or "  (hidden)") end
	end
end
save("gui.txt", table.concat(out, NL))
note(#out .. " texts on screen")

-- 6) remotes --------------------------------------------------------------------------------------------------------
out = {}
for _, root in ipairs({ RS, workspace, game:GetService("ReplicatedFirst") }) do
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("UnreliableRemoteEvent") or d:IsA("BindableEvent") then out[#out + 1] = d.ClassName .. "  " .. full(d) .. attrs(d) end
	end
end
save("remotes.txt", table.concat(out, NL))

-- 7) you + materials/budget in memory ------------------------------------------------------------------------------
out = {}
out[#out + 1] = "player attrs:" .. attrs(lp)
local ls = lp:FindFirstChild("leaderstats")
for _, v in ipairs(ls and ls:GetChildren() or {}) do out[#out + 1] = "leaderstats." .. v.Name .. " = " .. tostring(v.Value) end
for _, c in ipairs(lp:GetChildren()) do if c:IsA("ValueBase") or c:IsA("Folder") then out[#out + 1] = "player." .. c.Name .. " (" .. c.ClassName .. ")" .. valueOf(c) .. attrs(c) end end
local c = lp.Character
if c then out[#out + 1] = "character attrs:" .. attrs(c) end
out[#out + 1] = "---- tables in memory with material / budget / price keys ----"
if getgc then
	local n, found = 0, 0
	local WANT = { "Wood", "wood", "Steel", "steel", "Cable", "cable", "Road", "road", "Budget", "budget", "Price", "price", "Cost", "cost", "Strength", "strength" }
	for _, t in ipairs(getgc(true)) do
		n = n + 1
		if n % 4000 == 0 then task.wait() end
		if not running then break end
		if type(t) == "table" and found < 60 then
			local okk, hit = pcall(function() for _, k in ipairs(WANT) do if rawget(t, k) ~= nil then return true end end return false end)
			if okk and hit then
				found = found + 1
				local p, cnt = {}, 0
				for k, v in pairs(t) do
					cnt = cnt + 1
					if cnt > 14 then break end
					local vs = type(v) == "table" and "{table}" or tostring(v):sub(1, 30)
					p[#p + 1] = tostring(k) .. "=" .. vs
				end
				out[#out + 1] = "  {" .. table.concat(p, ", ") .. "}"
			end
		end
	end
end
save("player.txt", table.concat(out, NL))
save("index.txt", table.concat(index, NL))
note("PHASE 1 DONE " .. os.date("%H:%M:%S"))

-- 8) phase 2: record the remotes YOU fire while building one bridge by hand ---------------------------------------
local function ser(v, d)
	d = d or 0
	local t = typeof(v)
	if t == "Vector3" then return ("V3(%.3f,%.3f,%.3f)"):format(v.X, v.Y, v.Z) end
	if t == "CFrame" then return "CF(" .. table.concat({ v:GetComponents() }, ","):sub(1, 140) .. ")" end
	if t == "Instance" then return "<" .. full(v) .. ">" end
	if t == "table" then
		if d > 3 then return "{...}" end
		local p, n = {}, 0
		for k, x in pairs(v) do
			n = n + 1
			if n > 24 then p[#p + 1] = "..."; break end
			p[#p + 1] = "[" .. ser(k, d + 1) .. "]=" .. ser(x, d + 1)
		end
		return "{" .. table.concat(p, ", ") .. "}"
	end
	if t == "string" then return ("%q"):format(v:sub(1, 80)) end
	return tostring(v)
end
local log, counts = {}, {}
if hookmetamethod and getnamecallmethod then
	local old
	old = hookmetamethod(game, "__namecall", function(self, ...)
		local m = getnamecallmethod()
		if running and (m == "FireServer" or m == "InvokeServer") then
			local a = { ... }
			pcall(function()
				local key = full(self)
				counts[key] = (counts[key] or 0) + 1
				if counts[key] <= 60 then
					local p = {}
					for i = 1, #a do p[i] = ser(a[i]) end
					log[#log + 1] = ("%7.2f  %s:%s(%s)"):format(os.clock() % 10000, key, m, table.concat(p, ", "))
				end
			end)
		end
		return old(self, ...)
	end)
	note("RECORDING for " .. REC_SECONDS .. " s: place a few pieces by hand (each material once), delete one, then start the round")
	local t0 = os.clock()
	while running and os.clock() - t0 < REC_SECONDS do
		task.wait(5)
		save("remote_log.txt", table.concat(log, NL))
	end
	running = false
	local sum = {}
	for k, n in pairs(counts) do sum[#sum + 1] = ("%5d  %s"):format(n, k) end
	table.sort(sum, function(a, b) return a > b end)
	save("remote_log.txt", "# call counts" .. NL .. table.concat(sum, NL) .. NL .. NL .. "# first calls" .. NL .. table.concat(log, NL))
	note("recorded " .. #log .. " calls")
else
	note("this executor has no hookmetamethod: remote_log.txt skipped (the decompiled src still shows the build calls)")
end
running = false
save("index.txt", table.concat(index, NL))
pcall(function() setclipboard(table.concat(index, NL)) end)
print("[dump] ALL DONE - files are in workspace/" .. DIR)
