--!strict
-- skybound client entry point. Two-phase bootstrap: init() all modules in
-- Controllers/, then start() each of them. Each module is isolated: one that fails
-- to load or start is reported by name and cannot stop the others.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Build = require(Shared:WaitForChild("Build"))

local folder = script:WaitForChild("Controllers")
local loaded: { [string]: any } = {}
for _, child in folder:GetChildren() do
	if child:IsA("ModuleScript") then
		local ok, result = pcall(require, child)
		if ok then
			loaded[child.Name] = result
		else
			warn(
				"[Skybound] failed to load client module " .. child.Name .. ": " .. tostring(result)
			)
		end
	end
end

for name, module in loaded do
	if typeof(module.init) == "function" then
		local ok, err = pcall(module.init)
		if not ok then
			warn("[Skybound] init failed in " .. name .. ": " .. tostring(err))
		end
	end
end

for name, module in loaded do
	if typeof(module.start) == "function" then
		task.spawn(function()
			local ok, err = pcall(module.start)
			if not ok then
				warn("[Skybound] start failed in " .. name .. ": " .. tostring(err))
			end
		end)
	end
end

print(string.format("[Skybound] client started (build %s - %s)", Build.ID, Build.NAME))
