--!strict
-- Latest server snapshot of the local player's profile, plus helpers for
-- values that tick locally between syncs (potion timers, playtime, daily
-- countdown). The client never edits this; it only displays it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local Bus = require(script.Parent.Bus)

local State = {}

State.snapshot = nil :: Types.Snapshot?
local receivedAt = os.clock()
local serverOffset = 0

function State.profile(): Types.Profile?
	local snap = State.snapshot
	return if snap then snap.profile else nil
end

-- Server unix time estimated from the last sync.
function State.now(): number
	return os.time() + serverOffset
end

function State.effectRemaining(id: string): number
	local profile = State.profile()
	if not profile then
		return 0
	end
	local value = profile.effects[id] or 0
	if id == "shield" then
		return value -- charges, not seconds
	end
	return math.max(0, value - (os.clock() - receivedAt))
end

function State.sessionElapsed(): number
	local snap = State.snapshot
	if not snap then
		return 0
	end
	return State.now() - snap.sessionStart
end

function State.init()
	Remotes.event("ProfileSync").OnClientEvent:Connect(function(snap: Types.Snapshot)
		State.snapshot = snap
		receivedAt = os.clock()
		serverOffset = snap.serverTime - os.time()
		Bus.fire("ProfileChanged", snap)
	end)
end

State.init()

return State
