--[[
	Dinner Rush - PromptInput
	StarterPlayer.StarterPlayerScripts.Client.PromptInput  (LocalScript)

	Stops ProximityPrompts from stealing the camera in shift lock.

	ClickablePrompt defaults to true, which puts a clickable button under the
	cursor. Roblox's camera ignores mouse movement that begins over a GUI
	element, so walking up to a prompt in shift lock freezes the camera until
	you look away.

	Turning it off fixes that but removes the tap target touch players need,
	so the decision is made per client: keyboard/mouse gets key-only prompts,
	touch keeps them clickable. ProximityPrompt properties changed locally stay
	local, so this never affects anyone else.
--]]

local UserInputService = game:GetService("UserInputService")

--// Touch devices keep the tap target; everyone else uses the key only
local CLICKABLE = UserInputService.TouchEnabled

local function apply(instance)
	if instance:IsA("ProximityPrompt") then
		instance.ClickablePrompt = CLICKABLE
	end
end

--// Prompts are created on the server and replicate in, so they arrive as
--// Workspace descendants - both the ones already here and any added later
for _, descendant in ipairs(workspace:GetDescendants()) do
	apply(descendant)
end

workspace.DescendantAdded:Connect(apply)

print(("[PromptInput] ClickablePrompt = %s (touch: %s)")
	:format(tostring(CLICKABLE), tostring(UserInputService.TouchEnabled)))
