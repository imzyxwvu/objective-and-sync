require "HttpMisc"

local corunning, coyield = coroutine.running, coroutine.yield
local resume, tconcat = HttpMisc.resumefunc, table.concat

local BuiltinDecoders = {}

function BuiltinDecoders.HttpRequest(buffer)
	local l, r = buffer:find("\r?\n\r?\n")
	if l and r then
		assert(l - 1 > 1, "empty request")
		local head = buffer:sub(1, l - 1)
		local result, firstLine = {}, true
		for l in head:gmatch("([^\r\n]+)") do
			if firstLine then
				local verb, resource = l:match("^([A-Z]+) ([^%s]+) HTTP/1%.[01]$")
				assert(verb and resource, "bad request")
				result.method, result.resource_orig = verb, resource
				local resource2, querystr = resource:match("^([^%?]+)%??(.*)")
				result.headers = {}
				result.resource, result.query = HttpMisc.urldecode(resource2), querystr
				firstLine = false
			else
				local k, v = l:match("^([A-Za-z0-9%-]+):%s?(.+)$")
				assert(k and v, "bad request")
				result.headers[k:lower()] = v
			end
		end
		return result, buffer:sub(r + 1, -1)
	elseif #buffer > 0x10000 then -- impossible for a header to be larger than 64K
		error "header too long" -- notify the reader to stop reading from the stream
	end
end

function BuiltinDecoders.Line(buffer)
	local l, r = buffer:find("\r?\n")
	if l and r then
		if r < #buffer then
			return buffer:sub(1, l - 1), buffer:sub(r + 1, #buffer)
		else
			return buffer:sub(1, l - 1)
		end
	elseif #buffer > 0x8000 then
		error "line too long"
	end
end

function BuiltinDecoders.FcgiPacket(buffer)
	if #buffer < 8 then return nil end
	local dl, pl = buffer:byte(5) * 0x100 + buffer:byte(6), buffer:byte(7)
	if #buffer >= dl + pl + 8 then
		local result = { buffer:byte(2), buffer:sub(9,  8 + dl) }
		return result, buffer:sub(9 + dl + pl, -1)
	end
end

Reader = (require "Object"):extend()

function Reader:push(str, err)
	if not str then
		self.stopped = true
		if self.decoder then
			resume(self.readco, nil, err or "stopped")
		end
		if self.watchdog then uv.close(self.watchdog) end
	elseif self.buffer then
		self.buffer = self.buffer .. str
		if self.decoder then
			local s, result, rest = pcall(self.decoder, self.buffer)
			if not s then
				resume(self.readco, nil, result)
			elseif result then
				if rest and #rest > 0 then
					self.buffer = rest
				else
					self.buffer = nil
				end
				resume(self.readco, result)
			end
		end
	else
		if self.decoder then
			local s, result, rest = pcall(self.decoder, str)
			if not s then
				self.buffer = str
				resume(self.readco, nil, result)
			elseif result then
				if rest and #rest > 0 then self.buffer = rest end
				resume(self.readco, result)
			else self.buffer = str end
		else self.buffer = str end
	end
end

function Reader:decode(decoder_name)
	assert(not self.decoder, "already reading")
	local decoder = BuiltinDecoders[decoder_name] or decoder_name
	if self.buffer then
		local s, result, rest = pcall(decoder, self.buffer)
		if not s then
			return nil, result
		elseif result then
			if rest and #rest > 0 then
				self.buffer = rest
			else
				self.buffer = nil
			end
			return result
		end
	end
	if self.stopped then return nil, "stopped" end
	self.readco, self.decoder = corunning(), decoder
	local result, err = coyield()
	self.readco, self.decoder = nil, nil
	return result, err
end

function Reader:read(len)
	local function readSome(buffer)
		if #buffer <= len then return buffer elseif #buffer > len then
			return buffer:sub(1, len), buffer:sub(len + 1, -1)
		end
	end
	local cache = {}
	while len > 0 do
		local block, err = self:decode(readSome)
		if block then
			cache[#cache + 1] = block
			len = len - #block
		else
			cache[#cache + 1] = self.buffer
			self.buffer = tconcat(cache)
			return nil, err
		end
	end
	return tconcat(cache)
end