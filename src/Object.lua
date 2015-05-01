local Class_MT = {}
local Class = {}

local function method_lookup_on(self, key)
	local the_class = self
	while the_class do
		if the_class[1][key] then
			return the_class[1][key]
		else
			the_class = the_class.__parent
		end
	end
end

local function classify(class)
	local new_metatable = { __metatable = class }
	function new_metatable:__index(key)
		local rawvalue = rawget(self, key)
		if rawvalue == nil then
			return method_lookup_on(class, key)
		else return rawvalue end
	end
	function new_metatable:__tostring(key)
		local stringifier = method_lookup_on(class, "tostring")
		if stringifier then return stringifier() else
			return "instance of: " .. tostring(class)
		end
	end
	class.__mt = new_metatable
	return setmetatable(class, Class_MT)
end

function Class_MT:__index(key)
	return Class[key] or self[1][key]
end

function Class_MT:__newindex(key, value)
	if value == nil then
		self[1][key] = nil
	else
		assert(type(key) == "string", "method name must be a string")
		assert(type(value) == "function", "method must be a function")
		assert(not Class[key], "attempt to overwrite a class method")
		self[1][key] = value
	end
end

function Class_MT:__tostring()
	if self.__parent then
		for k, v in pairs(_G) do
			if v == self then return k end
		end
		return "<unnamed class>"
	else
		return "Object" -- only Object have no ancenstor
	end
end

function Class:extend() 
	return classify{ __parent = self, {} }
end

function Class:new(...)
	local instance = setmetatable({ }, self.__mt)
	local initializator = method_lookup_on(self, "initialize")
	if initializator then initializator(instance, ...) end
	return instance
end

function Class:check(item)
	local the_class = getmetatable(item)
	assert(getmetatable(the_class) == Class_MT, "bad instance")
	while the_class do
		if the_class == self then
			return item
		else
			the_class = the_class.__parent
		end
	end
	error(string.format("expected %s, got %s",
		tostring(self), tostring(getmetatable(item))))
end

function Class:undef(key, key2, ...)
	assert(type(key) == "string", "method name must be a string")
	self[1][key] = nil
	if key2 then return self:class_undef(key2, ...) end
end

local Object = classify{ {} }

function Object:super(method_name, ...)
	local parentclass = assert(getmetatable(self).__parent)
	local supermethod = method_lookup_on(parentclass, method_name)
	return assert(supermethod, "no such supermethod")(...)
end

return Object
