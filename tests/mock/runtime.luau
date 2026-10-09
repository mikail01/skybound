-- Minimal Roblox engine mock for headless testing of Skybound.
-- Validates every property read/write and method call against the real
-- Roblox API definitions, runs server and client in separate contexts with
-- separate require caches, links remotes, and integrates simple physics.

local API = APIDB
local GENV = getfenv(1)
local R = {}
R.errors = {}
R.warnings = {}
R.log = {}
R.now = 0
local BASE_TIME = 1760000000

-- typeof -----------------------------------------------------------------------
local rawtypeof = typeof
local function mtType(v)
	local mt = getmetatable(v)
	if type(mt) == "table" and rawget(mt, "__type") then
		return rawget(mt, "__type")
	end
	return nil
end
function typeof(v)
	if type(v) == "table" then
		local t = mtType(v)
		if t then
			return t
		end
	end
	return rawtypeof(v)
end

-- Contexts ---------------------------------------------------------------------
local contextOf = setmetatable({}, { __mode = "k" })
R.mainContext = { name = "test", cache = {} }
local function currentContext()
	local co = coroutine.running()
	return contextOf[co] or R.mainContext
end
R.currentContext = currentContext

-- Scheduler ------------------------------------------------------------------------
local sleeping = {} -- { co, wake, args }
local deferred = {}
local function report(err, co)
	local msg = tostring(err)
	table.insert(R.errors, msg)
	print("  !! ERROR [" .. (contextOf[co] and contextOf[co].name or "?") .. "] " .. msg)
	if co then
		print("     " .. string.gsub(debug.traceback(co), "\n", "\n     "))
	end
end
local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		report(err, co)
	end
end
local function spawnIn(ctx, fn, ...)
	local co = coroutine.create(fn)
	contextOf[co] = ctx
	resume(co, ...)
	return co
end
R.spawnIn = spawnIn

local taskLib = {}
function taskLib.spawn(fn, ...)
	if type(fn) == "thread" then
		resume(fn, ...)
		return fn
	end
	return spawnIn(currentContext(), fn, ...)
end
function taskLib.defer(fn, ...)
	local co = coroutine.create(fn)
	contextOf[co] = currentContext()
	table.insert(deferred, { co = co, args = table.pack(...) })
	return co
end
function taskLib.delay(t, fn, ...)
	local co = coroutine.create(fn)
	contextOf[co] = currentContext()
	table.insert(sleeping, { co = co, wake = R.now + (t or 0), args = table.pack(...) })
	return co
end
function taskLib.wait(t)
	local co = coroutine.running()
	assert(coroutine.isyieldable(), "task.wait called from non-yieldable thread")
	local start = R.now
	table.insert(sleeping, { co = co, wake = R.now + math.max(t or 0, 1 / 60), args = table.pack() })
	coroutine.yield()
	return R.now - start
end
function taskLib.cancel(co)
	for i = #sleeping, 1, -1 do
		if sleeping[i].co == co then
			table.remove(sleeping, i)
		end
	end
end
task = taskLib

local function runScheduler()
	local i = 1
	local ready = {}
	for idx = #sleeping, 1, -1 do
		local s = sleeping[idx]
		if s.wake <= R.now + 1e-9 then
			table.remove(sleeping, idx)
			table.insert(ready, 1, s)
		end
	end
	for _, s in ready do
		if coroutine.status(s.co) == "suspended" then
			resume(s.co, table.unpack(s.args, 1, s.args.n))
		end
	end
	local d = deferred
	deferred = {}
	for _, s in d do
		resume(s.co, table.unpack(s.args, 1, s.args.n))
	end
	local _ = i
end

