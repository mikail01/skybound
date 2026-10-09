--!strict
-- Single place that owns every RemoteEvent/RemoteFunction name. The server
-- creates them on first access; clients wait for them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.Events = table.freeze({
	-- server -> client
	"ProfileSync",
	"RunStarted",
	"RunResult",
	"Milestone",
	"Notify",
	"RewardPopup",
	"WorldEntered",
	"AchievementUnlocked",
	-- client -> server
	"CollectPickup",
	"EndRun",
	"ShieldUsed",
	"RunReady",
})

Remotes.Functions = table.freeze({
	"ClaimDaily",
	"ClaimPlaytime",
	"BuyUpgrade",
	"UsePotion",
	"BuyPotion",
	"EquipGear",
	"BuyGear",
	"Retry",
	"ReturnToHub",
	"SkipTutorial",
	"ClaimQuest",
	"EquipTitle",
})

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "Remotes"

local function getFolder(): Folder
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if existing and existing:IsA("Folder") then
			return existing
		end
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		return folder
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

function Remotes.event(name: string): RemoteEvent
	assert(table.find(Remotes.Events, name), "Unknown remote event " .. name)
	local folder = getFolder()
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteEvent") then
			return existing
		end
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name) :: RemoteEvent
end

function Remotes.func(name: string): RemoteFunction
	assert(table.find(Remotes.Functions, name), "Unknown remote function " .. name)
	local folder = getFolder()
	if IS_SERVER then
		local existing = folder:FindFirstChild(name)
		if existing and existing:IsA("RemoteFunction") then
			return existing
		end
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
		return remote
	end
	return folder:WaitForChild(name) :: RemoteFunction
end

-- Server only: create everything up front so clients never wait forever.
function Remotes.createAll()
	assert(IS_SERVER, "createAll is server-only")
	for _, name in Remotes.Events do
		Remotes.event(name)
	end
	for _, name in Remotes.Functions do
		Remotes.func(name)
	end
end

return Remotes
