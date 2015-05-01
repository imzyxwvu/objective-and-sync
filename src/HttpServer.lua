require "HttpMisc"
require "BaseServer"

local coyield, costatus = coroutine.yield, coroutine.status
local mmin, uv = math.min, HttpMisc.backend

HttpResponse = (require "Object"):extend()

local statuscodes = {
	[100] = 'Continue', [101] = 'Switching Protocols',
	[200] = 'OK', [201] = 'Created', [202] = 'Accepted',
	[203] = 'Non-Authoritative Information',
	[204] = 'No Content', [205] = 'Reset Content', [206] = 'Partial Content',
	[300] = 'Multiple Choices', [301] = 'Moved Permanently', [302] = 'Found',
	[303] = 'See Other', [304] = 'Not Modified',
	[400] = 'Bad Request', [401] = 'Unauthorized', [403] = 'Forbidden',
	[404] = 'Not Found', [405] = 'Method Not Allowed', [406] = 'Not Acceptable',
	[408] = 'Request Time-out', [409] = 'Conflict', [410] = 'Gone',
	[411] = 'Length Required', [412] = 'Precondition Failed',
	[413] = 'Request Entity Too Large', [415] = 'Unsupported Media Type',
	[416] = 'Requested Range Not Satisfiable', [417] = 'Expectation Failed',
	[418] = 'I\'m a teapot', -- RFC 2324
	[500] = 'Internal Server Error', [501] = 'Not Implemented',
	[502] = 'Bad Gateway', [503] = 'Service Unavailable',
}

function HttpResponse:initialize(connection, request)
	self.connection, self.thread = connection, connection.thread
	self.associated_handles = {}
	self.cleanedup = false
	self.tx = 0
end

function HttpResponse:resumeNRV()
	return self.connection:resumeNRV()
end

function HttpResponse:resumeFunc()
	return self.connection:resumeFunc()
end

function HttpResponse:associateHandle(handle)
	self.associated_handles[#self.associated_handles + 1] = assert(handle)
end

function HttpResponse:write(chunk)
	if not self.connection.active then
		return nil, "connection closed or cleaned up"
	end
	local ok, err = self.connection:core_write(chunk, self.connection:resumeNRV())
	if ok then
		ok, err = coyield()
		if err then
			self.connection.dont_shutdown = true
			self:close()
			return nil, err
		end
		self.tx = self.tx + #chunk
		return self
	else return nil, err end
end

function HttpResponse:writeHeader(status, headers)
	assert(not self.headersent, "header already sent")
	assert(statuscodes[status], "bad status code")
	local head = { ("HTTP/1.1 %d %s\r\n"):format(status, statuscodes[status]) }
	for k, v in pairs(headers) do
		if type(v) == "table" then
			for i, vv in ipairs(v) do
				head[#head + 1] = string.format("%s: %s\r\n", k, vv)
			end
		else head[#head + 1] = string.format("%s: %s\r\n", k, v) end
	end
	head[#head + 1] = string.format("Server: %s\r\n\r\n",
		self.connection.server_ver or HttpMisc.serverver)
	assert(self:write(head))
	self.headersent = true
	return self
end

function HttpResponse:serveFile(file_request)
	local stat = file_request[2] or uv.fs_stat(file_request[1])
	if stat then
		local rest = stat.size
		self:writeHeader(200, {
			["Content-Type"] = file_request.content_type,
			["Last-Modified"] = file_request.last_modified,
			["Content-Length"] = rest })
		if file_request.only_header then return end
		uv.fs_open(file_request[1], "r", 0, self.connection:resumeFunc())
		local fd, err = assert(coyield())
		local offset = 0
		local function readsome(len)
			uv.fs_read(fd, len, offset, self.connection:resumeFunc())
			local data, err = coyield()
			if err then
				uv.fs_close(fd)
				error(err)
			else
				offset = offset + #data
				return data
			end
		end
		while rest > 0 do
			local data = readsome(mmin(rest, 65536))
			if self:write(data) then
				rest = rest - #data
			else break end
		end
		uv.fs_close(fd)
	else
		return self:displayError(404,
			"<html><body><h1>Not Found</h1></body></html>")
	end
end

function HttpResponse:redirectTo(uri)
	assert(type(uri) == "string", "only redirects to URL strings")
	assert(not uri:find("[\r\n]"), "NEWLINE found in location")
	return self:writeHeader(302, { ["Content-Length"] = 0, ["Location"] = uri })
end

function HttpResponse:displayError(statuscode, description)
	if not self:handled() then
		self:writeHeader(statuscode, {
			["Content-Length"] = #description,
			["Connection"] = "close",
			["Content-Type"] = "text/html" })
		self:write(description)
	end
	self:close()
end

function HttpResponse:handled()
	return self.headersent or self.cleanedup
end

function HttpResponse:cleanup()
	if self.cleanedup then return end
	for i, handle in ipairs(self.associated_handles) do
		handle:close()
	end
	self.associated_handles = nil
	self.cleanedup = true
end

function HttpResponse:close()
	self.connection:cleanup()
	self.connection.active = false
	return self:cleanup()
end

HttpFakeResponse = HttpResponse:extend()

function HttpFakeResponse:initialize(connection, request)
	self.thread = coroutine.running()
	self.associated_handles = {}
	self.cleanedup = false
	self.reader = Reader:new()
end

function HttpFakeResponse:write(chunk)
	if self.cleanedup then
		return nil, "connection closed or cleaned up"
	end
	self.reader:push(chunk)
	return self
end

function HttpFakeResponse:resumeNRV()
	return function(err)
		return resume(self.thread, not err, err)
	end
end

function HttpFakeResponse:resumeFunc()
	return function(err, val)
		if err then
			return resume(self.thread, nil, err)
		else
			return resume(self.thread, val)
		end
	end
end

function HttpFakeResponse:close()
	self.reader:push(nil)
	return self:cleanup()
end

HttpConnection = BaseConnection:extend()

function HttpConnection:serve()
	while self.active do
		local request = self.reader:decode "HttpRequest"
		if request then
			request.peername = self.peername
			local response = HttpResponse:new(self, request)
			local ok, err = pcall(self.callback, request, response)
			if not self.active then return response:close() end
			if self.cleanedup or self.upgraded then return end
			if not response:handled() then
				if ok then
					response:displayError(404,
						"<html><body><h1>Request Not Handled</h1></body></html>")
				else
					response:displayError(500, ([[<html><body>
<h1>500 Internal Server Uncaught Lua Error</h1><p>%s Error: <strong>%s</strong></p><p><i>
This response is generated by %s</i></p></body></html>]]):format(_VERSION, err, HttpMisc.serverver))
				end
			end
			if request.headers.connection then
				request.headers.connection = request.headers.connection:lower()
				if request.headers.connection == "keep-alive" then
					response:cleanup()
				else return response:close() end
			else return response:close() end
		else return self:cleanup() end
	end
end

function HttpConnection:initialize(server, peer_ip)
	self.callback = server.callback
	self.peername = peer_ip
end

HttpServer = BaseServer:extend()

function HttpServer:initialize(port, callback)
	assert(type(callback) == "function")
	self.handle = uv.new_tcp()
	self.callback = callback
	assert(self.handle:bind("0.0.0.0", port or 80))
	return self:start(128)
end

function HttpServer:setup(stream)
	local peername = stream:getpeername()
	if peername then
		stream:nodelay(true)
		return HttpConnection:new(self, peername.ip)
	end
end

