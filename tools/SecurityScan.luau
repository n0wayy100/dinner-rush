--[[
	Dinner Rush - Security Scan          REPORT ONLY. DELETES NOTHING.

	HOW TO RUN
	  1. Open the place in Studio. STOP any playtest - this must run in EDIT
	     MODE. Script.Source is not readable while the game is running.
	  2. View > Command Bar.
	  3. Paste this entire file into the command bar and press Enter.
	  4. Read the output. Nothing is changed; every decision is yours.

	Run it on BOTH places (Lobby and MainGame) - they are separate files.

	WHY IT ONLY REPORTS
	  Auto-deleting would eventually delete something real, and a scanner you
	  stop trusting is a scanner you stop running. It tells you what and where;
	  you decide.

	WHAT IT LOOKS FOR
	  * Known backdoor primitives: require(<assetId>), loadstring, getfenv
	  * Obfuscation: bytecode markers, string.char chains, base64-ish blobs
	  * Network + insertion: HttpService, InsertService, MarketplaceService
	  * This project's known IOCs: getSignal, getArchetype, checkChild,
	    Pose.Value, the Credits:@rewq tag, and the named suspect nodes
	  * Structural smells: scripts hidden under Decals/Textures/Meshes,
	    disabled scripts, remotes in odd places
	  * Every script living OUTSIDE the four Rojo-managed folders - in this
	    project those are the ones nobody's git history can vouch for

	NOT version-controlled INTO the place: tools/ is not mapped by either
	project file, so Rojo never syncs this in.
]]

local CollectionService = game:GetService("CollectionService")

----------------------------------------------------------------
-- WHAT COUNTS AS "OURS"
--
-- Anything Rojo manages came from the repo and is in git history. Anything
-- else was placed by hand in Studio - that is the whole attack surface.
----------------------------------------------------------------

local MANAGED = {
	"ReplicatedStorage.Shared",
	"ServerScriptService.Server",
	"ServerStorage.Shared",
	"StarterPlayer.StarterPlayerScripts.Client",
}

----------------------------------------------------------------
-- PATTERNS
----------------------------------------------------------------

local CRITICAL = {
	{ "require%s*%(%s*%d",        "require(<assetId>) - loads code off the Roblox catalogue" },
	{ "loadstring",               "loadstring - runs text as code" },
	{ "getfenv",                  "getfenv - environment tampering" },
	{ "setfenv",                  "setfenv - environment tampering" },
	{ "getSignal",                "getSignal - known IOC for this place" },
	{ "getArchetype",             "getArchetype - known IOC for this place" },
	{ "checkChild",               "checkChild - known IOC for this place" },
	{ "rewq",                     "rewq - known IOC for this place" },
}

local HIGH = {
	{ "PostAsync",                "HttpService:PostAsync - sends data out" },
	{ "RequestAsync",             "HttpService:RequestAsync - sends data out" },
	{ "InsertService",            "InsertService - inserts assets at runtime" },
	{ "GetObjects",               "GetObjects - inserts assets at runtime" },
	{ "HttpGet",                  "HttpGet - exploit-side HTTP" },
	{ "\27",                      "raw bytecode marker in source" },
	{ "GetProductInfo",           "MarketplaceService:GetProductInfo - sometimes a payload fetch" },
}

local MEDIUM = {
	{ "Pose%.Value",              "Pose.Value - known IOC for this place" },
	{ "string%.char%s*%(",        "string.char( - common obfuscation" },
	{ "\\%d%d%d",                 "decimal escapes - common obfuscation" },
	{ "HttpService",              "HttpService referenced" },
	{ "BindToClose",              "BindToClose - worth a glance in an unexpected script" },
}

--// Scripts hiding under these read as decoration, not code
local ODD_PARENTS = {
	Decal = true, Texture = true, SpecialMesh = true, MeshPart = true,
	Sound = true, ParticleEmitter = true, Beam = true, SurfaceAppearance = true,
}

--// Nodes called out by name in earlier sessions
local NAMED_SUSPECTS = {
	"PoseTexture", "LightConfig", "DishRack", "Electrical Box", "WaterStation",
}

----------------------------------------------------------------
-- COLLECTION
----------------------------------------------------------------

local findings = {}   --// severity -> list of lines
local counts = { CRITICAL = 0, HIGH = 0, MEDIUM = 0, INFO = 0 }

local function add(severity, text)
	findings[severity] = findings[severity] or {}
	table.insert(findings[severity], text)
	counts[severity] = (counts[severity] or 0) + 1
end

local function pathOf(instance)
	local ok, full = pcall(function()
		return instance:GetFullName()
	end)
	return ok and full or "<unreadable path>"
end

local function isManaged(path)
	for _, prefix in ipairs(MANAGED) do
		if string.find(path, prefix, 1, true) == 1 then
			return true
		end
	end
	return false
end

--// Cheap base64-blob heuristic: a long unbroken run of base64 alphabet
local function looksEncoded(source)
	for run in string.gmatch(source, "[A-Za-z0-9+/=]+") do
		if #run > 200 then
			return #run
		end
	end
	return nil
end

local function longestLine(source)
	local longest = 0
	for line in string.gmatch(source, "[^\n]+") do
		if #line > longest then
			longest = #line
		end
	end
	return longest
end

----------------------------------------------------------------
-- SCAN
----------------------------------------------------------------

