require "BaseServer"

local md5sum = (require "md5").sum
local coyield, uv = coroutine.yield, HttpMisc.backend

RpcConnection = BaseConnection:extend()

function RpcConnection:PUSH(data)
	assert(self.top <= 0xFF, "stack overflow")
	self.top = self.top + 1
	self.stack[self.top] = data
end

function RpcConnection:PUSHVALUE(at)
	assert(at <= self.top, "stack did not reach that level")
	if at < 0 then at = self.top + at + 1 end
	return self:PUSH(self.stack[at])
end

function RpcConnection:NEWTABLE()
	return self:PUSH{}
end

function RpcConnection:LOAD(code)
	return self:PUSH(assert(load(code, "Code from RPC", "t")))
end

function RpcConnection:GETGLOBAL(field)
	return self:PUSH(_G[field])
end

function RpcConnection:SETGLOBAL(field)
	assert(self.top > 0, "stack empty")
	_G[field] = self.stack[self.top]
	self.top = self.top - 1
end

function RpcConnection:GETFIELD(field)
	assert(self.top > 0, "stack empty")
	self.stack[self.top] = self.stack[self.top][field]
end

function RpcConnection:MCPREP(field)
	assert(self.top > 0, "stack empty")
	local object = self.stack[self.top]
	if object[field] == nil then error "no such method" end
	self.stack[self.top] = object[field]
	self:PUSH(object)
end

function RpcConnection:SETFIELD(field)
	assert(self.top >= 2, "stack empty")
	self.stack[self.top - 1][field] = self.stack[self.top]
	self.top = self.top - 1
end

function RpcConnection:GETLOCAL(field)
	self:PUSH(self.locals[field])
end

function RpcConnection:SETLOCAL(field)
	assert(self.top > 0, "stack empty")
	self.locals[field] = self.stack[self.top]
	self.top = self.top - 1
end

function RpcConnection:RAWSET(at)
	assert(at <= self.top, "stack did not reach that level")
	if at < 0 then at = self.top + at + 1 end
	assert(self.top >= 2, "stack empty")
	local key = self.stack[self.top - 1]
	local value = self.stack[self.top]
	self.top = self.top - 2
	rawset(self.stack[at], key, value)
end

function RpcConnection:RAWLEN(at)
	assert(at <= self.top, "stack did not reach that level")
	if at < 0 then at = self.top + at + 1 end
	return #(self.stack[at])
end

function RpcConnection:POP(n)
	assert(n <= self.top, "stack overflow")
	for i = self.top - n + 1, self.top do
		self.stack[i] = nil
	end
	self.top = self.top - n
end

function RpcConnection:CALL(n)
	assert(n < self.top, "stack overflow")
	if n == 0 then
		local func = self.stack[self.top]
		self.top = self.top - 1
		local results = { func() }
		for i = 1, #results do self:PUSH(results[i]) end
		return #results
	else
		local args = {}
		for i = self.top - n + 1, self.top do
			assert(self.stack[i] ~= "nil", "can not pass nil holes")
			args[#args + 1] = self.stack[i]
		end
		self.top = self.top - n
		local func = self.stack[self.top]
		self.top = self.top - 1
		local results = { func(unpack(args)) }
		for i = 1, #results do self:PUSH(results[i]) end
		return #results
	end
end

function RpcConnection:AT(at)
	assert(at <= self.top, "stack did not reach that level")
	if at < 0 then at = self.top + at + 1 end
	return self.stack[at]
end

function RpcConnection:TYPE(at)
	assert(at <= self.top, "stack did not reach that level")
	if at < 0 then at = self.top + at + 1 end
	return type(self.stack[at])
end

function RpcConnection:GETTOP(at)
	return self.top
end

function RpcConnection:SETTOP(at)
	assert(at <= 0xFF, "stack overflow")
	for i = at + 1, self.top do
		self.stack[i] = nil
	end
	self.top = at
end

function RpcConnection:serve()
	local state = {}
	state.auth_salt = string.char(
		math.random(0, 255), math.random(0, 255),
		math.random(0, 255), math.random(0, 255),
		math.random(0, 255), math.random(0, 255),
		math.random(0, 255), math.random(0, 255))
	self:write(state.auth_salt)
	local line = self.reader:read(16)
	if line then
		if line == md5sum(self.server.auth_key .. state.auth_salt) then
			self:write(HttpMisc.serverver .. " RPC Ready\r\n")
		else
			return self:write("ERR: authentication failure\r\n"):cleanup()
		end
	else return self:cleanup() end -- CLOSED
	while self.active do
		line, err = self.reader:decode "Line"
		if line then
			local cmd, data, length = line:match "([A-Z]+):([SBIN])([0-9]+)"
			if cmd and data and length then
				if not self[cmd] then
					return self:write("ERR: no such instruction\r\n"):cleanup()
				end
				length = tonumber(length)
				if data == "S" then
					if length > 0xFFFF then return self:cleanup() end
					data = self.reader:read(length)
					if not data then return self:cleanup() end -- CLOSED
				elseif data == "I" then data = length
				elseif data == "N" then data = - length
				elseif length == 0 then data = nil
				else data = length == 1 end
				local ok, result = pcall(self[cmd], self, data)
				cmd = ok and "S" or "E"
				if type(result) == "string" then
					self:write(("%sS%d\r\n"):format(cmd, #result))
					self:write(result)
				elseif result == true then self:write(cmd .. "B1\r\n")
				elseif result == false then self:write(cmd .. "B2\r\n")
				elseif type(result) == "number" then
					if result < 0 then
						self:write(("%sN%d\r\n"):format(cmd, - result))
					else
						self:write(("%sI%d\r\n"):format(cmd, result))
					end
				else self:write(cmd .. "B0\r\n") end
			else return self:cleanup() end -- PROTOCOL ERROR
		else return self:cleanup() end -- CLOSED
	end
end

function RpcConnection:write(chunk)
	if not self.active then
		return nil, "connection closed"
	end
	local ok, err = self:core_write(chunk, self:resumeNRV())
	if ok then
		ok, err = coyield()
		if err then
			self.dont_shutdown = true
			self:cleanup()
			self.active = false
			return nil, err
		end
		return self
	else return nil, err end
end

function RpcConnection:initialize(server, peername)
	self.stack, self.top, self.locals = {}, 0, {}
	self.server, self.peername = server, peername.ip
end

RpcServer = BaseServer:extend()

function RpcServer:initialize(path)
	if type(path) == "number" then
		self.handle = uv.new_tcp()
		assert(self.handle:bind("0.0.0.0", path))
	else
		assert(type(path) == "string", "string expected for path")
		os.remove(path)
		self.handle = uv.new_pipe(false)
		assert(self.handle:bind(path))
	end
	self.auth_key = "It just works." -- default auth key
	return self:start(8)
end

function RpcServer:authenticWith(authentic_key)
	assert(type(authentic_key) == "string")
	self.auth_key = authentic_key
	return self
end

function RpcServer:setup(stream)
	return RpcConnection:new(self, stream:getpeername())
end

