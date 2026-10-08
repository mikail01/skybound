--!strict
-- Live numbers from the active run, written by the Run controller every
-- frame and read by the HUD. Display only; the server keeps the real tally.

local RunState = {
	active = false,
	height = 0,
	best = 0,
	coins = 0,
	gems = 0,
	fuel = 0,
	maxFuel = 0,
	hasJetpack = false,
	boosting = false,
	shield = 0,
	worldName = "",
}

return RunState
