--// Temporary diagnostic dump - delete this file once the lobby works.
--// Prints the structure the queue scripts depend on, plus every script in
--// the place, so scripts added directly in Studio show up here too.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local function line(text)
	print("[DIAG] " .. text)
end

local function dump(instance, depth, maxDepth)
	depth = depth or 0
	maxDepth = maxDepth or 4

	for _, child in ipairs(instance:GetChildren()) do
		line(("%s%s (%s)"):format(string.rep("    ", depth + 1), child.Name, child.ClassName))
		if depth + 1 < maxDepth then
			dump(child, depth + 1, maxDepth)
		end
	end
end

line("================ DIAGNOSTICS ================")

--// 1. What the server script requires at startup
line("--- ReplicatedStorage (top level) ---")
dump(ReplicatedStorage, 0, 1)

local modules = ReplicatedStorage:FindFirstChild("Modules")
line("ReplicatedStorage.Modules exists: " .. tostring(modules ~= nil))
if modules then
	dump(modules, 0, 1)
end

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
line("ReplicatedStorage.Remotes exists: " .. tostring(remotes ~= nil))
if remotes then
	for _, child in ipairs(remotes:GetChildren()) do
		line(("    %s (%s)"):format(child.Name, child.ClassName))
	end
end

--// 2. The zone hierarchy
local zone = workspace:FindFirstChild("Teleport_zone", true)
line("--- Teleport_zone found: " .. tostring(zone ~= nil) .. " ---")
if zone then
	line("full path: " .. zone:GetFullName())
	dump(zone, 0, 3)
end

--// 3. Every script in the place, so Studio-only additions are visible.
--//    Disabled is the quiet one - a disabled script looks perfectly normal
--//    in the Explorer but never runs.
line("--- All scripts ---")
for _, container in ipairs({ ServerScriptService, ReplicatedStorage, StarterGui, StarterPlayer, workspace }) do
	for _, descendant in ipairs(container:GetDescendants()) do
		if descendant:IsA("LuaSourceContainer") then
			local disabled = ""
			if descendant:IsA("BaseScript") and descendant.Disabled then
				disabled = "   <-- DISABLED"
			end
			line(("    %s (%s)%s"):format(descendant:GetFullName(), descendant.ClassName, disabled))
		end
	end
end

line("================ END DIAGNOSTICS ================")
