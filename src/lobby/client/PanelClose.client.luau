--[[
	Dinner Rush - PanelClose (lobby)
	StarterPlayer.StarterPlayerScripts.Client.PanelClose  (LocalScript)

	Owns opening AND closing for the lobby pop-up panels, so the two halves
	cannot disagree about whether "hidden" means ScreenGui.Enabled or
	MainPanel.Visible.

	DELETE the old OpenHandler LocalScripts under HudDock_UI.ButtonDock once
	this is running, or both will fight over the same panels.

	Add an entry to PANELS and it is handled - no other changes.

	Expected shape (both current panels already match):
	  <ScreenGui>
	    MainPanel        <- the frame that gets hidden
	      CloseButton    <- any GuiButton, at any depth
--]]

local Players = game:GetService("Players")

--// gui       = ScreenGui name in PlayerGui
--// openBy    = name of the dock button that opens it (optional)
--// MatchMaking_UI is deliberately absent - PartySettings owns that one.
local PANELS = {
	{ gui = "Codes_UI",    openBy = "OpenCodesButton" },
	{ gui = "FreeGift_UI", openBy = "OpenGiftButton" },
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--// Hidden means both: Enabled off and the panel not visible. Setting both
--// keeps this consistent no matter which one anything else looks at.
local function setOpen(screenGui, panel, open)
	screenGui.Enabled = open
	panel.Visible = open

	--// A hidden ancestor between MainPanel and the ScreenGui would keep it
	--// invisible even with both of the above set
	if open then
		local node = panel.Parent
		while node and node ~= screenGui do
			if node:IsA("GuiObject") then
				node.Visible = true
			end
			node = node.Parent
		end
	end
end

local function setup(entry)
	local screenGui = playerGui:FindFirstChild(entry.gui, true)
	if not screenGui then
		return false
	end

	if not screenGui:IsA("ScreenGui") then
		warn(("[PanelClose] %s is a %s, not a ScreenGui - skipped")
			:format(screenGui:GetFullName(), screenGui.ClassName))
		return true --// found something, stop retrying
	end

	--// Respawning would otherwise clone a fresh copy and strand these connections
	screenGui.ResetOnSpawn = false

	local panel = screenGui:FindFirstChild("MainPanel", true)
	if not panel then
		warn(("[PanelClose] %s has no MainPanel - skipped"):format(entry.gui))
		return true
	end

	local closeButton = screenGui:FindFirstChild("CloseButton", true)
	if closeButton and closeButton:IsA("GuiButton") then
		closeButton.Activated:Connect(function()
			setOpen(screenGui, panel, false)
			print(("[PanelClose] closed %s"):format(entry.gui))
		end)
	else
		warn(("[PanelClose] %s has no CloseButton (must be a TextButton or ImageButton)")
			:format(entry.gui))
	end

	--// Opening: the dock button lives in a different ScreenGui, so search
	--// the whole PlayerGui for it
	if entry.openBy then
		local openButton = playerGui:FindFirstChild(entry.openBy, true)
		if openButton and openButton:IsA("GuiButton") then
			openButton.Activated:Connect(function()
				--// toggle, so the dock button also closes an open panel
				local nowOpen = not screenGui.Enabled
				setOpen(screenGui, panel, nowOpen)
				print(("[PanelClose] %s %s"):format(entry.gui, nowOpen and "opened" or "closed"))

				--// If a second handler is still bound to this button it will
				--// toggle straight back, and the panel never appears. Check a
				--// moment later and name the problem rather than leaving it
				--// looking like the open simply did nothing.
				if nowOpen then
					task.delay(0.15, function()
						if not screenGui.Enabled or not panel.Visible then
							warn(("[PanelClose] %s was re-hidden right after opening - the old OpenHandler script is probably still under ButtonDock. Delete it.")
								:format(entry.gui))
						end
					end)
				end
			end)
			print(("[PanelClose] %s opens from %s"):format(entry.gui, openButton:GetFullName()))
		else
			warn(("[PanelClose] no GuiButton named '%s' found - %s cannot be opened")
				:format(entry.openBy, entry.gui))
		end
	end

	--// Pop-ups start closed
	setOpen(screenGui, panel, false)
	print(("[PanelClose] wired %s"):format(screenGui:GetFullName()))
	return true
end

--// StarterGui clones into PlayerGui around the first spawn, so poll briefly
--// rather than yielding forever on one that has not arrived yet
task.spawn(function()
	local pending = table.clone(PANELS)
	local waited = 0

	while #pending > 0 and waited < 20 do
		for index = #pending, 1, -1 do
			if setup(pending[index]) then
				table.remove(pending, index)
			end
		end

		if #pending == 0 then break end
		task.wait(0.25)
		waited += 0.25
	end

	for _, entry in ipairs(pending) do
		warn(("[PanelClose] never found a ScreenGui named '%s' in PlayerGui"):format(entry.gui))
	end
end)