local realOs = os
local realTime = realOs.time
os = setmetatable({
	clock = function()
		return R.now
	end,
	time = function(t)
		if t then
			return realTime(t)
		end
		return BASE_TIME + math.floor(R.now)
	end,
}, { __index = realOs })
function warn(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local msg = table.concat(parts, " ")
	table.insert(R.warnings, msg)
	print("  [warn] " .. msg)
end
local realPrint = print
function print(...)
	realPrint(...)
end

-- Signals --------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"
local Connection = {}
Connection.__index = Connection
Connection.__type = "RBXScriptConnection"
function Connection:Disconnect()
	self.Connected = false
	local list = self.signal.handlers
	for i, h in list do
		if h == self then
			table.remove(list, i)
			break
		end
	end
end
function R.newSignal(name)
	return setmetatable({ handlers = {}, name = name, waiting = {} }, Signal)
end
function Signal:Connect(fn)
	assert(type(fn) == "function", "Attempt to connect failed: Passed value is not a function")
	local c = setmetatable({ fn = fn, ctx = currentContext(), Connected = true, signal = self }, Connection)
	table.insert(self.handlers, c)
	-- Remote events queue until the first listener connects (like Roblox).
	if self.queue and #self.queue > 0 then
		local q = self.queue
		self.queue = {}
		for _, args in q do
			spawnIn(c.ctx, fn, table.unpack(args, 1, args.n))
		end
	end
	return c
end
function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end
function Signal:Wait()
	local co = coroutine.running()
	table.insert(self.waiting, co)
	return coroutine.yield()
end
function Signal:Fire(...)
	if self.queue and #self.handlers == 0 then
		table.insert(self.queue, table.pack(...))
		return
	end
	for _, c in table.clone(self.handlers) do
		if c.Connected then
			spawnIn(c.ctx, c.fn, ...)
		end
	end
	local w = self.waiting
	self.waiting = {}
	for _, co in w do
		resume(co, ...)
	end
end

-- Datatypes -------------------------------------------------------------------------
local function mk(typeName, ops)
	ops.__type = typeName
	return ops
end

-- Vector3
local V3 = {}
local V3mt
local function v3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3mt)
end
V3mt = mk("Vector3", {
	__index = function(v, k)
		if k == "Magnitude" then
			return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		elseif k == "Unit" then
			local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
			if m == 0 then
				return v3(0 / 0, 0 / 0, 0 / 0)
			end
			return v3(v.X / m, v.Y / m, v.Z / m)
		elseif k == "x" then
			return v.X
		elseif k == "y" then
			return v.Y
		elseif k == "z" then
			return v.Z
		end
		local m = V3[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of Vector3", 2)
	end,
	__add = function(a, b)
		return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
	end,
	__sub = function(a, b)
		return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			return v3(b.X * a, b.Y * a, b.Z * a)
		elseif type(b) == "number" then
			return v3(a.X * b, a.Y * b, a.Z * b)
		end
		return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
	end,
	__div = function(a, b)
		if type(b) == "number" then
			return v3(a.X / b, a.Y / b, a.Z / b)
		end
		return v3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
	end,
	__unm = function(a)
		return v3(-a.X, -a.Y, -a.Z)
	end,
	__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y and a.Z == b.Z
	end,
	__tostring = function(a)
		return string.format("%.2f, %.2f, %.2f", a.X, a.Y, a.Z)
	end,
})
function V3.Lerp(a, b, t)
	return a + (b - a) * t
end
function V3.Dot(a, b)
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V3.Cross(a, b)
	return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
Vector3 = { new = v3, zero = v3(0, 0, 0), one = v3(1, 1, 1), xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1) }

-- Vector2
local V2mt
local function v2(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, V2mt)
end
V2mt = mk("Vector2", {
	__index = function(v, k)
		if k == "Magnitude" then
			return math.sqrt(v.X * v.X + v.Y * v.Y)
		end
		error(tostring(k) .. " is not a valid member of Vector2", 2)
	end,
	__add = function(a, b)
		return v2(a.X + b.X, a.Y + b.Y)
	end,
	__sub = function(a, b)
		return v2(a.X - b.X, a.Y - b.Y)
	end,
	__mul = function(a, b)
		if type(b) == "number" then
			return v2(a.X * b, a.Y * b)
		end
		return v2(a.X * b.X, a.Y * b.Y)
	end,
	__div = function(a, b)
		return v2(a.X / b, a.Y / b)
	end,
	__eq = function(a, b)
		return a.X == b.X and a.Y == b.Y
	end,
})
Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1) }

