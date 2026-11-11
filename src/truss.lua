-- Pin-jointed 2D truss solver (direct stiffness method). Pure Lua: no Roblox calls, so it can be tested offline.
-- Truss.analyze(beams, opts) -> { f = {per member max |force| for a unit load}, sign = {+1 tension / -1 compression at that max}, ok = bool }
--   beams : array of { x1, y1, x2, y2, mat }          (any consistent unit; the game's cells are fine)
--   opts  : supports = function(x, y) -> bool         (nodes that are fixed: the cliff anchors)
--           loadAt   = function(x, y) -> bool         (nodes a vehicle can press on: deck nodes)
-- A cable can only pull: a cable that ends up in compression is switched off and the case is solved again.
local Truss = {}

local function key(x, y) return ("%d,%d"):format(math.floor(x * 8 + 0.5), math.floor(y * 8 + 0.5)) end

-- solve K u = p on the free degrees of freedom with Gaussian elimination (partial pivoting); returns nil if the structure is a mechanism
local function solve(K, p, n)
	local A = {}
	for i = 1, n do
		local row = {}
		for j = 1, n do row[j] = K[i][j] end
		row[n + 1] = p[i]
		A[i] = row
	end
	for c = 1, n do
		local piv, best = c, math.abs(A[c][c])
		for r = c + 1, n do
			local v = math.abs(A[r][c])
			if v > best then piv, best = r, v end
		end
		if best < 1e-9 then return nil end
		A[c], A[piv] = A[piv], A[c]
		local d = A[c][c]
		for r = c + 1, n do
			local f = A[r][c] / d
			if f ~= 0 then
				local ar, ac = A[r], A[c]
				for j = c, n + 1 do ar[j] = ar[j] - f * ac[j] end
			end
		end
	end
	local u = {}
	for i = n, 1, -1 do
		local s = A[i][n + 1]
		for j = i + 1, n do s = s - A[i][j] * u[j] end
		u[i] = s / A[i][i]
	end
	return u
end

function Truss.analyze(beams, opts)
	opts = opts or {}
	local nodes, order = {}, {}
	local function node(x, y)
		local k = key(x, y)
		local n = nodes[k]
		if not n then n = { x = x, y = y, id = #order + 1 }; nodes[k] = n; order[#order + 1] = n end
		return n
	end
	local mem = {}
	for i, b in ipairs(beams) do
		local a, c = node(b[1], b[2]), node(b[3], b[4])
		local dx, dy = c.x - a.x, c.y - a.y
		local L = math.sqrt(dx * dx + dy * dy)
		mem[i] = { a = a.id, b = c.id, L = L, cx = dx / L, cy = dy / L, mat = b[5] }
	end
	local N = #order
	-- degrees of freedom: 2 per node, fixed ones removed
	local free, idx = {}, {}
	for _, n in ipairs(order) do
		local fixed = opts.supports and opts.supports(n.x, n.y)
		n.fixed = fixed
		if not fixed then
			free[#free + 1] = { n.id, 1 }; idx[n.id * 2 - 1] = #free
			free[#free + 1] = { n.id, 2 }; idx[n.id * 2] = #free
		end
	end
	local D = #free
	if D == 0 then return { ok = false } end
	local loads = {}
	for _, n in ipairs(order) do
		if not n.fixed and opts.loadAt and opts.loadAt(n.x, n.y) then loads[#loads + 1] = n end
	end
	if #loads == 0 then return { ok = false } end

	local f, sg = {}, {}
	for i = 1, #mem do f[i], sg[i] = 0, 1 end
	local off = {}
	for case = 1, #loads do
		for i = 1, #mem do off[i] = false end
		local forces
		for _ = 1, 6 do
			local K = {}
			for i = 1, D do local r = {}; for j = 1, D do r[j] = 0 end; K[i] = r end
			for i, m in ipairs(mem) do
				if not off[i] then
					local k = 1 / m.L
					local c, s = m.cx, m.cy
					local blocks = { { c * c, c * s }, { c * s, s * s } }
					local ids = { m.a * 2 - 1, m.a * 2, m.b * 2 - 1, m.b * 2 }
					local sgn = { 1, 1, -1, -1 }
					local dirv = { c, s, c, s }
					for p = 1, 4 do
						local ip = idx[ids[p]]
						if ip then
							for q = 1, 4 do
								local iq = idx[ids[q]]
								if iq then K[ip][iq] = K[ip][iq] + k * dirv[p] * dirv[q] * sgn[p] * sgn[q] end
							end
						end
					end
				end
			end
			for i = 1, D do K[i][i] = K[i][i] + 1e-7 end -- tiny stabiliser: a dangling node (zero force) must not make the whole system singular
			local P = {}
			for i = 1, D do P[i] = 0 end
			local ld = loads[case]
			P[idx[ld.id * 2]] = -1
			local u = solve(K, P, D)
			if not u then return { ok = false, mechanism = true } end
			forces = {}
			local again = false
			for i, m in ipairs(mem) do
				local ua = (idx[m.a * 2 - 1] and u[idx[m.a * 2 - 1]] or 0) * m.cx + (idx[m.a * 2] and u[idx[m.a * 2]] or 0) * m.cy
				local ub = (idx[m.b * 2 - 1] and u[idx[m.b * 2 - 1]] or 0) * m.cx + (idx[m.b * 2] and u[idx[m.b * 2]] or 0) * m.cy
				local F = off[i] and 0 or (ub - ua) / m.L -- positive = tension
				forces[i] = F
				if m.mat == "cable" and not off[i] and F < -1e-9 then off[i] = true; again = true end
			end
			if not again then break end
		end
		for i = 1, #mem do
			local a = math.abs(forces[i])
			if a > f[i] then f[i] = a; sg[i] = forces[i] >= 0 and 1 or -1 end
		end
	end
	return { ok = true, f = f, sign = sg, members = #mem, nodes = N }
end

-- capacity per material and force direction, in "vehicle weights" (calibrated from recorded rounds; see tools/fit_capacity.py)
Truss.cap = {
	wood = { t = 1.0, c = 0.6 },
	steel = { t = 3.0, c = 2.5 },
	cable = { t = 2.0, c = 0 },
	road = { t = 1.5, c = 1.2 },
}

-- load factor the bridge can take before its most stressed member reaches capacity (bigger = stronger); nil when it is a mechanism
function Truss.strength(beams, opts, cap)
	cap = cap or Truss.cap
	local r = Truss.analyze(beams, opts)
	if not r.ok then return nil, r end
	local lam, worst = math.huge, nil
	for i, b in ipairs(beams) do
		local c = cap[b[5]]
		local k = c and (r.sign[i] > 0 and c.t or c.c) or 0
		local fi = r.f[i]
		if fi > 1e-9 then
			local v = k / fi
			if v < lam then lam, worst = v, i end
		end
	end
	return lam, r, worst
end

return Truss
