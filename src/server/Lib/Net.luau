--!strict
-- Server-side remote wiring with per-player rate limiting and error
-- isolation. Handlers never receive calls from players whose data hasn't
-- loaded, and a throwing handler returns a safe failure instead of an error.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Remotes = require(Shared.Remotes)

local Net = {}

local lastCall: { [Player]: { [string]: number } } = {}

local function allowed(player: Player, name: string, cooldown: number): boolean
	if not player:GetAttribute("DataLoaded") then
		return false
	end
	local now = os.clock()
	local perPlayer = lastCall[player]
	if not perPlayer then
		perPlayer = {}
		lastCall[player] = perPlayer
	end
	local last = perPlayer[name]
	if last and now - last < cooldown then
		return false
	end
	perPlayer[name] = now
	return true
end

game:GetService("Players").PlayerRemoving:Connect(function(player)
	lastCall[player] = nil
end)

-- Handler returns a result table sent back to the client.
function Net.onInvoke(name: string, cooldown: number, handler: (Player, ...any) -> any)
	Remotes.func(name).OnServerInvoke = function(player: Player, ...)
		if not allowed(player, name, cooldown) then
			return { ok = false, reason = "Slow down!" }
		end
		local ok, result = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[Net] %s failed for %s: %s", name, player.Name, tostring(result)))
			return { ok = false, reason = "Something went wrong." }
		end
		return result
	end
end

function Net.onEvent(name: string, cooldown: number, handler: (Player, ...any) -> ...any)
	Remotes.event(name).OnServerEvent:Connect(function(player: Player, ...)
		if not allowed(player, name, cooldown) then
			return
		end
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(string.format("[Net] %s failed for %s: %s", name, player.Name, tostring(err)))
		end
	end)
end

function Net.fire(player: Player, name: string, ...: any)
	Remotes.event(name):FireClient(player, ...)
end

return Net