local scanned, unreadable = 0, 0
local outsideManaged = {}

local function scanScript(instance)
	local path = pathOf(instance)

	local ok, source = pcall(function()
		return instance.Source
	end)

	if not ok or type(source) ~= "string" then
		unreadable += 1
		add("HIGH", ("SOURCE UNREADABLE  %s  (%s)  <- run in EDIT MODE, not a playtest")
			:format(path, instance.ClassName))
		return
	end

	scanned += 1

	local function sweep(list, severity)
		for _, entry in ipairs(list) do
			if string.find(source, entry[1]) then
				add(severity, ("%s\n     %s\n     %s"):format(path, entry[2], instance.ClassName))
			end
		end
	end

	sweep(CRITICAL, "CRITICAL")
	sweep(HIGH, "HIGH")
	sweep(MEDIUM, "MEDIUM")

	local blob = looksEncoded(source)
	if blob then
		add("HIGH", ("%s\n     %d-char unbroken blob - likely encoded payload"):format(path, blob))
	end

	local longest = longestLine(source)
	if longest > 500 then
		add("MEDIUM", ("%s\n     longest line is %d chars - minified or obfuscated"):format(path, longest))
	end

	if instance:IsA("BaseScript") and instance.Disabled then
		add("MEDIUM", ("%s\n     script is DISABLED - backdoors ship dormant"):format(path))
	end

	local parent = instance.Parent
	if parent and ODD_PARENTS[parent.ClassName] then
		add("HIGH", ("%s\n     parented to a %s - code hiding inside decoration")
			:format(path, parent.ClassName))
	end

	if not isManaged(path) then
		table.insert(outsideManaged, ("%s  (%s)"):format(path, instance.ClassName))
	end
end

--// Services worth walking. game:GetDescendants() would also work but is
--// slower and drags in a lot of engine noise.
local TARGETS = {
	"Workspace", "ServerScriptService", "ServerStorage", "ReplicatedStorage",
	"ReplicatedFirst", "StarterGui", "StarterPack", "StarterPlayer",
	"Lighting", "SoundService", "Chat", "TextChatService", "Teams", "Players",
}

print("")
print("================================================================")
print("  DINNER RUSH SECURITY SCAN - report only, nothing is changed")
print("  place: " .. tostring(game.PlaceId) .. "   " .. os.date("%Y-%m-%d %H:%M"))
print("================================================================")

for _, serviceName in ipairs(TARGETS) do
	local ok, service = pcall(function()
		return game:GetService(serviceName)
	end)
	if ok and service then
		for _, descendant in ipairs(service:GetDescendants()) do
			if descendant:IsA("LuaSourceContainer") then
				scanScript(descendant)
			elseif descendant:IsA("RemoteEvent") or descendant:IsA("RemoteFunction") then
				local path = pathOf(descendant)
				if not string.find(path, "ReplicatedStorage", 1, true) then
					add("MEDIUM", ("%s\n     %s outside ReplicatedStorage")
						:format(path, descendant.ClassName))
				end
			end

			for _, suspect in ipairs(NAMED_SUSPECTS) do
				if string.find(descendant.Name, suspect, 1, true) then
					add("INFO", ("named suspect: %s  (%s)"):format(pathOf(descendant), descendant.ClassName))
					break
				end
			end
		end
	end
end

----------------------------------------------------------------
-- TAGS
----------------------------------------------------------------

for _, tag in ipairs(CollectionService:GetAllTags()) do
	local lower = string.lower(tag)
	if string.find(lower, "rewq", 1, true) or string.find(lower, "credit", 1, true) then
		add("CRITICAL", ("TAG '%s' is present - known IOC"):format(tag))
		for _, tagged in ipairs(CollectionService:GetTagged(tag)) do
			add("CRITICAL", ("     tagged: %s"):format(pathOf(tagged)))
		end
	end
end

----------------------------------------------------------------
-- REPORT
----------------------------------------------------------------

local function section(severity, header)
	local list = findings[severity]
	if not list or #list == 0 then
		print(("  [%s] none"):format(severity))
		return
	end
	print("")
	print("  ---- " .. header .. " (" .. #list .. ") ----")
	for _, line in ipairs(list) do
		print("   * " .. line)
	end
end

print("")
print(("  scripts read: %d    unreadable: %d"):format(scanned, unreadable))

section("CRITICAL", "CRITICAL - treat as compromised until proven otherwise")
section("HIGH", "HIGH - explain each one or remove it")
section("MEDIUM", "MEDIUM - probably fine, look anyway")

print("")
print(("  ---- SCRIPTS OUTSIDE ROJO-MANAGED FOLDERS (%d) ----"):format(#outsideManaged))
print("  Everything Rojo manages is in git. These are not.")
print("  Anything here you do not recognise is the thing to look at first.")
for _, line in ipairs(outsideManaged) do
	print("   ? " .. line)
end

section("INFO", "NAMED SUSPECTS from earlier sessions")

print("")
print("================================================================")
print(("  CRITICAL %d   HIGH %d   MEDIUM %d"):format(
	counts.CRITICAL or 0, counts.HIGH or 0, counts.MEDIUM or 0))
if (counts.CRITICAL or 0) == 0 and (counts.HIGH or 0) == 0 then
	print("  No critical or high findings. Still read the OUTSIDE list.")
else
	print("  Findings above. Nothing was deleted - every call is yours.")
end
print("================================================================")
print("")
