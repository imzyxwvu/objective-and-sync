require "Reader"

FcgiProvider = (require "Object"):extend()

local uv = require "luv"
local coyield, tconcat = coroutine.yield, table.concat
local schar, band = string.char, (bit or bit32).band
local resume = HttpMisc.resumefunc

function FcgiProvider:handle(servervars, postdata, res)
	local stream = self:createStream(res)
	if stream then
		res:associateHandle(stream)
		return self:_handle(servervars, postdata, res, stream)
	else
		return res:displayError(502,
			"<html><body><h1>Bad Gay</h1></body></html>")
	end
end

function FcgiProvider:_handle(servervars, postdata, res, stream)
	local thread = coroutine.running()
	local function send(t, block)
		if block then
			assert(#block < 0x10000, "block too large")
			stream:write(schar(
				0x1, -- FCGI_VERSION_1
				t, -- unsigned char type
				0, 1, -- FCGI_NULL_REQUEST_ID
				band(#block, 0xFF00) / 0x100, band(#block, 0xFF),
				0, 0 -- unsigned char paddingLength, reserved
			) .. block, function(err)
				return resume(thread, not err, err)
			end)
		else
			stream:write(schar(
				0x1, -- FCGI_VERSION_1
				t, 0, 1, 0, 0, 0, 0
			), function(err)
				return resume(thread, not err, err)
			end)
		end
		assert(coyield())
	end
	send(1, schar(
		0, 3, -- unsigned char roleB1, roleB0
		0, -- unsigned char flags
		0, 0, 0, 0, 0 ))
	for k, v in pairs(servervars) do
		local vl = #v
		if vl > 127 then
			vl = schar(#k,
				band(vl, 0x7F000000) / 0x1000000 + 0x80,
				band(vl, 0xFF0000) / 0x10000,
				band(vl, 0xFF00) / 0x100, band(vl, 0xFF))
		else vl = schar(#k, vl) end
		send(4, vl .. k .. v)
	end
	send(4, nil)
	if postdata then
		for i, v in ipairs(postdata) do send(5, v) end -- FCGI_STDIN
	end
	send(5, nil)
	local reader = Reader:new()
	stream:read_start(function(err, data)
		if err then
			return reader:push(nil, err)
		elseif data then
			return reader:push(data)
		else
			return reader:push(nil)
		end
	end)
	local first_block = true
	while true do
		local block = assert(reader:decode "FcgiPacket")
		if block[1] == 6 then
			if first_block then
				local headEnd, bodyStart = assert(block[2]:find("\r\n\r\n"))
				assert(headEnd and bodyStart, "bad FastCGI backend")
				local head = { "HTTP/1.1 200 OK" }
				for l in block[2]:sub(1, headEnd - 1):gmatch("([^\r\n]+)") do
					local k, v = l:match("^([%a%d%-_]+): ?(.+)$")
					if k == "Status" then head[1] = "HTTP/1.1 " .. v
					else head[#head + 1] = l end
				end
				head[#head + 1] = "Server: " .. HttpMisc.serverver
				head[#head + 1] = "Connection: close\r\n\r\n"
				if not res:write(tconcat(head, "\r\n")) then
					send(2, nil); break
				end
				res.headersent, first_block = 0, false
				if bodyStart < #block[2] then
					if not (res.connection.active and
						res:write(block[2]:sub(bodyStart + 1, -1))) then
						send(2, nil); break
					end
				end
			else
				if not res:write(block[2]) then send(2, nil); break end
			end
		elseif block[1] == 7 and self.stderr then self.stderr:write(block[2])
		elseif block[1] == 3 then break end
	end
	res:close()
end

TcpFcgiProvider = FcgiProvider:extend()

function TcpFcgiProvider:initialize(address, port)
	assert(type(address) == "string")
	self.address = address
	self.port = port or 9000
end

function TcpFcgiProvider:createStream(res)
	local stream = uv.new_tcp()
	stream:connect(self.address, self.port, res:resumeNRV())
	if coyield() then
		return stream
	else stream:close() end
end

UnixFcgiProvider = FcgiProvider:extend()

function UnixFcgiProvider:initialize(path)
	assert(type(path) == "string")
	self.path = path
end

function UnixFcgiProvider:createStream(res)
	local stream = uv.new_pipe(false)
	stream:connect(self.path, res:resumeNRV())
	if coyield() then
		return stream
	else stream:close() end
end

if jit then
	local ffi = require "ffi"
	FcgiProcessPool = UnixFcgiProvider:extend()

	ffi.cdef[[
typedef struct {
	unsigned short sun_family;
	char sun_path[108]; } sockaddr_un;
int socket(int domain, int type, int protocol); 
int bind(int sockfd, struct sockaddr *my_addr, int addrlen); 
int listen(int sockfd, int backlog); 
int close(int sockfd);
	]]

	function FcgiProcessPool:initialize(options)
		assert(type(options) == "table")
		assert(type(options[1]) == "string", "no executable provided")
		self.executable = options[1]
		self.args = options.args
		if options.suid then
			if type(options.suid) == "string" then
				self.uid = assert(
					HttpMisc.finduidof(options.suid), "no such user")
			else
				assert(type(options.suid) == "number")
				self.uid = options.suid
			end
		end
		self.path = string.format(
			"/tmp/zywebfcgi-%d.sock",
			math.random(10000, 99999))
		os.remove(self.path)
		self.sockfd = ffi.C.socket(1, 1, 0) -- AF_UNIX
		assert(self.sockfd > -1, "can not create socket")
		local addr = ffi.new "sockaddr_un"
		addr.sun_family = 1 -- AF_UNIX
		addr.sun_path = self.path
		if ffi.C.bind(self.sockfd,
			ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) < 0 then
			ffi.C.close(self.sockfd)
			error("can not bind path", 2)
		end
		if ffi.C.listen(self.sockfd, options.backlog or 8) < 0 then
			ffi.C.close(self.sockfd)
			error("listen() failure", 2)
		end
		self.pool = {}
		self.gcanchor = HttpMisc.gcanchor(function()
			return self:cleanup()
		end)
		if options.initial then
			for i = 1, options.initial do self:spawn() end
		end
	end
	
	function FcgiProcessPool:spawn()
		local process, pid
		process, pid = assert(uv.spawn(self.executable, {
			args = self.args, uid = self.uid, stdio = { self.sockfd }
		}, function()
			process:close()
			self.pool[pid] = nil
		end))
		self.pool[pid] = process
	end
	
	function FcgiProcessPool:stat()
		local nprocess, nrss = 0, 0
		for pid in pairs(self.pool) do
			nprocess = nprocess + 1
			nrss = nrss + HttpMisc.getrssof(pid)
		end
		return nprocess, nrss
	end
	
	function FcgiProcessPool:cleanup()
		for k, process in pairs(self.pool) do
			process:kill()
		end
		if self.sockfd then
			ffi.C.close(self.sockfd)
			self.sockfd = nil
		end
		os.remove(self.path)
	end
end