-- CFrame (rotation matrix rows)
local CFmt
local CF = {}
local function cf(px, py, pz, r)
	return setmetatable({ p = v3(px, py, pz), r = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, CFmt)
end
local function matmul(a, b)
	local o = {}
	for i = 0, 2 do
		for j = 0, 2 do
			local s = 0
			for k = 0, 2 do
				s += a[i * 3 + k + 1] * b[k * 3 + j + 1]
			end
			o[i * 3 + j + 1] = s
		end
	end
	return o
end
local function rotv(r, v)
	return v3(
		r[1] * v.X + r[2] * v.Y + r[3] * v.Z,
		r[4] * v.X + r[5] * v.Y + r[6] * v.Z,
		r[7] * v.X + r[8] * v.Y + r[9] * v.Z
	)
end
CFmt = mk("CFrame", {
	__index = function(c, k)
		if k == "Position" or k == "p" then
			return rawget(c, "p")
		elseif k == "X" then
			return c.p.X
		elseif k == "Y" then
			return c.p.Y
		elseif k == "Z" then
			return c.p.Z
		elseif k == "LookVector" then
			return v3(-c.r[3], -c.r[6], -c.r[9])
		elseif k == "RightVector" then
			return v3(c.r[1], c.r[4], c.r[7])
		elseif k == "UpVector" then
			return v3(c.r[2], c.r[5], c.r[8])
		elseif k == "Rotation" then
			return cf(0, 0, 0, c.r)
		end
		local m = CF[k]
		if m then
			return m
		end
		error(tostring(k) .. " is not a valid member of CFrame", 2)
	end,
	__mul = function(a, b)
		if getmetatable(b) == V3mt then
			return a.p + rotv(a.r, b)
		end
		local p = a.p + rotv(a.r, b.p)
		return cf(p.X, p.Y, p.Z, matmul(a.r, b.r))
	end,
	__add = function(a, b)
		local p = a.p + b
		return cf(p.X, p.Y, p.Z, a.r)
	end,
	__sub = function(a, b)
		local p = a.p - b
		return cf(p.X, p.Y, p.Z, a.r)
	end,
	__eq = function(a, b)
		return a.p == b.p
	end,
})
function CF.Inverse(c)
	local r = c.r
	local t = { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
	local p = rotv(t, -c.p)
	return cf(p.X, p.Y, p.Z, t)
end
function CF.Lerp(a, b, t)
	local p = a.p:Lerp(b.p, t)
	return cf(p.X, p.Y, p.Z, if t < 0.5 then a.r else b.r)
end
function CF.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function CF.PointToWorldSpace(a, v)
	return a * v
end
local function angles(rx, ry, rz)
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	local Rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local Rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return cf(0, 0, 0, matmul(matmul(Rx, Ry), Rz))
end
local function lookAt(at, target, up)
	up = up or v3(0, 1, 0)
	local f = (target - at)
	if f.Magnitude < 1e-9 then
		return cf(at.X, at.Y, at.Z)
	end
	f = f.Unit
	local right = f:Cross(up)
	if right.Magnitude < 1e-6 then
		right = v3(1, 0, 0)
	end
	right = right.Unit
	local u = right:Cross(f)
	local back = -f
	return cf(at.X, at.Y, at.Z, { right.X, u.X, back.X, right.Y, u.Y, back.Y, right.Z, u.Z, back.Z })
end
CFrame = {
	new = function(a, b, c, ...)
		if a == nil then
			return cf(0, 0, 0)
		elseif type(a) == "number" then
			local extra = { ... }
			if #extra == 9 then
				return cf(a, b, c, extra)
			end
			return cf(a, b, c)
		elseif b ~= nil then
			return lookAt(a, b)
		end
		return cf(a.X, a.Y, a.Z)
	end,
	Angles = angles,
	fromEulerAnglesXYZ = angles,
	fromOrientation = function(x, y, z)
		return angles(0, y, 0) * angles(x, 0, 0) * angles(0, 0, z)
	end,
	lookAt = lookAt,
	identity = cf(0, 0, 0),
}

-- Color3
local C3mt
local function c3(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3mt)
end
C3mt = mk("Color3", {
	__index = function(c, k)
		if k == "Lerp" then
			return function(a, b, t)
				return c3(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
			end
		elseif k == "ToHSV" then
			return function()
				return 0, 0, 0
			end
		end
		error(tostring(k) .. " is not a valid member of Color3", 2)
	end,
	__eq = function(a, b)
		return a.R == b.R and a.G == b.G and a.B == b.B
	end,
})
Color3 = {
	new = c3,
	fromRGB = function(r, g, b)
		return c3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
	fromHSV = function(h, s, v)
		return c3(v, v * (1 - s), v * (1 - s * h))
	end,
}

-- UDim / UDim2
local UDmt = mk("UDim", { __index = function(_, k)
	error(tostring(k) .. " is not a valid member of UDim", 2)
end })
local function udim(s, o)
	return setmetatable({ Scale = s or 0, Offset = o or 0 }, UDmt)
end
UDim = { new = udim }
local UD2mt
local function udim2(xs, xo, ys, yo)
	return setmetatable({ X = udim(xs, xo), Y = udim(ys, yo) }, UD2mt)
end
UD2mt = mk("UDim2", {
	__index = function(u, k)
		if k == "Width" then
			return u.X
		elseif k == "Height" then
			return u.Y
		elseif k == "Lerp" then
			return function(a)
				return a
			end
		end
		error(tostring(k) .. " is not a valid member of UDim2", 2)
	end,
	__add = function(a, b)
		return udim2(a.X.Scale + b.X.Scale, a.X.Offset + b.X.Offset, a.Y.Scale + b.Y.Scale, a.Y.Offset + b.Y.Offset)
	end,
})
UDim2 = {
	new = function(a, b, c, d)
		if type(a) == "table" then
			return udim2(a.Scale, a.Offset, b.Scale, b.Offset)
		end
		return udim2(a, b, c, d)
	end,
	fromScale = function(x, y)
		return udim2(x, 0, y, 0)
	end,
	fromOffset = function(x, y)
		return udim2(0, x, 0, y)
	end,
}

local function opaque(typeName)
	local mt = mk(typeName, { __index = function(_, k)
		error(tostring(k) .. " is not a valid member of " .. typeName, 2)
	end })
	return function(...)
		return setmetatable({ args = table.pack(...) }, mt)
	end
end
ColorSequence = { new = opaque("ColorSequence") }
ColorSequenceKeypoint = { new = opaque("ColorSequenceKeypoint") }
NumberSequence = { new = opaque("NumberSequence") }
NumberSequenceKeypoint = { new = opaque("NumberSequenceKeypoint") }
NumberRange = { new = opaque("NumberRange") }
Rect = { new = opaque("Rect") }
local tweenInfoNew = opaque("TweenInfo")
TweenInfo = {
	new = function(time, ...)
		local t = tweenInfoNew(time, ...)
		rawset(t, "time", time or 1)
		return t
	end,
}

-- Enum: permissive but stable identities.
local enumCache = {}
local EnumItemMt = mk("EnumItem", {
	__index = function(e, k)
		if k == "Value" then
			return 0
		end
		error(tostring(k) .. " is not a valid member of EnumItem", 2)
	end,
	__tostring = function(e)
		return "Enum." .. e.EnumType .. "." .. e.Name
	end,
})
Enum = setmetatable({}, {
	__index = function(_, enumName)
		enumCache[enumName] = enumCache[enumName]
			or setmetatable({}, {
				__index = function(t, itemName)
					local item = setmetatable({ Name = itemName, EnumType = enumName }, EnumItemMt)
					rawset(t, itemName, item)
					return item
				end,
			})
		return enumCache[enumName]
	end,
})

-- Random
local RandomMt = { __type = "Random" }
RandomMt.__index = RandomMt
function RandomMt:NextNumber(a, b)
	self.state = (self.state * 48271) % 2147483647
	local v = self.state / 2147483647
	if a then
		return a + (b - a) * v
	end
	return v
end
function RandomMt:NextInteger(a, b)
	return a + math.floor(self:NextNumber() * (b - a + 1))
end
Random = {
	new = function(seed)
		return setmetatable({ state = ((seed or 12345) % 2147483646) + 1 }, RandomMt)
	end,
}

-- Instances --------------------------------------------------------------------------
local classes = API.classes
local function classChain(name)
	local chain = {}
	local c = name
	while c do
		table.insert(chain, c)
		local def = classes[c]
		c = def and def.base
	end
	return chain
end
local function findProp(className, prop)
	for _, c in classChain(className) do
		local def = classes[c]
		if def and def.props[prop] then
			return def.props[prop]
		end
	end
	return nil
end
local function hasMethod(className, m)
	for _, c in classChain(className) do
		local def = classes[c]
		if def and def.methods[m] then
			return true
		end
	end
	return false
end
local function isA(className, target)
	for _, c in classChain(className) do
		if c == target then
			return true
		end
	end
	return false
end

local function defaultFor(t, className, prop)
	if prop == "Name" then
		return className
	end
	if t == "number" then
		return 0
	elseif t == "boolean" then
		return false
	elseif t == "string" or t == "ContentId" then
		return ""
	elseif t == "Vector3" then
		return Vector3.zero
	elseif t == "Vector2" then
		return Vector2.zero
	elseif t == "CFrame" then
		return CFrame.new()
	elseif t == "Color3" then
		return Color3.new(1, 1, 1)
	elseif t == "UDim2" then
		return UDim2.new(0, 0, 0, 0)
	elseif t == "UDim" then
		return UDim.new(0, 0)
	end
	return nil
end

local CLASS_DEFAULTS = {
	BasePart = { Size = Vector3.new(4, 1, 2), Anchored = false, CanCollide = true, CanTouch = true, CanQuery = true, Transparency = 0 },
	Humanoid = { HipHeight = 2, Health = 100, MaxHealth = 100, WalkSpeed = 16, AutoRotate = true },
	Camera = { ViewportSize = Vector2.new(1600, 900), FieldOfView = 70 },
	UIScale = { Scale = 1 },
	GuiObject = { Visible = true, BackgroundTransparency = 0 },
	LayerCollector = { Enabled = true },
	ParticleEmitter = { Enabled = true },
	Workspace = { Gravity = 196.2 },
}

local Inst = {}
local InstMt = { __type = "Instance" }
local instanceMethods = {}
R.instanceMethods = instanceMethods

local function newInstance(className, isService)
	local self = setmetatable({}, InstMt)
	rawset(self, "__class", className)
	rawset(self, "__p", {})
	rawset(self, "__children", {})
	rawset(self, "__attr", {})
	rawset(self, "__signals", {})
	rawset(self, "__changed", {})
	local p = rawget(self, "__p")
	for _, c in classChain(className) do
		local d = CLASS_DEFAULTS[c]
		if d then
			for k, v in d do
				if p[k] == nil then
					p[k] = v
				end
			end
		end
	end
	p.Name = className
	if isA(className, "BasePart") then
		p.CFrame = CFrame.new()
		p.AssemblyLinearVelocity = Vector3.zero
		p.Color = Color3.fromRGB(163, 162, 165)
	end
	if className == "Humanoid" then
		p.RigType = Enum.HumanoidRigType.R15
	end
	return self
end

local function fullName(inst)
	local parts = {}
	local cur = inst
	while cur do
		table.insert(parts, 1, rawget(cur, "__p").Name)
		cur = rawget(cur, "__p").Parent
	end
	return table.concat(parts, ".")
end
R.fullName = fullName

local function signalFor(self, name)
	local sigs = rawget(self, "__signals")
	if not sigs[name] then
		sigs[name] = R.newSignal(name)
		if name == "OnClientEvent" or name == "OnServerEvent" then
			sigs[name].queue = {}
		end
	end
	return sigs[name]
end

local function setParent(self, parent)
	local p = rawget(self, "__p")
	local old = p.Parent
	if old == parent then
		return
	end
	if rawget(self, "__destroyed") and parent ~= nil then
		error("The Parent property of " .. p.Name .. " is locked, current parent: NULL, new parent " .. rawget(parent, "__p").Name, 3)
	end
	if old then
		local list = rawget(old, "__children")
		for i, c in list do
			if c == self then
				table.remove(list, i)
				break
			end
		end
		signalFor(old, "ChildRemoved"):Fire(self)
	end
	p.Parent = parent
	if parent then
		table.insert(rawget(parent, "__children"), self)
		signalFor(parent, "ChildAdded"):Fire(self)
		-- DescendantAdded up the chain
		local cur = parent
		while cur do
			signalFor(cur, "DescendantAdded"):Fire(self)
			cur = rawget(cur, "__p").Parent
		end
	end
	signalFor(self, "AncestryChanged"):Fire(self, parent)
end

InstMt.__index = function(self, k)
	local className = rawget(self, "__class")
	if rawget(self, "__destroyedHard") then
		-- still readable in Roblox
	end
	local impl = instanceMethods[k]
	if impl and (hasMethod(className, k) or rawget(impl, "always")) then
		return impl.fn
	end
	local t = findProp(className, k)
	if t then
		if string.sub(t, 1, 15) == "RBXScriptSignal" then
			return signalFor(self, k)
		end
		local p = rawget(self, "__p")
		if k == "Position" and isA(className, "BasePart") then
			return p.CFrame.Position
		end
		if k == "Orientation" and isA(className, "BasePart") then
			return Vector3.zero
		end
		if k == "AssemblyMass" then
			return 10
		end
		if k == "LocalPlayer" and className == "Players" then
			return currentContext().player
		end
		if k == "WorldPivot" and className == "Model" and p.WorldPivot == nil then
			return CFrame.new()
		end
		local v = p[k]
		if v == nil then
			v = defaultFor(t, className, k)
		end
		return v
	end
	if hasMethod(className, k) then
		return function()
			table.insert(R.log, "stub method " .. className .. ":" .. k)
			return nil
		end
	end
	for _, c in rawget(self, "__children") do
		if rawget(c, "__p").Name == k then
			return c
		end
	end
	error(tostring(k) .. " is not a valid member of " .. className .. ' "' .. fullName(self) .. '"', 2)
end

local VALUE_TYPES = {
	Vector3 = true, Vector2 = true, CFrame = true, Color3 = true, UDim2 = true, UDim = true,
	NumberRange = true, NumberSequence = true, ColorSequence = true, Rect = true, TweenInfo = true,
}
local function checkType(className, k, declared, v)
	local t = string.gsub(declared, "%?$", "")
	local optional = string.sub(declared, -1) == "?"
	if v == nil then
		if optional or classes[t] then
			return
		end
		if t == "number" or t == "boolean" or t == "string" or VALUE_TYPES[t] or string.sub(t, 1, 4) == "Enum" then
			error("Unable to assign property " .. k .. ". " .. t .. " expected, got nil", 3)
		end
		return
	end
	local actual = typeof(v)
	if t == "number" then
		if actual ~= "number" then
			error("Unable to assign property " .. k .. ". number expected, got " .. actual, 3)
		end
	elseif t == "boolean" then
		if actual ~= "boolean" then
			error("Unable to assign property " .. k .. ". bool expected, got " .. actual, 3)
		end
	elseif t == "string" or t == "ContentId" then
		if actual ~= "string" and actual ~= "number" then
			error("Unable to assign property " .. k .. ". string expected, got " .. actual, 3)
		end
	elseif VALUE_TYPES[t] then
		if actual ~= t then
			error("Unable to assign property " .. k .. ". " .. t .. " expected, got " .. actual, 3)
		end
	elseif string.sub(t, 1, 4) == "Enum" and #t > 4 then
		local enumName = string.sub(t, 5)
		if actual == "EnumItem" then
			if v.EnumType ~= enumName then
				error("Unable to assign property " .. k .. ". Enum." .. enumName .. " expected, got Enum." .. v.EnumType, 3)
			end
		elseif actual ~= "number" and actual ~= "string" then
			error("Unable to assign property " .. k .. ". EnumItem expected, got " .. actual, 3)
		end
	elseif classes[t] then
		if actual ~= "Instance" or not isA(rawget(v, "__class"), t) then
			error("Unable to assign property " .. k .. ". " .. t .. " expected, got " .. (if actual == "Instance" then rawget(v, "__class") else actual), 3)
		end
	end
end

InstMt.__newindex = function(self, k, v)
	local className = rawget(self, "__class")
	local t = findProp(className, k)
	if not t or string.sub(t, 1, 15) == "RBXScriptSignal" then
		-- callbacks like OnServerInvoke are declared as props in some defs
		if k == "OnServerInvoke" or k == "OnClientInvoke" then
			rawget(self, "__p")[k] = v
			return
		end
		error(tostring(k) .. " is not a valid member of " .. className .. ' "' .. fullName(self) .. '"', 2)
	end
	local p = rawget(self, "__p")
	checkType(className, k, t, v)
	if k == "Parent" then
		if v ~= nil and typeof(v) ~= "Instance" then
			error("Unable to assign property Parent. Object expected, got " .. typeof(v), 2)
		end
		setParent(self, v)
		return
	end
	if k == "Position" and isA(className, "BasePart") then
		p.CFrame = CFrame.new(v) * p.CFrame.Rotation
	elseif k == "Shape" then
		p.Shape = v
	else
		p[k] = v
	end
	local changed = rawget(self, "__changed")[k]
	if changed then
		changed:Fire()
	end
end
InstMt.__tostring = function(self)
	return rawget(self, "__p").Name
end

local function method(name, fn, always)
	instanceMethods[name] = { fn = fn, always = always }
end

method("FindFirstChild", function(self, name, recursive)
	for _, c in rawget(self, "__children") do
		if rawget(c, "__p").Name == name then
			return c
		end
	end
	if recursive then
		for _, c in rawget(self, "__children") do
			local f = c:FindFirstChild(name, true)
			if f then
				return f
			end
		end
	end
	return nil
end)
method("WaitForChild", function(self, name, timeout)
	local start = R.now
	local warned = false
	while true do
		local c = self:FindFirstChild(name)
		if c then
			return c
		end
		if timeout and R.now - start >= timeout then
			return nil
		end
		if not warned and R.now - start > 5 then
			warned = true
			warn("Infinite yield possible on '" .. fullName(self) .. ":WaitForChild(\"" .. name .. "\")'")
		end
		task.wait()
	end
end)
method("GetChildren", function(self)
	return table.clone(rawget(self, "__children"))
end)
method("GetDescendants", function(self)
	local out = {}
	local function walk(i)
		for _, c in rawget(i, "__children") do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end)
method("IsA", function(self, c)
	return isA(rawget(self, "__class"), c)
end)
method("FindFirstChildOfClass", function(self, c)
	for _, ch in rawget(self, "__children") do
		if rawget(ch, "__class") == c then
			return ch
		end
	end
	return nil
end)
method("FindFirstChildWhichIsA", function(self, c, recursive)
	for _, ch in rawget(self, "__children") do
		if ch:IsA(c) then
			return ch
		end
	end
	if recursive then
		for _, ch in rawget(self, "__children") do
			local f = ch:FindFirstChildWhichIsA(c, true)
			if f then
				return f
			end
		end
	end
	return nil
end)
method("FindFirstAncestorOfClass", function(self, c)
	local cur = rawget(self, "__p").Parent
	while cur do
		if rawget(cur, "__class") == c then
			return cur
		end
		cur = rawget(cur, "__p").Parent
	end
	return nil
end)
method("FindFirstAncestorWhichIsA", function(self, c)
	local cur = rawget(self, "__p").Parent
	while cur do
		if cur:IsA(c) then
			return cur
		end
		cur = rawget(cur, "__p").Parent
	end
	return nil
end)
method("FindFirstAncestor", function(self, n)
	local cur = rawget(self, "__p").Parent
	while cur do
		if rawget(cur, "__p").Name == n then
			return cur
		end
		cur = rawget(cur, "__p").Parent
	end
	return nil
end)
method("IsDescendantOf", function(self, a)
	local cur = rawget(self, "__p").Parent
	while cur do
		if cur == a then
			return true
		end
		cur = rawget(cur, "__p").Parent
	end
	return false
end)
method("IsAncestorOf", function(self, d)
	return d:IsDescendantOf(self)
end)
method("Destroy", function(self)
	for _, c in table.clone(rawget(self, "__children")) do
		c:Destroy()
	end
	setParent(self, nil)
	rawset(self, "__destroyed", true)
	signalFor(self, "Destroying"):Fire()
end)
method("ClearAllChildren", function(self)
	for _, c in table.clone(rawget(self, "__children")) do
		c:Destroy()
	end
end)
method("Clone", function(self)
	local copy = newInstance(rawget(self, "__class"))
	for k, v in rawget(self, "__p") do
		if k ~= "Parent" then
			rawget(copy, "__p")[k] = v
		end
	end
	for k, v in rawget(self, "__attr") do
		rawget(copy, "__attr")[k] = v
	end
	for _, c in rawget(self, "__children") do
		c:Clone().Parent = copy
	end
	return copy
end)
method("SetAttribute", function(self, k, v)
	rawget(self, "__attr")[k] = v
	signalFor(self, "AttributeChanged"):Fire(k)
end)
method("GetAttribute", function(self, k)
	return rawget(self, "__attr")[k]
end)
method("GetAttributes", function(self)
	return table.clone(rawget(self, "__attr"))
end)
method("GetAttributeChangedSignal", function(self, k)
	local sig = R.newSignal("attr")
	signalFor(self, "AttributeChanged"):Connect(function(name)
		if name == k then
			sig:Fire()
		end
	end)
	return sig
end)
method("GetPropertyChangedSignal", function(self, k)
	if not findProp(rawget(self, "__class"), k) then
		error(k .. " is not a valid property name.", 2)
	end
	local ch = rawget(self, "__changed")
	ch[k] = ch[k] or R.newSignal("changed:" .. k)
	return ch[k]
end)
method("GetFullName", function(self)
	return fullName(self)
end)
method("AddTag", function() end)
method("HasTag", function()
	return false
end)

local function descendantsParts(self)
	local out = {}
	for _, d in self:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(out, d)
		end
	end
	return out
end
method("GetPivot", function(self)
	if self:IsA("BasePart") then
		return rawget(self, "__p").CFrame
	end
	local p = rawget(self, "__p")
	if p.PrimaryPart then
		return rawget(p.PrimaryPart, "__p").CFrame
	end
	if p.WorldPivot then
		return p.WorldPivot
	end
	local parts = descendantsParts(self)
	if parts[1] then
		return rawget(parts[1], "__p").CFrame
	end
	return CFrame.new()
end)
method("PivotTo", function(self, target)
	if self:IsA("BasePart") then
		rawget(self, "__p").CFrame = target
		return
	end
	local current = self:GetPivot()
	local delta = target * current:Inverse()
	for _, part in descendantsParts(self) do
		local pp = rawget(part, "__p")
		pp.CFrame = delta * pp.CFrame
	end
	local p = rawget(self, "__p")
	if p.WorldPivot then
		p.WorldPivot = delta * p.WorldPivot
	end
end)
method("GetBoundingBox", function(self)
	return self:GetPivot(), Vector3.new(4, 5, 2)
end)
method("Emit", function() end)
method("Play", function(self)
	if self:IsA("Sound") then
		task.delay(0.5, function()
			signalFor(self, "Ended"):Fire()
		end)
	end
end)
method("Stop", function() end)
method("ChangeState", function() end)
method("SetStateEnabled", function() end)
method("GetState", function()
	return Enum.HumanoidStateType.Running
end)
method("TakeDamage", function(self, d)
	local p = rawget(self, "__p")
	p.Health = math.max(0, p.Health - d)
end)

-- Instance global
Instance = {
	new = function(className, parent)
		if not API.creatable[className] then
			error('Unable to create an Instance of type "' .. tostring(className) .. '"', 2)
		end
		local i = newInstance(className)
		if parent then
			i.Parent = parent
		end
		return i
	end,
}
R.newInstance = newInstance

-- DataModel + services ------------------------------------------------------------------
local gameInst = newInstance("DataModel")
rawget(gameInst, "__p").Name = "Game"
rawget(gameInst, "__p").JobId = ""
local services = {}
local function service(name)
	if not services[name] then
		local s = newInstance(name, true)
		rawget(s, "__p").Name = name
		setParent(s, gameInst)
		services[name] = s
	end
	return services[name]
end
R.service = service
method("GetService", function(_, name)
	if not API.services[name] then
		error("'" .. tostring(name) .. "' is not a valid Service name", 2)
	end
	return service(name)
end)
method("BindToClose", function(_, fn)
	R.bindToClose = R.bindToClose or {}
	table.insert(R.bindToClose, fn)
end)
game = gameInst
workspace = service("Workspace")
local camera = newInstance("Camera")
camera.Parent = workspace
rawget(workspace, "__p").CurrentCamera = camera

-- RunService
local runService = service("RunService")
method("IsServer", function()
	return currentContext().server == true
end)
method("IsClient", function()
	return currentContext().server ~= true
end)
method("IsStudio", function()
	return true
end)
method("BindToRenderStep", function(_, _, _, fn)
	signalFor(runService, "RenderStepped"):Connect(fn)
end)
R.runService = runService

-- Players
local players = service("Players")
method("GetPlayers", function(self)
	local out = {}
	for _, c in rawget(self, "__children") do
		if c:IsA("Player") then
			table.insert(out, c)
		end
	end
	return out
end)
method("GetPlayerFromCharacter", function(self, character)
	for _, pl in self:GetPlayers() do
		if rawget(pl, "__p").Character == character then
			return pl
		end
	end
	return nil
end)
method("GetNameFromUserIdAsync", function(_, id)
	return "Player" .. tostring(id)
end)
method("Kick", function() end)
method("RequestStreamAroundAsync", function() end)

-- DataStores: in-memory
local stores = {}
local function makeStore(name, ordered)
	local data = {}
	local s = { __data = data }
	function s:UpdateAsync(key, fn)
		local new = fn(data[key], nil)
		if new ~= nil then
			data[key] = new
		end
		return new
	end
	function s:GetAsync(key)
		return data[key]
	end
	function s:SetAsync(key, v)
		data[key] = v
	end
	if ordered then
		function s:GetSortedAsync(asc, n)
			local list = {}
			for k, v in data do
				table.insert(list, { key = k, value = v })
			end
			table.sort(list, function(a, b)
				return a.value > b.value
			end)
			return {
				GetCurrentPage = function()
					return list
				end,
			}
		end
	end
	return s
end
method("GetDataStore", function(_, name)
	stores[name] = stores[name] or makeStore(name, false)
	return stores[name]
end)
method("GetOrderedDataStore", function(_, name)
	stores["o:" .. name] = stores["o:" .. name] or makeStore(name, true)
	return stores["o:" .. name]
end)
R.stores = stores

-- TweenService
method("Create", function(_, inst, info, props)
	local tween = {}
	tween.Completed = R.newSignal("Completed")
	function tween:Play()
		for k, v in props do
			inst[k] = v
		end
		task.delay(rawget(info, "time") or 0.1, function()
			tween.Completed:Fire(Enum.PlaybackState.Completed)
		end)
	end
	function tween:Cancel() end
	function tween:Pause() end
	return tween
end)

-- UserInputService
local keysDown = {}
R.keysDown = keysDown
method("IsKeyDown", function(_, key)
	return keysDown[key.Name] == true
end)
method("GetGuiInset", function()
	return Vector2.new(0, 58), Vector2.zero
end)
method("GenerateGUID", function()
	return "GUID-" .. tostring(math.random(1, 1e9))
end)
method("LogOnboardingFunnelStepEvent", function(_, player, step, name)
	table.insert(R.log, "funnel " .. step .. " " .. name)
end)
method("LogCustomEvent", function(_, player, name)
	table.insert(R.log, "event " .. name)
end)

-- Remotes
method("FireServer", function(self, ...)
	local args = table.pack(...)
	local player = currentContext().player
	local serverCtx = R.serverContext
	spawnIn(serverCtx, function()
		signalFor(self, "OnServerEvent"):Fire(player, table.unpack(args, 1, args.n))
	end)
end)
method("FireClient", function(self, player, ...)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "FireClient: player expected")
	signalFor(self, "OnClientEvent"):Fire(...)
end)
method("FireAllClients", function(self, ...)
	signalFor(self, "OnClientEvent"):Fire(...)
end)
method("InvokeServer", function(self, ...)
	local cb = rawget(self, "__p").OnServerInvoke
	if not cb then
		error("InvokeServer: no OnServerInvoke on " .. fullName(self))
	end
	local player = currentContext().player
	local args = table.pack(...)
	-- run in server context, synchronously from the caller's view
	local result
	local done = false
	spawnIn(R.serverContext, function()
		result = table.pack(cb(player, table.unpack(args, 1, args.n)))
		done = true
	end)
	while not done do
		task.wait()
	end
	return table.unpack(result, 1, result.n)
end)

-- require ------------------------------------------------------------------------------
local moduleSources = {}
R.moduleSources = moduleSources
local realRequire = require
function require(target)
	if typeof(target) ~= "Instance" then
		return realRequire(target)
	end
	if not target:IsA("ModuleScript") then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	local ctx = currentContext()
	local cache = ctx.cache
	if cache[target] ~= nil then
		if cache[target] == "__loading" then
			error("Recursive require detected: " .. fullName(target), 2)
		end
		return cache[target]
	end
	local src = moduleSources[target]
	if not src then
		-- mock-provided module (e.g. PlayerModule)
		local mockFn = rawget(target, "__mock")
		if mockFn then
			cache[target] = mockFn()
			return cache[target]
		end
		error("Module has no source: " .. fullName(target), 2)
	end
	cache[target] = "__loading"
	local fn, err = loadstring(src.code, "=" .. src.path)
	if not fn then
		error("Syntax error in " .. src.path .. ": " .. tostring(err))
	end
	setfenv(fn, setmetatable({ script = target }, { __index = GENV }))
	local results = table.pack(fn())
	if results.n ~= 1 then
		error("Module code did not return exactly one value: " .. src.path, 2)
	end
	cache[target] = results[1]
	return results[1]
end

function R.runScript(ctx, scriptInst)
	local src = moduleSources[scriptInst]
	local fn, err = loadstring(src.code, "=" .. src.path)
	if not fn then
		error("Syntax error in " .. src.path .. ": " .. tostring(err))
	end
	setfenv(fn, setmetatable({ script = scriptInst }, { __index = GENV }))
	spawnIn(ctx, fn)
end

-- Physics + frame stepping -----------------------------------------------------------------
R.collidables = function()
	local out = {}
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") then
			local p = rawget(d, "__p")
			if p.CanCollide and p.Anchored and p.Transparency < 1 then
				table.insert(out, d)
			elseif p.CanCollide and p.Anchored then
				table.insert(out, d)
			end
		end
	end
	return out
end

local function hasAntiGravity(root)
	for _, c in rawget(root, "__children") do
		if rawget(c, "__class") == "VectorForce" and rawget(c, "__p").Force and rawget(c, "__p").Force.Y > 0 then
			return true
		end
	end
	return false
end

function R.stepPhysics(dt, characters, collidables)
	for _, root in characters do
		local p = rawget(root, "__p")
		if p.Parent and not p.Anchored then
			local v = p.AssemblyLinearVelocity
			if not hasAntiGravity(root) then
				v = v - Vector3.new(0, workspace.Gravity * dt, 0)
			end
			local pos = p.CFrame.Position + v * dt
			-- feet collision with anchored collidable boxes (axis-aligned approximation)
			local feet = pos.Y - 3
			for _, part in collidables do
				local pp = rawget(part, "__p")
				local c, s = pp.CFrame.Position, pp.Size
				if pp.Shape == Enum.PartType.Cylinder then
					s = Vector3.new(s.Y, s.X, s.Z) -- our vertical cylinders are rotated
				end
				local top = c.Y + s.Y / 2
				if math.abs(pos.X - c.X) <= s.X / 2 and math.abs(pos.Z - c.Z) <= s.Z / 2 then
					local prevFeet = p.CFrame.Position.Y - 3
					if prevFeet >= top - 0.2 and feet < top then
						pos = Vector3.new(pos.X, top + 3, pos.Z)
						v = Vector3.new(v.X, 0, v.Z)
					end
				end
			end
			p.AssemblyLinearVelocity = v
			p.CFrame = CFrame.new(pos) * p.CFrame.Rotation
			-- move the rest of the character with the root
			local character = p.Parent
			if character and rawget(character, "__class") == "Model" then
				for _, d in character:GetDescendants() do
					if d ~= root and d:IsA("BasePart") then
						rawget(d, "__p").CFrame = CFrame.new(pos + Vector3.new(0, 2.5, 0))
					end
				end
			end
		end
	end
end

R.jitter = false
local jitterRng = Random.new(7)
local lastDt = 1 / 60
function R.frame(dt, physics)
	-- Real engines hand RenderStepped the *previous* frame's duration, and
	-- frame lengths vary. With jitter on, emulate both.
	local reported = dt
	if R.jitter then
		reported = lastDt
		dt = jitterRng:NextNumber(1 / 90, 1 / 24)
		lastDt = dt
	elseif R.highFps then
		dt = 1 / R.highFps
		reported = dt
	end
	R.now += dt
	runScheduler()
	signalFor(runService, "RenderStepped"):Fire(reported)
	signalFor(runService, "Stepped"):Fire(R.now, dt)
	signalFor(runService, "PreSimulation"):Fire(dt)
	if physics then
		if R.highFps then
			-- Render at R.highFps while physics only advances in fixed 1/60 steps.
			R.physicsAccum = (R.physicsAccum or 0) + dt
			while R.physicsAccum >= 1 / 60 do
				R.physicsAccum -= 1 / 60
				physics(1 / 60)
			end
		else
			physics(dt)
		end
	end
	signalFor(runService, "Heartbeat"):Fire(dt)
	runScheduler()
end
R.signalFor = signalFor
R.setParent = setParent

return R
