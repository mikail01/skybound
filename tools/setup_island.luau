-- One-time setup for the imported hub island. Run it in Roblox Studio after
-- importing FloatingIslandMap.glb with the 3D Importer:
--   View > Command Bar, paste this whole file, press Enter.
--
-- It finds the imported model (selected, or anywhere in Workspace /
-- ServerStorage), names it FloatingIslandMap, anchors it, turns off
-- collision on decoration, gives everything you walk on precise collision
-- (only Studio can set that, scripts at runtime can't) and moves it to
-- ServerStorage. On Play the hub clones it in, scales and places it, and
-- puts the stalls, portal and spawn on it. Save the place afterwards.

local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")

local NAME = "FloatingIslandMap"
local DECOR = {
	"Plants_",
	"Island_Paths",
	"Water_",
	"Props_Butterflies",
	"Props_Mushrooms",
	"Props_Squirrel",
	"Props_SteppingStones",
	"Portal_Vortex",
	"Portal_Label",
	"Portal_Gems",
	"VFX_",
}

local function isDecor(name)
	if string.sub(name, -8) == "_Outline" then
		return true
	end
	for _, prefix in DECOR do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

-- The importer may prefix the file name or rename meshes, so match loosely.
local function isIsland(model)
	return string.find(model.Name, NAME, 1, true) ~= nil or model:FindFirstChild("Island_Grass", true) ~= nil
end

local function findMap()
	for _, selected in Selection:Get() do
		local model = if selected:IsA("Model") then selected else selected:FindFirstAncestorOfClass("Model")
		while model and not isIsland(model) do
			model = model:FindFirstAncestorOfClass("Model")
		end
		if model then
			-- Walk up to the outermost model that still belongs to the import.
			local parent = model.Parent
			while parent and parent:IsA("Model") and parent.Parent ~= game do
				model = parent
				parent = model.Parent
			end
			return model
		end
	end
	for _, container in { workspace, ServerStorage } do
		for _, child in container:GetChildren() do
			if child:IsA("Model") and isIsland(child) then
				return child
			end
		end
	end
	return nil
end

local map = findMap()
if not map then
	warn("[Skybound] No imported island found. Import FloatingIslandMap.glb first (Home > Import 3D).")
	return
end

local History = game:GetService("ChangeHistoryService")
local okRecording, recording = pcall(function()
	return History:TryBeginRecording("Setup hub island")
end)
local solid, decor = 0, 0
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		d.Anchored = true
		if isDecor(d.Name) then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			decor += 1
		else
			if d:IsA("MeshPart") then
				d.CollisionFidelity = Enum.CollisionFidelity.PreciseConvexDecomposition
			end
			solid += 1
		end
	end
end
map.Name = NAME
map.Parent = ServerStorage
if okRecording and recording then
	History:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
Selection:Set({ map })
print(
	string.format(
		"[Skybound] %s ready in ServerStorage: %d solid meshes (precise collision), %d decoration. Press Play, then save the place.",
		NAME,
		solid,
		decor
	)
)
