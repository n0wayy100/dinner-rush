--[[
	Dinner Rush - ToolMountClient
	StarterPlayer.StarterPlayerScripts.Client.ToolMountClient  (LocalScript)

	A tool mount whose tool can be PUT BACK (the vacuum): while the tool is
	out, the server turns the mount's prompt into "Put back" and stamps the
	holder's UserId on it as an OnlyFor attribute. This hides that prompt on
	everyone else's screen, so only the person holding the vacuum sees it.

	Only reacts to prompts that carry OnlyFor - every other prompt in the
	game is left exactly as the server set it.
--]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer

local function watch(prompt)
	if not prompt:IsA("ProximityPrompt") then return end
	local function apply()
		local onlyFor = prompt:GetAttribute("OnlyFor")
		prompt.Enabled = (onlyFor == nil) or (onlyFor == player.UserId)
	end
	prompt:GetAttributeChangedSignal("OnlyFor"):Connect(apply)
	if prompt:GetAttribute("OnlyFor") ~= nil then
		apply()
	end
end

for _, descendant in ipairs(workspace:GetDescendants()) do
	watch(descendant)
end
workspace.DescendantAdded:Connect(watch)
