-- Bridge Builder UI (same look as Scrdsx Solutions)
local UIS = game:GetService("UserInputService")
local UI = __import("ui")
local Bot = __import("bridgebot")

local TITLE, SUBTITLE = "Bridge Builder", "Last Bridge Standing"
local env = (getgenv and getgenv()) or _G
if env.__BridgeBuilder then pcall(env.__BridgeBuilder) end
if env.BridgeBot and env.BridgeBot.Destroy then pcall(env.BridgeBot.Destroy) end -- the old v0.1 window

local win = UI.new({ Title = TITLE, Subtitle = SUBTITLE })
local alive = true

-- Builder -----------------------------------------------------------------------------------------------------------
local tB = win:Tab("Builder", { Section = "Bridge", Icon = 1 })
local lPhase = tB:Label({ Name = "Phase", Value = "-" })
local lLayout = tB:Label({ Name = "Layout / twist", Value = "-" })
local lBudget = tB:Label({ Name = "Budget", Value = "-" })
local lLast = tB:Label({ Name = "Last build", Value = Bot.Last })
local lShape = tB:Label({ Name = "Shape", Value = "-" })
local lSpent = tB:Label({ Name = "Spent / beams", Value = "-" })
local lRound = tB:Label({ Name = "Last round", Value = "-" })

tB:Button({ Name = "Build the best bridge now", Callback = function()
	task.spawn(function()
		Bot.BuildNow()
		win:Notify(Bot.Last, 5)
	end)
end })
tB:Button({ Name = "Auto-tune: build, test drive, reinforce what breaks", Callback = function()
	task.spawn(function() Bot.AutoTune(2); win:Notify(Bot.Last, 5) end)
end })
tB:Button({ Name = "Test drive (2 free per round)", Callback = function() Bot.TestDrive(); win:Notify("Test drive requested") end })
tB:Button({ Name = "Ready", Callback = function() Bot.Ready(true) end })

local mAuto = tB:Module({ Name = "Auto build every round", Default = false, Callback = function(on)
	Bot.Auto = on
	win:Notify(on and "Auto build on: builds 2.5 s into every build phase" or "Auto build off")
end })
mAuto:Toggle({ Name = "Press Ready after a good build", Default = false, Callback = function(v) Bot.AutoReady = v end })
mAuto:Toggle({ Name = "Spend the leftover on steel", Default = true, Callback = function(v) Bot.Upgrade = v end })
mAuto:Slider({ Name = "Spend at most", Min = 20, Max = 100, Step = 5, Default = 100, Suffix = " % of the budget", Callback = function(v) Bot.SpendPct = v end })

local mShape = tB:Module({ Name = "Custom shape", Default = false, Callback = function(on) Bot.Custom = on; win:Notify(on and "Custom shape on (0 = let the planner choose)" or "Custom shape off") end })
mShape:Slider({ Name = "Truss depth (cells)", Min = 0, Max = 5, Step = 0.5, Default = 0, Callback = function(v) Bot.ForceDepth = v end })
mShape:Slider({ Name = "Panel width (cells)", Min = 0, Max = 4, Step = 0.5, Default = 0, Callback = function(v) Bot.ForcePanel = v end })

-- Info ---------------------------------------------------------------------------------------------------------------
local tI = win:Tab("Info", { Section = "Bridge", Icon = 3 })
tI:Label({ Name = "Prices per stud", Value = "road 200, wood 100, steel 250, cable 150" })
tI:Label({ Name = "Reach (cells)", Value = "road 4, wood 5, steel 3, cable 8" })
tI:Label({ Name = "Limits", Value = "150 beams, 75 s to build" })
tI:Button({ Name = "Copy the log (send me this)", Callback = function()
	local n = Bot.CopyLog()
	win:Notify(("Copied %d log lines. The file is BridgeBuilder_log.txt in the workspace"):format(n), 5)
end })

-- Settings -----------------------------------------------------------------------------------------------------------
local tS = win:Tab("Settings", { Section = "Script", Icon = 9 })
tS:Slider({ Name = "UI scale", Min = 0.7, Max = 1.4, Step = 0.05, Default = 1, Callback = function(v) win:SetScale(v) end })
tS:Label({ Name = "Toggle UI", Value = "RightShift" })
tS:Label({ Name = "Version", Value = tostring(env.BridgeVersion or "?") })
local function unload()
	alive = false
	Bot.Changed = nil
	Bot.Destroy()
	win:Destroy()
	env.__BridgeBuilder = nil
end
tS:Button({ Name = "Unload", Callback = unload })
env.__BridgeBuilder = unload

-- auto reload when a new version is pushed
task.spawn(function()
	local mine = env.BridgeVersion
	task.wait(8)
	while alive and env.BridgeFetchVersion do
		local ok, latest = pcall(env.BridgeFetchVersion)
		-- reload once per new version: if the loader still hands back the old one (stale cache) it tells you instead of looping
		if ok and latest ~= "" and mine and latest ~= mine and env.BridgeTried ~= latest then
			env.BridgeTried = latest
			win:Notify("New version " .. latest .. " found - reloading", 4)
			task.wait(1.5)
			local reload = env.BridgeReload
			unload()
			if reload then task.spawn(reload) end
			return
		end
		task.wait(45)
	end
end)

table.insert(win.conns, UIS.InputBegan:Connect(function(i)
	if i.KeyCode == Enum.KeyCode.RightShift then win:Toggle() end
end))

local function refresh()
	if not alive then return end
	lPhase:Set(Bot.Phase)
	lLayout:Set(Bot.Layout .. " / " .. Bot.Twist)
	lBudget:Set(tostring(Bot.Budget))
	lLast:Set(Bot.Last)
	lShape:Set(Bot.Shape)
	lSpent:Set(("%d / %d beams"):format(Bot.Spent, Bot.Beams))
	lRound:Set(Bot.LastRound or "-")
end
Bot.Changed = refresh

task.spawn(function()
	Bot.Start()
	refresh()
	while alive do
		task.wait(1)
		pcall(function()
			local RS = game:GetService("ReplicatedStorage")
			local st = RS:FindFirstChild("RoundState")
			if st then
				Bot.Phase = tostring(st:GetAttribute("Phase"))
				Bot.Layout, Bot.Twist = tostring(st:GetAttribute("Layout")), tostring(st:GetAttribute("Twist"))
				Bot.Budget = st:GetAttribute("Budget") or Bot.Budget
			end
		end)
		refresh()
	end
end)
win:Notify("Bridge Builder loaded. RightShift hides the menu", 5)
