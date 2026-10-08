--!strict
-- Tiny client-side event bus so controllers can talk without requiring
-- each other (e.g. a ProximityPrompt asks the Panels controller to open).

local Bus = {}

local listeners: { [string]: { (...any) -> () } } = {}

function Bus.on(name: string, callback: (...any) -> ()): () -> ()
	local list = listeners[name]
	if not list then
		list = {}
		listeners[name] = list
	end
	table.insert(list, callback)
	return function()
		local current = listeners[name]
		if current then
			local index = table.find(current, callback)
			if index then
				table.remove(current, index)
			end
		end
	end
end

function Bus.fire(name: string, ...: any)
	local list = listeners[name]
	if not list then
		return
	end
	for _, callback in table.clone(list) do
		task.spawn(callback, ...)
	end
end

return Bus
