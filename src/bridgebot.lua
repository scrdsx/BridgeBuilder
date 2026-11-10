-- Bridge builder logic for Last Bridge Standing (place 88943954655371).
-- It uses the game's OWN modules (Shared.BuildConfig / DesignRules / LocalDesign / Maps, Client.RoundRules) so every beam is checked by the game's
-- rules before it is sent, and it pushes the design through the game's own BuildController so you SEE it and the budget bar updates.
-- Design format (same as the game): Remotes.Design:FireServer({ beams = { {x1, y1, x2, y2, material}, ... } }), coordinates in cells (1/8 cell grid).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

local Bot = {
	Auto = false, AutoReady = false, Upgrade = true, SpendPct = 100,
	Info = "starting", Last = "nothing built yet", Phase = "-", Layout = "-", Twist = "-", Budget = 0, Spent = 0, Beams = 0, Shape = "-",
	Busy = false, LogLines = {}, Changed = nil, Hooked = false,
}

local function log(...)
	local t = {}
	for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
	local line = os.date("%H:%M:%S") .. "  " .. table.concat(t, " ")
	Bot.LogLines[#Bot.LogLines + 1] = line
	if #Bot.LogLines > 500 then table.remove(Bot.LogLines, 1) end
	pcall(function() if writefile then writefile("BridgeScript_log.txt", table.concat(Bot.LogLines, "\n")) end end)
end
Bot.Log = log
local function changed() if Bot.Changed then task.defer(Bot.Changed) end end

-- game modules (loaded in Start) --------------------------------------------------------------------------------------
local Shared, Remotes, RoundState, Design, BuildConfig, DesignRules, LocalDesign, Maps, Twists, Vehicles, RoundRules, UpgradeCatalogue, UpgradeView, ClientFolder
local cardsEnv

local function load()
	Shared = RS:WaitForChild("Shared", 15)
	Remotes = RS:WaitForChild("Remotes", 15)
	RoundState = RS:WaitForChild("RoundState", 15)
	assert(Shared and Remotes and RoundState, "game folders not found - are you in Last Bridge Standing?")
	Design = Remotes:WaitForChild("Design", 10)
	BuildConfig = require(Shared:WaitForChild("BuildConfig"))
	DesignRules = require(Shared:WaitForChild("DesignRules"))
	LocalDesign = require(Shared:WaitForChild("LocalDesign"))
	Maps = require(Shared:WaitForChild("Maps"))
	Twists = require(Shared:WaitForChild("Twists"))
	Vehicles = require(Shared:WaitForChild("Vehicles"))
	UpgradeCatalogue = require(Shared:WaitForChild("UpgradeCatalogue"))
	ClientFolder = lp:WaitForChild("PlayerScripts"):WaitForChild("Client")
	RoundRules = require(ClientFolder:WaitForChild("RoundRules"))
	pcall(function() UpgradeView = require(ClientFolder:WaitForChild("UpgradeView", 5)) end)
	local stars
	pcall(function() stars = require(Shared:WaitForChild("StarCatalogue", 5)) end)
	cardsEnv = { maps = Maps, twists = Twists, vehicles = Vehicles, designRules = DesignRules, config = BuildConfig, stars = stars }
end

-- the current round as the game sees it -------------------------------------------------------------------------------
local function readRound()
	local card = RoundRules.fromInstance(cardsEnv, RoundState, lp)
	if not card then return nil, "the round is not ready yet" end
	local budget = card.budget
	pcall(function()
		local attr = lp:GetAttribute(UpgradeCatalogue.upgrades.budget.attribute)
		local own = UpgradeView.ownBudget(UpgradeCatalogue, card.budget, attr, card.unlimited, UpgradeView.bonusApplies(false))
		if type(own) == "number" then budget = own end
	end)
	local rules = DesignRules.makeRules(BuildConfig, card.map, budget, card.materials)
	return card, rules, budget
end

local function snap(v) return math.floor(v * 8 + 0.5) / 8 end
local function studs(dx, dy) return BuildConfig.cellSize * math.sqrt(dx * dx + dy * dy) end

-- members: the abstract bridge (roles), realised with materials later --------------------------------------------------
-- Warren truss under the deck: deck nodes every `step`, bottom nodes in the middle of every panel, diagonals in a W, bottom chord, braces from lower anchors.
local function genMembers(card, p, h)
	local m = card.map
	local cl = m.cliffs or { left = m.zone.minX, right = m.zone.maxX, top = m.deckY or 0 }
	local L, R, top = cl.left, cl.right, cl.top
	local W = R - L
	if W <= 0 then return nil end
	local n = math.max(1, math.ceil(W / p - 1e-6))
	local step = W / n
	if step > BuildConfig.reach.road then return nil end
	local xs = {}
	for i = 0, n do xs[i + 1] = L + i * step end
	local mem = {}
	local bot = top - h
	for i = 1, n do mem[#mem + 1] = { xs[i], top, xs[i + 1], top, role = "deck" } end
	local mids = {}
	for i = 1, n do
		local a, b = xs[i], xs[i + 1]
		local mid = (a + b) / 2
		mids[i] = mid
		mem[#mem + 1] = { a, top, mid, bot, role = "diag" }
		mem[#mem + 1] = { mid, bot, b, top, role = "diag" }
	end
	for i = 1, n - 1 do mem[#mem + 1] = { mids[i], bot, mids[i + 1], bot, role = "chord" } end
	for _, an in ipairs(m.anchors or {}) do
		if an[2] < top - 0.01 then
			local mid = (an[1] <= L) and mids[1] or mids[n]
			mem[#mem + 1] = { an[1], an[2], mid, bot, role = "brace" }
		end
	end
	return mem, { L = L, R = R, top = top, n = n, step = step, h = h }
end

local function baseMaterial(rules)
	if rules.allowed.wood then return "wood" end
	if rules.allowed.steel then return "steel" end
	if rules.allowed.cable then return "cable" end
	return "road"
end

local function realize(rules, mem)
	local d = LocalDesign.new(rules)
	local base = baseMaterial(rules)
	local refused, deckOK, why = 0, true, {}
	for _, b in ipairs(mem) do
		local mat = b.mat or (b.role == "deck" and "road") or base
		local ok, r = d:place(snap(b[1]), snap(b[2]), snap(b[3]), snap(b[4]), mat)
		if not ok then
			refused = refused + 1
			why[tostring(r)] = (why[tostring(r)] or 0) + 1
			if b.role == "deck" then deckOK = false end
		end
	end
	return d, refused, deckOK, why
end

local function plan(rules, card, budget)
	local cap = math.floor(budget * (Bot.SpendPct / 100))
	if budget >= 100000 then cap = math.min(cap, 60000) end -- unlimited rounds: do not waste time on a silly spend
	local best, bestScore, failWhy, failPlaced
	for _, p in ipairs({ 4, 3.5, 3, 2.5, 2, 1.5 }) do
		for _, h in ipairs({ 1, 2, 3, 4 }) do
			local mem, info = genMembers(card, p, h)
			if mem then
				local d, refused, deckOK, why = realize(rules, mem)
				local placed = #mem - refused
				if deckOK and d:getSpent() <= cap then
					-- beams the budget refused are dropped, so prefer designs that lose nothing
					-- a truss is strong when it is about span/6 deep and its diagonals are ~55 degrees (step about 1.4 x depth); spend the budget, lose nothing
					local W = info.R - info.L
					local hWant = math.clamp(W / 6, 2, 4)
					local score = -math.abs(h - hWant) * 4 - math.abs(info.step / h - 1.4) * 3 - refused * 5 + d:getSpent() / math.max(cap, 1) * 2
					if not best or score > bestScore then best, bestScore = { mem = mem, info = info, p = p, h = h, refused = refused }, score end
				elseif not deckOK and (not failPlaced or placed > failPlaced) then
					failWhy, failPlaced = why, placed
				end
			end
		end
	end
	if not best then return nil, failWhy end
	-- spend what is left on steel where it matters (steel reach is short, so only short members)
	if Bot.Upgrade and rules.allowed.steel then
		local d0 = realize(rules, best.mem)
		local remaining = cap - d0:getSpent()
		local info = best.info
		local center = (info.L + info.R) / 2
		local order = {}
		for _, b in ipairs(best.mem) do
			if b.role == "chord" then order[#order + 1] = { b = b, pri = math.abs((b[1] + b[3]) / 2 - center) }
			elseif b.role == "diag" or b.role == "brace" then order[#order + 1] = { b = b, pri = 100 + math.min(math.abs((b[1] + b[3]) / 2 - info.L), math.abs((b[1] + b[3]) / 2 - info.R)) } end
		end
		table.sort(order, function(a, c) return a.pri < c.pri end)
		local reachSteel = BuildConfig.reach.steel
		for _, o in ipairs(order) do
			local b = o.b
			local dx, dy = b[3] - b[1], b[4] - b[2]
			if dx * dx + dy * dy <= reachSteel * reachSteel then
				local extra = math.round((BuildConfig.prices.steel - BuildConfig.prices.wood) * studs(dx, dy))
				if extra <= remaining then b.mat = "steel"; remaining = remaining - extra end
			end
		end
	end
	local d, refused, deckOK = realize(rules, best.mem)
	if not deckOK or d:getSpent() > budget or refused > best.refused then
		for _, b in ipairs(best.mem) do b.mat = nil end -- the upgrade did not fit: plain version
		d = realize(rules, best.mem)
	end
	return d, best
end

-- the game's own controller (so the bridge is drawn and the budget bar follows) --------------------------------------
local ctrl
local function findController()
	if ctrl and rawget(ctrl, "design") ~= nil then return ctrl end
	ctrl = nil
	if not getgc then return nil end
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" then
			local ok, hit = pcall(function()
				return rawget(t, "design") ~= nil and rawget(t, "renderer") ~= nil and rawget(t, "roundState") ~= nil and rawget(t, "remote") ~= nil
			end)
			if ok and hit then ctrl = t; return t end
		end
	end
	return nil
end

local reply
local replyConn
local wrapped = {}
local function hookClass()
	local ok, cls = pcall(function() return require(ClientFolder:WaitForChild("BuildController", 10)) end)
	if not ok or type(cls) ~= "table" then log("BuildController class not found: " .. tostring(cls)); return end
	for _, name in ipairs({ "onFrame", "refreshCards", "refreshAim", "refreshSnap", "scheduleSend", "onResponse", "refreshReady" }) do
		local orig = rawget(cls, name)
		if type(orig) == "function" then
			wrapped[#wrapped + 1] = { cls = cls, name = name, orig = orig }
			cls[name] = function(self, ...)
				if rawget(self, "design") ~= nil then ctrl = self end
				return orig(self, ...)
			end
		end
	end
	log("hooked " .. #wrapped .. " controller methods")
end
local function unhookClass()
	for _, w in ipairs(wrapped) do pcall(function() w.cls[w.name] = w.orig end) end
	wrapped = {}
end

local function deliver(list, spent)
	reply = nil
	local c = findController()
	if c then
		c.design:setList(list)
		pcall(function() c.renderer:sync(c.design:entries(), false) end)
		pcall(function() c.hud:setBudget(c.design:getSpent(), c.budget, false) end)
		c:send()
		return "game"
	end
	Design:FireServer({ beams = list })
	return "remote"
end

function Bot.BuildNow()
	if Bot.Busy then return false, "busy" end
	if not Design then Bot.Last = "not loaded: " .. tostring(Bot.Info); changed(); return false end
	Bot.Busy = true
	local ok, err = pcall(function()
		local card, rules, budget = readRound()
		if not card then Bot.Last = tostring(rules); log(Bot.Last); return end
		Bot.Phase = tostring(RoundState:GetAttribute("Phase"))
		if Bot.Phase ~= "Build" then Bot.Last = "wait for the build phase (now: " .. Bot.Phase .. ")"; log(Bot.Last); return end
		if type(lp:GetAttribute("Lane")) ~= "number" then Bot.Last = "you have no lane yet"; log(Bot.Last); return end
		Bot.Layout, Bot.Twist, Bot.Budget = tostring(card.layout), tostring(card.twist), budget
		local d, best = plan(rules, card, budget)
		if not d then
			local w = {}
			for k, n in pairs(best or {}) do w[#w + 1] = k .. " x" .. n end
			Bot.Last = "no valid bridge for this layout (" .. table.concat(w, ", ") .. ")"
			log(Bot.Last, "layout=" .. Bot.Layout, "twist=" .. Bot.Twist, "budget=" .. tostring(budget))
			return
		end
		local list = d:toList()
		Bot.Spent, Bot.Beams = d:getSpent(), #list
		local counts = {}
		for _, b in ipairs(list) do counts[b[5]] = (counts[b[5]] or 0) + 1 end
		Bot.Shape = ("%d panels, depth %d"):format(best.info.n, best.h)
		log(("layout=%s twist=%s budget=%d materials=%s | %s | beams=%d spent=%d | road %d wood %d steel %d cable %d"):format(
			Bot.Layout, Bot.Twist, budget, table.concat(card.materials, ","), Bot.Shape, #list, Bot.Spent,
			counts.road or 0, counts.wood or 0, counts.steel or 0, counts.cable or 0))
		local how = deliver(list, Bot.Spent)
		local t0 = os.clock()
		while reply == nil and os.clock() - t0 < 3 do task.wait(0.05) end
		if type(reply) == "table" then
			Bot.Last = reply.ok == true and ("built: %d beams, %d / %d"):format(#list, Bot.Spent, budget) or ("server refused: " .. tostring(reply.reason))
		else
			Bot.Last = ("sent via %s, no reply yet"):format(how)
		end
		if how == "remote" then Bot.Last = Bot.Last .. " (preview off: game controller not found)" end
		log("result:", Bot.Last)
		if Bot.AutoReady and type(reply) == "table" and reply.ok == true then
			local R = Remotes:FindFirstChild("Ready")
			if R then task.wait(0.4); R:FireServer(true); log("ready sent") end
		end
	end)
	Bot.Busy = false
	if not ok then Bot.Last = "error: " .. tostring(err); log(Bot.Last) end
	changed()
	return ok
end

function Bot.TestDrive()
	local TD = Remotes and Remotes:FindFirstChild("TestDrive")
	if TD then TD:FireServer("start"); log("test drive requested; charges left:", tostring(lp:GetAttribute("TestDrivesLeft"))) end
end

function Bot.Ready(on)
	local R = Remotes and Remotes:FindFirstChild("Ready")
	if R then R:FireServer(on ~= false); log("ready:", tostring(on ~= false)) end
end

function Bot.CopyLog()
	local s = table.concat(Bot.LogLines, "\n")
	pcall(function() if setclipboard then setclipboard(s) end end)
	return #Bot.LogLines
end

-- start / stop ------------------------------------------------------------------------------------------------------
local conns = {}
local lastRound

function Bot.Start()
	local ok, err = pcall(load)
	if not ok then Bot.Info = "load failed: " .. tostring(err); log(Bot.Info); changed(); return false end
	replyConn = Design.OnClientEvent:Connect(function(r) reply = r end)
	conns[#conns + 1] = replyConn
	pcall(function()
		local TD = Remotes:WaitForChild("TestDrive", 5)
		if TD then conns[#conns + 1] = TD.OnClientEvent:Connect(function(...)
			local t = {}
			for i = 1, select("#", ...) do local v = select(i, ...); t[i] = type(v) == "table" and "{table}" or tostring(v) end
			log("testdrive:", table.concat(t, ", "))
		end) end
	end)
	conns[#conns + 1] = RoundState:GetAttributeChangedSignal("Phase"):Connect(function()
		Bot.Phase = tostring(RoundState:GetAttribute("Phase"))
		changed()
		if Bot.Auto and Bot.Phase == "Build" then
			local id = tostring(RoundState:GetAttribute("BuildFrom"))
			if id == lastRound then return end
			lastRound = id
			task.wait(2.5)
			Bot.BuildNow()
		end
	end)
	pcall(hookClass)
	task.spawn(function() -- find the game's controller early so the first build already shows
		for _ = 1, 20 do if findController() then Bot.Hooked = true; break end task.wait(0.5) end
		log("game controller:", Bot.Hooked and "found (bridge will be drawn)" or "not found (the bridge is sent, the preview may not show)")
		changed()
	end)
	Bot.Info = "ready"
	Bot.Phase = tostring(RoundState:GetAttribute("Phase"))
	log("loaded. phase=" .. Bot.Phase .. " layout=" .. tostring(RoundState:GetAttribute("Layout")) .. " twist=" .. tostring(RoundState:GetAttribute("Twist")))
	changed()
	return true
end

function Bot.Destroy()
	unhookClass()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
	Bot.Auto = false
end

return Bot
