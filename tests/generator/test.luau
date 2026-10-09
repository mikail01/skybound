local Gen = MOD_Generator
local Config = MOD_Config
local M = Config.Movement
local V, G = M.JUMP_VELOCITY, M.GRAVITY
local apex = V * V / (2 * G)
local fails, checks, worstDy, worstSlack = 0, 0, 0, math.huge
local hazardFails = 0
for seed = 1, 300 do
	local prev = nil
	for index = 0, 220 do
		local chunk = Gen.chunk(seed * 7919, index, seed % 2 == 0)
		for i = 1, chunk.spine do
			local b = chunk.platforms[i]
			if prev then
				checks += 1
				local dy = b.y - prev.y
				if dy > worstDy then worstDy = dy end
				local V2 = if prev.kind == "bounce" then V * M.BOUNCE_PAD_MULTIPLIER else V
				local ok = dy < V2 * V2 / (2 * G) - 0.5
				if ok then
					local t = (V2 + math.sqrt(V2 * V2 - 2 * G * math.max(dy, 0))) / G
					local reach = if t > 0.125 then M.MOVE_SPEED * (t - 0.0625) else 0
					local need = math.max(0, math.abs(b.x - prev.x) - prev.width / 2 - b.width / 2 + prev.moveRange + b.moveRange)
					local slack = reach * 0.9 - need
					if slack < worstSlack then worstSlack = slack end
					ok = slack >= 0
				end
				if not ok then
					fails += 1
					if fails <= 8 then
						print(string.format("FAIL seed=%d chunk=%d dy=%.1f dx=%.1f wA=%.1f wB=%.1f", seed, index, dy, b.x - prev.x, prev.width, b.width))
					end
				end
			end
			prev = b
		end
		for _, h in chunk.hazards do
			if h.kind == "spike" then
				for i = 1, chunk.spine do
					local p = chunk.platforms[i]
					local dx = math.max(0, math.abs(h.x - p.x) - p.width / 2) - h.moveRange
					local dy = math.abs(h.y - p.y)
					if dx < h.radius + 4 and dy < h.radius + 4 then
						hazardFails += 1
					end
				end
			end
		end
	end
end
print(string.format("jump apex %.1f studs | %d gaps checked | %d unreachable | worst dy %.1f | worst horizontal slack %.1f | spikes touching route %d", apex, checks, fails, worstDy, worstSlack, hazardFails))
