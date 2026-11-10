-- Bridge Builder UI (same look as Scrdsx Solutions)
local UIS = game:GetService("UserInputService")
local UI = __import("ui")
local Bot = __import("bridgebot")

local TITLE, SUBTITLE = "Bridge Builder", "Last Bridge Standing"
local env = (getgenv and getgenv()) or _G
if env.__BridgeBuilder then pcall(env.__BridgeBuilder) end

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

tB:Button({ Name = "Build the best bridge now", Callback = function()
	task.spawn(function()
		Bot.BuildNow()
		win:Notify(Bot.Last, 5)
	end)
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

-- Info ---------------------------------------------------------------------------------------------------------------
local tI = win:Tab("Info", { Section = "Bridge", Icon = 3 })
tI:Label({ Name = "Prices per stud", Value = "road 200, wood 100, steel 250, cable 150" })
tI:Label({ Name = "Reach (cells)", Value = "road 4, wood 5, steel 3, cable 8" })
tI:Label({ Name = "Limits", Value = "150 beams, 75 s to build" })
tI:Button({ Name = "Copy the log (send me this)", Callback = function()
	local n = Bot.CopyLog()
	win:Notify(("Copied %d log lines. The file is BridgeScript_log.txt in the workspace"):format(n), 5)
end })

-- Settings -----------------------------------------------------------------------------------------------------------
local tS = win:Tab("Settings", { Section = "Script", Icon = 9 })
tS:Slider({ Name = "UI scale", Min = 0.7, Max = 1.4, Step = 0.05, Default = 1, Callback = function(v) win:SetScale(v) end })
tS:Label({ Name = "Toggle UI", Value = "RightShift" })
local function unload()
	alive = false
	Bot.Changed = nil
	Bot.Destroy()
	win:Destroy()
	env.__BridgeBuilder = nil
end
tS:Button({ Name = "Unload", Callback = unload })
env.__BridgeBuilder = unload

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
