-- Bridge builder logic for Last Bridge Standing (place 88943954655371).
-- It uses the game's OWN modules (Shared.BuildConfig / DesignRules / LocalDesign / Maps, Client.RoundRules) so every beam is checked by the game's
-- rules before it is sent, and it pushes the design through the game's own BuildController so you SEE it and the budget bar updates.
-- Design format (same as the game): Remotes.Design:FireServer({ beams = { {x1, y1, x2, y2, material}, ... } }), coordinates in cells (1/8 cell grid).
local Truss = __import("truss")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

local Bot = {
	Auto = false, AutoReady = false, Upgrade = true, SpendPct = 100,
	Info = "starting", Last = "nothing built yet", Phase = "-", Layout = "-", Twist = "-", Budget = 0, Spent = 0, Beams = 0, Shape = "-",
	Busy = false, LogLines = {}, Changed = nil, Hooked = false,
	Custom = false, ForceDepth = 0, ForcePanel = 0,
	over = {}, Tuning = false, Version = "?",
}

local function log(...)
	local t = {}
	for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
	local line = os.date("%H:%M:%S") .. "  " .. table.concat(t, " ")
	Bot.LogLines[#Bot.LogLines + 1] = line
	if #Bot.LogLines > 500 then table.remove(Bot.LogLines, 1) end
	pcall(function() if writefile then writefile("BridgeBuilder_log.txt", table.concat(Bot.LogLines, "\n")) end end)
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


-- Winner's design from the recorded data: deck of road, road posts hanging down at the deck nodes, and a CABLE chain through the post bottoms and the
-- lower cliff anchors (cable is tension-only and far stronger than wood). Extra crossing cables stiffen it when the budget allows.
local function genCable(card, s, h)
	local m = card.map
	local cl = m.cliffs or { left = m.zone.minX, right = m.zone.maxX, top = m.deckY or 0 }
	local L, R, top = cl.left, cl.right, cl.top
	local W = R - L
	if W <= 0 then return nil end
	local n = math.max(2, math.ceil(W / s - 1e-6))
	local step = W / n
	if step > BuildConfig.reach.road then return nil end
	local xs = {}
	for i = 0, n do xs[i + 1] = L + i * step end
	local bot = top - h
	local mem = {}
	for i = 1, n do mem[#mem + 1] = { xs[i], top, xs[i + 1], top, role = "deck", base = "road" } end
	for i = 2, n do mem[#mem + 1] = { xs[i], top, xs[i], bot, role = "post", base = "road" } end
	-- lowest anchor on each side (the cable ends); the deck end node if there is none below the deck
	local la, ra
	for _, an in ipairs(m.anchors or {}) do
		if an[2] < top - 0.01 then
			if an[1] <= L + 0.01 then if not la or an[2] < la[2] then la = an end
			elseif an[1] >= R - 0.01 then if not ra or an[2] < ra[2] then ra = an end end
		end
	end
	la = la or { L, top }
	ra = ra or { R, top }
	mem[#mem + 1] = { la[1], la[2], xs[2], bot, role = "chord", base = "cable" }
	for i = 2, n - 1 do mem[#mem + 1] = { xs[i], bot, xs[i + 1], bot, role = "chord", base = "cable" } end
	mem[#mem + 1] = { ra[1], ra[2], xs[n], bot, role = "chord", base = "cable" }
	-- crossing cables, centre first (they only start from points that already exist)
	local order = {}
	for i = 2, n - 1 do order[#order + 1] = i end
	local mid = (n + 2) / 2
	table.sort(order, function(a, b) return math.abs(a - mid) < math.abs(b - mid) end)
	for _, i in ipairs(order) do
		mem[#mem + 1] = { xs[i], top, xs[i + 1], bot, role = "xdiag", base = "cable" }
		mem[#mem + 1] = { xs[i + 1], top, xs[i], bot, role = "xdiag", base = "cable" }
	end
	return mem, { L = L, R = R, top = top, n = n, step = step, h = h, family = "cable" }
end

local function baseMaterial(rules)
	if rules.allowed.wood then return "wood" end
	if rules.allowed.steel then return "steel" end
	if rules.allowed.cable then return "cable" end
	return "road"
end

local function sigOf(b) return ("%.2f,%.2f,%.2f,%.2f"):format(b[1], b[2], b[3], b[4]) end

local function realize(rules, mem)
	local d = LocalDesign.new(rules)
	local base = baseMaterial(rules)
	local refused, deckOK, why, placed = 0, true, {}, {}
	for _, b in ipairs(mem) do
		local mat = b.mat or Bot.over[sigOf(b)] or b.base or (b.role == "deck" and "road") or base
		if b.role == "deck" then mat = "road" end
		local ok, r = d:place(snap(b[1]), snap(b[2]), snap(b[3]), snap(b[4]), mat)
		if not ok then
			refused = refused + 1
			why[tostring(r)] = (why[tostring(r)] or 0) + 1
			if b.role == "deck" then deckOK = false end
		else
			placed[#placed + 1] = b
		end
	end
	return d, refused, deckOK, why, placed
end

local function plan(rules, card, budget)
	local cap = math.floor(budget * (Bot.SpendPct / 100))
	if budget >= 100000 then cap = math.min(cap, 60000) end -- unlimited rounds: do not waste time on a silly spend
	local best, bestScore, failWhy, failPlaced
	local panels, depths = { 4, 3.5, 3, 2.5, 2, 1.5 }, { 1, 2, 3, 4 }
	local cpanels, cdepths = { 4, 3.5, 3, 2.5, 2 }, { 2, 2.5, 3, 3.5, 4, 5 }
	if Bot.Custom then
		if Bot.ForcePanel > 0 then panels, cpanels = { Bot.ForcePanel }, { Bot.ForcePanel } end
		if Bot.ForceDepth > 0 then depths, cdepths = { Bot.ForceDepth }, { Bot.ForceDepth } end
	end
	local families = { "warren" }
	if Bot.geom and Bot.geomKey == Bot.roundKey then -- tuning: keep the geometry so the learned beams still match
		panels, depths, cpanels, cdepths = { Bot.geom.p }, { Bot.geom.h }, { Bot.geom.p }, { Bot.geom.h }
		families = { Bot.geom.family }
	end
	for _, fam in ipairs(families) do
		local ps, hs = panels, depths
		if fam == "cable" then ps, hs = cpanels, cdepths end
		for _, p in ipairs(ps) do
			for _, h in ipairs(hs) do
				local mem, info
				if fam == "cable" then mem, info = genCable(card, p, h) else mem, info = genMembers(card, p, h) end
				if mem then
					local d, refused, deckOK, why = realize(rules, mem)
					local placed = #mem - refused
					if deckOK and d:getSpent() <= cap then
						local W = info.R - info.L
						local score
						if fam == "cable" then
							-- recorded winner: posts about span/5 deep, panels about 3 cells; spend the budget, lose nothing
							local hWant = math.clamp(W / 5, 2, 4)
							score = 6 - math.abs(h - hWant) * 3 - math.abs(info.step - 3) * 2 - refused * 0.4 + d:getSpent() / math.max(cap, 1) * 4
						else
							local hWant = math.clamp(W / 6, 2, 4)
							score = -math.abs(h - hWant) * 4 - math.abs(info.step / h - 1.4) * 3 - refused * 5 + d:getSpent() / math.max(cap, 1) * 2
						end
						if not best or score > bestScore then best, bestScore = { mem = mem, info = info, p = p, h = h, refused = refused, family = fam }, score end
					elseif not deckOK and (not failPlaced or placed > failPlaced) then
						failWhy, failPlaced = why, placed
					end
				end
			end
		end
	end
	if not best then return nil, failWhy end
	-- spend what is left on steel where it matters (steel reach is short, so only short members)
	if Bot.Upgrade and rules.allowed.steel and next(Bot.over) == nil and best.family ~= "cable" then
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
	local d, refused, deckOK, _, placed = realize(rules, best.mem)
	if not deckOK or d:getSpent() > budget or refused > best.refused then
		for _, b in ipairs(best.mem) do b.mat = nil end -- the upgrade did not fit: plain version
		d, _, _, _, placed = realize(rules, best.mem)
	end
	best.placed = placed
	return d, best
end

-- SOLVER PLANNER ---------------------------------------------------------------------------------------------------------
-- Several truss topologies x panel widths x depths. Each is analysed with a real truss solver (src/truss.lua), then the budget is spent on the
-- most stressed beams (a stronger material where its reach allows) while over-built beams are made cheaper. Capacities come from the recorded rounds.
local CAP = { wood = { t = 1.0, c = 1.0 }, steel = { t = 3.0, c = 2.5 }, cable = { t = 0.5, c = 0 }, road = { t = 2.0, c = 2.0 } }
Bot.Cap = CAP

local function pkey(x, y) return ("%d,%d"):format(math.floor(x * 8 + 0.5), math.floor(y * 8 + 0.5)) end

local function trussOpts(card, top)
	local set = {}
	for _, an in ipairs(card.map.anchors or {}) do set[pkey(an[1], an[2])] = true end
	return {
		supports = function(x, y) return set[pkey(x, y)] == true end,
		loadAt = function(x, y) return math.abs(y - top) < 0.01 end,
	}
end

local function memLen(b) return math.sqrt((b[3] - b[1]) ^ 2 + (b[4] - b[2]) ^ 2) end
local function costOf(mat, lenCells) return math.round(BuildConfig.prices[mat] * BuildConfig.cellSize * lenCells) end
local function reachOK(mat, lenCells) local r = BuildConfig.reach[mat]; return r ~= nil and lenCells <= r + 1e-6 end

local function frame(card, s)
	local m = card.map
	local cl = m.cliffs or { left = m.zone.minX, right = m.zone.maxX, top = m.deckY or 0 }
	local L, R, top = cl.left, cl.right, cl.top
	local W = R - L
	if W <= 0 then return nil end
	local n = math.max(2, math.ceil(W / s - 1e-6))
	local step = W / n
	if step > BuildConfig.reach.road then return nil end
	local xs = {}
	for i = 0, n do xs[i + 1] = L + i * step end
	local la, ra
	for _, an in ipairs(m.anchors or {}) do
		if an[2] < top - 0.01 then
			if an[1] <= L + 0.01 then if not la or an[2] < la[2] then la = an end
			elseif an[1] >= R - 0.01 then if not ra or an[2] < ra[2] then ra = an end end
		end
	end
	return { L = L, R = R, top = top, n = n, step = step, xs = xs, la = la, ra = ra }
end

local function newMem()
	local mem, seen = {}, {}
	local function add(x1, y1, x2, y2, role)
		local a, b = pkey(x1, y1), pkey(x2, y2)
		local k = a < b and (a .. "|" .. b) or (b .. "|" .. a)
		if seen[k] or a == b then return end
		seen[k] = true
		mem[#mem + 1] = { x1, y1, x2, y2, role = role }
	end
	return mem, add
end

-- Pratt (as the round winner "Wren" built): posts under the deck nodes, bottom chord from anchor to anchor, diagonals leaning to the centre
local function genPratt(card, s, h)
	local f = frame(card, s)
	if not f or not f.la or not f.ra then return nil end
	local n, xs, top = f.n, f.xs, f.top
	local bot = top - h
	local mem, add = newMem()
	for i = 1, n do add(xs[i], top, xs[i + 1], top, "deck") end
	for i = 2, n do add(xs[i], top, xs[i], bot, "post") end
	local B = {}
	B[1] = { f.la[1], f.la[2] }
	for i = 2, n do B[i] = { xs[i], bot } end
	B[n + 1] = { f.ra[1], f.ra[2] }
	for i = 1, n do add(B[i][1], B[i][2], B[i + 1][1], B[i + 1][2], "chord") end
	for i = 1, n + 1 do
		if i <= n / 2 + 0.01 and i <= n then add(B[i][1], B[i][2], xs[i + 1], top, "diag")
		elseif i > n / 2 + 1 then add(B[i][1], B[i][2], xs[i - 1], top, "diag") end
	end
	return mem, { L = f.L, R = f.R, top = top, n = n, step = f.step, h = h }
end

-- posts with a W of diagonals (the other winner shape): every post bottom reaches both neighbouring deck nodes
local function genPostW(card, s, h, chord)
	local f = frame(card, s)
	if not f then return nil end
	local n, xs, top = f.n, f.xs, f.top
	local bot = top - h
	local mem, add = newMem()
	for i = 1, n do add(xs[i], top, xs[i + 1], top, "deck") end
	for i = 2, n do add(xs[i], top, xs[i], bot, "post") end
	for i = 2, n do
		add(xs[i], bot, xs[i - 1], top, "diag")
		add(xs[i], bot, xs[i + 1], top, "diag")
	end
	if f.la then add(f.la[1], f.la[2], xs[2], bot, "brace") end
	if f.ra then add(f.ra[1], f.ra[2], xs[n], bot, "brace") end
	if chord ~= false then for i = 2, n - 1 do add(xs[i], bot, xs[i + 1], bot, "chord") end end
	return mem, { L = f.L, R = f.R, top = top, n = n, step = f.step, h = h }
end

local function startMats(rules, mem)
	local base = baseMaterial(rules)
	local mats = {}
	for i, b in ipairs(mem) do
		if b.role == "deck" then mats[i] = "road"
		else
			local m = Bot.over[sigOf(b)] or base
			if not reachOK(m, memLen(b)) then
				m = "wood"
				if not (rules.allowed.wood and reachOK("wood", memLen(b))) then m = rules.allowed.cable and "cable" or "road" end
			end
			mats[i] = m
		end
	end
	return mats
end

local function beamsOf(mem, mats)
	local out = {}
	for i, b in ipairs(mem) do out[i] = { b[1], b[2], b[3], b[4], mats[i] } end
	return out
end

local function totalCost(mem, mats)
	local t = 0
	for i, b in ipairs(mem) do t = t + costOf(mats[i], memLen(b)) end
	return t
end

local function evaluate(mem, mats, opts)
	return Truss.strength(beamsOf(mem, mats), opts, CAP)
end

-- drop beams that carry nothing (free saving), then, if the design is over the budget, drop the least loaded beams while it stays sound
local function reduce(mem, mats, opts, cap)
	local m2, t2, protected = {}, {}, {}
	for i, b in ipairs(mem) do m2[i] = b; t2[i] = mats[i] end
	for _ = 1, 60 do
		local lam, r = evaluate(m2, t2, opts)
		if not lam then return m2, t2 end
		local total = totalCost(m2, t2)
		local victim, vf = nil, math.huge
		for i, b in ipairs(m2) do
			if b.role ~= "deck" and not protected[b] then
				local fi = r.f[i]
				if fi < 1e-6 then victim, vf = i, -1; break end
				if total > cap and fi < vf then victim, vf = i, fi end
			end
		end
		if not victim then break end
		local m3, t3 = {}, {}
		for i, b in ipairs(m2) do if i ~= victim then m3[#m3 + 1] = b; t3[#t3 + 1] = t2[i] end end
		local lam2 = evaluate(m3, t3, opts)
		if lam2 and (vf < 0 or lam2 >= lam * 0.35) then
			m2, t2 = m3, t3
		else
			protected[m2[victim]] = true
		end
	end
	return m2, t2
end

-- spend the budget where the stress is: upgrade the weakest non-deck beam, pay for it by making over-built beams cheaper
local function optimise(rules, mem, mats, opts, capBudget)
	local total = totalCost(mem, mats)
	for _ = 1, 70 do
		local lam, r = evaluate(mem, mats, opts)
		if not lam then break end
		local beams = beamsOf(mem, mats)
		-- utilisation of every non-deck beam: capacity / force (smaller = closer to breaking)
		local util, worst, worstU = {}, nil, math.huge
		for i, b in ipairs(mem) do
			if b.role ~= "deck" and r.f[i] > 1e-9 then
				local c = CAP[mats[i]]
				local k = r.sign[i] > 0 and c.t or c.c
				util[i] = k / r.f[i]
				if util[i] < worstU then worst, worstU = i, util[i] end
			end
		end
		if not worst then break end
		local b, len, cur, sign = mem[worst], memLen(mem[worst]), mats[worst], r.sign[worst]
		local curK = sign > 0 and CAP[cur].t or CAP[cur].c
		local pick, pickK
		for _, m in ipairs({ "road", "steel", "wood", "cable" }) do
			if m ~= cur and rules.allowed[m] and reachOK(m, len) and (m ~= "cable" or sign > 0) then
				local k = sign > 0 and CAP[m].t or CAP[m].c
				if k > curK * 1.05 and total + costOf(m, len) - costOf(cur, len) <= capBudget then
					if not pickK or k > pickK then pick, pickK = m, k end
				end
			end
		end
		if pick then
			total = total + costOf(pick, len) - costOf(cur, len)
			mats[worst] = pick
		else
			-- no money: find the most over-built beam and make it cheaper while it stays well above the weakest one
			local freed = false
			local order = {}
			for i, u in pairs(util) do order[#order + 1] = { i = i, u = u } end
			table.sort(order, function(a, c) return a.u > c.u end)
			for _, o in ipairs(order) do
				if o.u > worstU * 2.5 then
					local bi, li, ci = mem[o.i], memLen(mem[o.i]), mats[o.i]
					local sg = r.sign[o.i]
					local best, bestSave
					for _, m in ipairs({ "wood", "road", "cable", "steel" }) do
						if m ~= ci and rules.allowed[m] and reachOK(m, li) and (m ~= "cable" or sg > 0) then
							local k = sg > 0 and CAP[m].t or CAP[m].c
							local save = costOf(ci, li) - costOf(m, li)
							if save > 0 and k / r.f[o.i] >= worstU * 1.8 and (not bestSave or save > bestSave) then best, bestSave = m, save end
						end
					end
					if best then mats[o.i] = best; total = total - bestSave; freed = true; break end
				end
			end
			if not freed then break end
		end
	end
	return mats, total
end


local function density(mem)
	local nodes, n = {}, 0
	for _, b in ipairs(mem) do
		local a, c = pkey(b[1], b[2]), pkey(b[3], b[4])
		if not nodes[a] then nodes[a] = true; n = n + 1 end
		if not nodes[c] then nodes[c] = true; n = n + 1 end
	end
	return #mem / math.max(n, 1)
end

-- what the 51 recorded bridges say: the ones that lasted longest spent the most, were braced the densest, used little cable
local function rank(lam, spent, cap, mem)
	return 0.6 * math.min(lam or 0, 2) + 3 * math.min(spent / math.max(cap, 1), 1) + 1.5 * density(mem)
end

local function plan2(rules, card, budget)
	local cap = math.floor(budget * (Bot.SpendPct / 100))
	if budget >= 100000 then cap = math.min(cap, 60000) end
	local f0 = frame(card, 3)
	if not f0 then return nil end
	local opts = trussOpts(card, f0.top)
	local cands = {}
	local ss, hs = { 4, 3.5, 3, 2.5, 2 }, { 2, 3, 4 }
	if Bot.Custom then
		if Bot.ForcePanel > 0 then ss = { Bot.ForcePanel } end
		if Bot.ForceDepth > 0 then hs = { Bot.ForceDepth } end
	end
	local topos = { { "pratt", genPratt }, { "postW", genPostW }, { "fan", function(c, s, h) return genPostW(c, s, h, false) end }, { "warren", function(c, s, h) return genMembers(c, s, h) end } }
	for _, tp in ipairs(topos) do
		for _, s in ipairs(ss) do
			for _, h in ipairs(hs) do
				local mem, info = tp[2](card, s, h)
				if mem and #mem > 0 then
					local mats = startMats(rules, mem)
					mem, mats = reduce(mem, mats, opts, cap)
					local spent = totalCost(mem, mats)
					if spent <= cap then
						local lam = evaluate(mem, mats, opts)
						if lam then cands[#cands + 1] = { mem = mem, info = info, mats = mats, lam = lam, name = tp[1], s = s, h = h, score = rank(lam, spent, cap, mem) } end
					end
				end
			end
		end
	end
	if #cands == 0 then return nil end
	table.sort(cands, function(a, b) return a.score > b.score end)
	local top = {}
	for i = 1, math.min(8, #cands) do
		local c = cands[i]
		c.mats, c.cost = optimise(rules, c.mem, c.mats, opts, cap)
		c.lam2 = evaluate(c.mem, c.mats, opts) or 0
		c.score2 = rank(c.lam2, c.cost, cap, c.mem)
		top[#top + 1] = c
	end
	table.sort(top, function(a, b) return a.score2 > b.score2 end)
	-- the game's own rules have the last word: realise every candidate, drop beams the game refuses, re-measure what is left, keep the strongest
	local pick, pickLam, pickScore
	local shown = 0
	for _, c in ipairs(top) do
		for i, b in ipairs(c.mem) do b.mat = c.mats[i] end
		local d, refused, deckOK, why, placed = realize(rules, c.mem)
		if deckOK and d:getSpent() <= budget then
			local beams = {}
			for _, b in ipairs(placed) do beams[#beams + 1] = { b[1], b[2], b[3], b[4], b.mat } end
			local lamP = Truss.strength(beams, opts, CAP) or 0
			local sc = rank(lamP, d:getSpent(), cap, placed)
			if not pick or sc > pickScore then pick, pickLam, pickScore = { c = c, d = d, placed = placed, refused = refused }, lamP, sc end
		elseif shown < 3 then
			shown = shown + 1
			local w = {}
			for k, n in pairs(why or {}) do w[#w + 1] = k .. " x" .. n end
			log(("solver candidate %s s=%s h=%s refused by the game: deck %s, %s"):format(c.name, tostring(c.s), tostring(c.h), tostring(deckOK), table.concat(w, ", ")))
		end
	end
	if pick then
		local c = pick.c
		log(("solver: %s s=%s h=%s  strength %.2f -> %.2f  cost %d  (%d candidates, %d beams refused)"):format(c.name, tostring(c.s), tostring(c.h), c.lam, pickLam, pick.d:getSpent(), #cands, pick.refused))
		Bot.Strength = pickLam
		return pick.d, { mem = c.mem, info = c.info, p = c.s, h = c.h, refused = pick.refused, family = c.name, placed = pick.placed }
	end
	log("solver: no candidate had a complete deck under the game's rules - falling back")
	return nil
end

-- the game's own controller (so the bridge is drawn and the budget bar follows) --------------------------------------
local ctrl
local function findController()
	if ctrl and rawget(ctrl, "design") ~= nil then return ctrl end
	ctrl = nil
	local function isCtrl(t)
		if type(t) ~= "table" then return false end
		local ok, hit = pcall(function()
			return rawget(t, "design") ~= nil and rawget(t, "renderer") ~= nil and rawget(t, "roundState") ~= nil and rawget(t, "remote") ~= nil
		end)
		return ok and hit
	end
	local getups = (debug and debug.getupvalues) or getupvalues
	local function fromFunction(f, depth)
		if type(f) ~= "function" or not getups then return nil end
		local ok, ups = pcall(getups, f)
		if not ok or type(ups) ~= "table" then return nil end
		for _, v in pairs(ups) do
			if isCtrl(v) then return v end
		end
		if depth < 2 then
			for _, v in pairs(ups) do
				if type(v) == "function" then local r = fromFunction(v, depth + 1); if r then return r end end
			end
		end
		return nil
	end
	if getconnections then
		local signals = { Design and Design.OnClientEvent, lp:GetAttributeChangedSignal("Lane"), RoundState and RoundState:GetAttributeChangedSignal("Phase"),
			RoundState and RoundState:GetAttributeChangedSignal("Budget"), RoundState and RoundState:GetAttributeChangedSignal("EndsAt") }
		local ready = Remotes and Remotes:FindFirstChild("Ready")
		if ready then signals[#signals + 1] = ready.OnClientEvent end
		for _, sig in ipairs(signals) do
			local ok, conns = pcall(getconnections, sig)
			if ok and type(conns) == "table" then
				for _, c in ipairs(conns) do
					local f
					pcall(function() f = c.Function end)
					local r = fromFunction(f, 0)
					if r then ctrl = r; return r end
				end
			end
		end
	end
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
	for name, orig in pairs(cls) do
		if type(orig) == "function" and name ~= "new" and name ~= "destroy" then
			wrapped[#wrapped + 1] = { cls = cls, name = name, orig = orig }
			cls[name] = function(self, ...)
				if ctrl == nil and type(self) == "table" and rawget(self, "design") ~= nil and rawget(self, "renderer") ~= nil then ctrl = self end
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
		local rk = tostring(RoundState:GetAttribute("BuildFrom"))
		if rk ~= Bot.roundKey then Bot.roundKey = rk; Bot.over = {}; Bot.geom = nil end
		local ok2, d, best = pcall(plan2, rules, card, budget)
		if not ok2 then log("solver planner error: " .. tostring(d)); d, best = nil, nil end
		if not d then d, best = plan(rules, card, budget) end
		if not d then
			local w = {}
			for k, n in pairs(best or {}) do w[#w + 1] = k .. " x" .. n end
			Bot.Last = "no valid bridge for this layout (" .. table.concat(w, ", ") .. ")"
			log(Bot.Last, "layout=" .. Bot.Layout, "twist=" .. Bot.Twist, "budget=" .. tostring(budget))
			return
		end
		local list = d:toList()
		Bot.last = { placed = best.placed, list = list, budget = budget, cap = math.floor(budget * (Bot.SpendPct / 100)), best = best, rules = rules, card = card }
		Bot.geom, Bot.geomKey = { p = best.p, h = best.h, family = best.family }, Bot.roundKey
		Bot.Spent, Bot.Beams = d:getSpent(), #list
		local counts = {}
		for _, b in ipairs(list) do counts[b[5]] = (counts[b[5]] or 0) + 1 end
		Bot.Shape = ("%s: %d panels, depth %s"):format(best.family, best.info.n, tostring(best.h))
		log(("layout=%s twist=%s budget=%d materials=%s | %s | beams=%d spent=%d | road %d wood %d steel %d cable %d"):format(
			Bot.Layout, Bot.Twist, budget, table.concat(card.materials, ","), Bot.Shape, #list, Bot.Spent,
			counts.road or 0, counts.wood or 0, counts.steel or 0, counts.cable or 0))
		Bot.builtRound = tostring(RoundState:GetAttribute("BuildFrom"))
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

-- observer: reads the same public data the game shows everyone (test events + my own test-drive frames) ------------------
local TP
local Obs = { peak = {}, brokenIdx = {}, started = false, ended = false, setup = nil, outs = {} }
local HttpService = game:GetService("HttpService")

local function memMaterial(m, rules)
	if m.role == "deck" then return "road" end
	return m.mat or Bot.over[sigOf(m)] or baseMaterial(rules)
end

local function appendDataset(row)
	pcall(function()
		if not (writefile and makefolder) then return end
		pcall(makefolder, "BridgeData")
		local path = "BridgeData/rounds.jsonl"
		local old = ""
		if isfile and isfile(path) then old = readfile(path) end
		writefile(path, old .. HttpService:JSONEncode(row) .. "\n")
	end)
end

local function laneBeams(lane)
	local pts, out = lane.points or {}, {}
	local zero = false
	for _, b in ipairs(lane.beams or {}) do if b.a == 0 or b.b == 0 then zero = true break end end
	local add = zero and 1 or 0
	for _, b in ipairs(lane.beams or {}) do
		local ia, ib = b.a + add, b.b + add
		local ax, ay, bx, by = pts[2 * ia - 1], pts[2 * ia], pts[2 * ib - 1], pts[2 * ib]
		if ax and bx then out[#out + 1] = { ax, ay, bx, by, b.material, b.broken and 1 or 0 } end
	end
	return out
end

local function saveResults(ev)
	local setup = Obs.setup
	if not setup then return end
	local byLane = {}
	for _, l in ipairs(setup.lanes or {}) do byLane[l.lane] = l end
	local row = { t = os.time(), version = Bot.Version, layout = tostring(RoundState:GetAttribute("Layout")), twist = tostring(RoundState:GetAttribute("Twist")),
		budget = RoundState:GetAttribute("Budget"), waves = setup.waves, winner = ev.winner, rule = ev.rule, lanes = {} }
	local mine
	for _, r in ipairs(ev.ranking or {}) do
		local l = byLane[r.lane]
		local entry = { lane = r.lane, name = r.name, rank = r.rank, outWave = r.outWave, progress = r.progress, cost = r.cost, rings = r.rings, isGhost = r.isGhost }
		if l then
			entry.beams = laneBeams(l)
			local c = {}
			for _, b in ipairs(l.beams or {}) do c[b.material or "?"] = (c[b.material or "?"] or 0) + 1 end
			entry.mats = c
			entry.broken = Obs.brokenLane and Obs.brokenLane[r.lane] or 0
			if l.userId == lp.UserId then mine = entry end
		end
		row.lanes[#row.lanes + 1] = entry
	end
	appendDataset(row)
	local win
	for _, e in ipairs(row.lanes) do if e.lane == ev.winner then win = e end end
	local function mats(e) local t = {} for k, n in pairs(e.mats or {}) do t[#t + 1] = k .. " " .. n end table.sort(t) return table.concat(t, ", ") end
	if mine then
		Bot.LastRound = ("rank %s, out wave %s, cost %s"):format(tostring(mine.rank), tostring(mine.outWave or "survived all"), tostring(mine.cost))
		log("ROUND RESULT: you: " .. Bot.LastRound .. " | " .. mats(mine))
	end
	if win then log(("ROUND RESULT: winner %s cost %s | %s | rule=%s"):format(tostring(win.name), tostring(win.cost), mats(win), tostring(ev.rule))) end
	changed()
end

local function onTestEvents(buf)
	local evs = TP and TP.decodeEvents(buf)
	if not evs then return end
	for _, ev in ipairs(evs) do
		local t = ev.type
		if t == "setup" then Obs.setup, Obs.outs, Obs.brokenLane = ev, {}, {}
		elseif t == "beamBroke" then Obs.brokenLane = Obs.brokenLane or {}; Obs.brokenLane[ev.lane] = (Obs.brokenLane[ev.lane] or 0) + 1
		elseif t == "laneOut" then Obs.outs[ev.lane] = { wave = ev.wave, reason = ev.reason, progress = ev.progress }
		elseif t == "results" then pcall(saveResults, ev) end
	end
end

local function summarizeDrive()
	local L = Bot.last
	if not L then return end
	local per = {}
	for k, m in ipairs(L.placed) do
		local mat = memMaterial(m, L.rules)
		local e = per[mat] or { n = 0, max = 0, sum = 0, broke = 0 }
		per[mat] = e
		local pk = Obs.peak[k] or 0
		e.n = e.n + 1; e.sum = e.sum + pk; e.max = math.max(e.max, pk)
		if Obs.brokenIdx[k] then e.broke = e.broke + 1 end
	end
	local parts = {}
	for mat, e in pairs(per) do parts[#parts + 1] = ("%s n=%d max=%.2f avg=%.2f broke=%d"):format(mat, e.n, e.max, e.sum / math.max(e.n, 1), e.broke) end
	table.sort(parts)
	log("DRIVE STRESS: " .. table.concat(parts, " | "))
end

local function applyLearning()
	local L = Bot.last
	if not L then return false end
	local reach = BuildConfig.reach.steel
	local diff = BuildConfig.prices.steel - BuildConfig.prices.wood
	local hot, cold = {}, {}
	for k, m in ipairs(L.placed) do
		if m.role ~= "deck" then
			local pk, brk = Obs.peak[k] or 0, Obs.brokenIdx[k]
			local dx, dy = m[3] - m[1], m[4] - m[2]
			local cur = memMaterial(m, L.rules)
			if (brk or pk >= 0.8) and cur == "wood" and dx * dx + dy * dy <= reach * reach and L.rules.allowed.steel then
				hot[#hot + 1] = { sig = sigOf(m), pk = pk + (brk and 1 or 0), cost = math.round(diff * studs(dx, dy)) }
			elseif pk < 0.3 and cur == "steel" then
				cold[#cold + 1] = { sig = sigOf(m), pk = pk, cost = math.round(diff * studs(dx, dy)) }
			end
		end
	end
	table.sort(hot, function(a, b) return a.pk > b.pk end)
	table.sort(cold, function(a, b) return a.pk < b.pk end)
	local free = L.cap - Bot.Spent
	local up, down = 0, 0
	for _, h in ipairs(hot) do
		while h.cost > free and #cold > 0 do
			local c = table.remove(cold, 1)
			Bot.over[c.sig] = "wood"; free = free + c.cost; down = down + 1
		end
		if h.cost <= free then Bot.over[h.sig] = "steel"; free = free - h.cost; up = up + 1 end
	end
	log(("LEARNED: %d wood->steel, %d steel->wood (hot %d)"):format(up, down, #hot))
	return up + down > 0
end

function Bot.RunTestDrive(timeout)
	local TD = Remotes and Remotes:FindFirstChild("TestDrive")
	if not TD then return false end
	Obs.started, Obs.ended, Obs.peak, Obs.brokenIdx = false, false, {}, {}
	TD:FireServer("start")
	local t0 = os.clock()
	while not Obs.started and os.clock() - t0 < 6 do task.wait(0.1) end
	if not Obs.started then log("test drive did not start (no charges left or too late in the round)"); return false end
	t0 = os.clock()
	while not Obs.ended and os.clock() - t0 < (timeout or 45) do task.wait(0.2) end
	summarizeDrive()
	return Obs.ended
end

function Bot.AutoTune(rounds)
	if Bot.Tuning then return end
	Bot.Tuning = true
	changed()
	local ok, err = pcall(function()
		Bot.BuildNow()
		for i = 1, (rounds or 2) do
			if RoundState:GetAttribute("Phase") ~= "Build" then break end
			Bot.Info = ("tuning %d: test drive"):format(i); changed()
			if not Bot.RunTestDrive() then break end
			if not applyLearning() then log("nothing to change - this bridge looks balanced"); break end
			task.wait(0.5)
			Bot.Info = ("tuning %d: rebuild"):format(i); changed()
			Bot.BuildNow()
		end
	end)
	Bot.Tuning = false
	Bot.Info = "ready"
	if not ok then log("auto-tune error: " .. tostring(err)) end
	changed()
end

-- start / stop ------------------------------------------------------------------------------------------------------
local conns = {}
local lastRound

function Bot.Start()
	local ok, err = pcall(load)
	if not ok then Bot.Info = "load failed: " .. tostring(err); log(Bot.Info); changed(); return false end
	replyConn = Design.OnClientEvent:Connect(function(r) reply = r end)
	conns[#conns + 1] = replyConn
	pcall(function() TP = require(Shared:WaitForChild("TestProtocol")) end)
	pcall(function()
		local TD = Remotes:WaitForChild("TestDrive", 5)
		if TD then conns[#conns + 1] = TD.OnClientEvent:Connect(function(kind, id, a, b)
			if kind == "start" then Obs.started = true
			elseif kind == "end" then Obs.ended = true
			elseif kind == "events" then
				local evs = TP and type(a) == "buffer" and TP.decodeEvents(a)
				for _, ev in ipairs(evs or {}) do
					if ev.type == "beamBroke" then Obs.brokenIdx[ev.beam] = true; log("drive: beam " .. tostring(ev.beam) .. " broke")
					elseif ev.type == "waveStart" or ev.type == "vehicleFell" or ev.type == "vehicleArrived" or ev.type == "vehicleStuck" or ev.type == "laneOut" or ev.type == "waveSurvived" then
						log("drive: " .. ev.type .. (ev.kind and (" " .. tostring(ev.kind)) or "") .. (ev.reason and (" " .. tostring(ev.reason)) or ""))
					end
				end
			end
		end) end
		local TDF = Remotes:WaitForChild("TestDriveFrame", 5)
		if TDF then conns[#conns + 1] = TDF.OnClientEvent:Connect(function(id, buf)
			local f = TP and type(buf) == "buffer" and TP.decodeFrame(buf)
			if not f then return end
			for _, sec in ipairs(f.sections or {}) do
				for k, v in ipairs(sec.stress or {}) do
					local idx = (sec.beamStart or 1) + k - 1
					local ratio, brk = TP.stressRatio(v)
					if ratio > (Obs.peak[idx] or 0) then Obs.peak[idx] = ratio end
					if brk then Obs.brokenIdx[idx] = true end
				end
			end
		end) end
		local TE = Remotes:WaitForChild("TestEvent", 5)
		if TE then conns[#conns + 1] = TE.OnClientEvent:Connect(onTestEvents) end
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
	Bot.Version = tostring(env.BridgeVersion or "?")
	log("loaded v" .. Bot.Version .. ". phase=" .. Bot.Phase .. " layout=" .. tostring(RoundState:GetAttribute("Layout")) .. " twist=" .. tostring(RoundState:GetAttribute("Twist")))
	changed()
	return true
end


-- keep-alive: while Auto is on, make sure a bridge is on the server for the whole build phase (the game can overwrite it with an empty one)
task.spawn(function()
	while not Bot.dead do
		task.wait(5)
		if Design and RoundState and Bot.Auto and not Bot.Busy and not Bot.Tuning and RoundState:GetAttribute("Phase") == "Build" then
			local left = (RoundState:GetAttribute("EndsAt") or 0) - workspace:GetServerTimeNow()
			if left > 3 then
				local id = tostring(RoundState:GetAttribute("BuildFrom"))
				if Bot.builtRound ~= id then
					Bot.BuildNow()
				elseif Bot.last and Bot.last.list and #Bot.last.list > 0 and left < 40 then
					pcall(function() Design:FireServer({ beams = Bot.last.list }) end)
				end
			end
		end
	end
end)

function Bot.Destroy()
	Bot.dead = true
	unhookClass()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	conns = {}
	Bot.Auto = false
end

return Bot
