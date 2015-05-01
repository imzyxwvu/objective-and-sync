require "HttpMisc"

local resume, uv = HttpMisc.resumefunc, HttpMisc.backend

BaseConnection = (require "Object"):extend()

function BaseConnection:start()
	self.reader = Reader:new()
	self.active, self.cleanedup = true, false
	self.suspend_id = 0
	self.thread = coroutine.create(self.serve)
	return resume(self.thread, self)
end

function BaseConnection:cleanup()
	if self.cleanedup then return end
	self:core_close()
	self.reader:push(nil)
	self.cleanedup = true
end

function BaseConnection:resumeNRV()
	local resume_id = self.suspend_id
	return function(err)
		if resume_id == self.suspend_id then
			self.suspend_id = self.suspend_id + 1
			return resume(self.thread, not err, err)
		end
	end
end

function BaseConnection:resumeFunc()
	local resume_id = self.suspend_id
	return function(err, val)
		if resume_id == self.suspend_id then
			self.suspend_id = self.suspend_id + 1
			if err then
				return resume(self.thread, nil, err)
			else
				return resume(self.thread, val)
			end
		end
	end
end

function BaseConnection:handleChunk(chunk)
	return self.reader:push(chunk)
end

function BaseConnection:handleClose(err)
	self.active = false
	if err then self.dont_shutdown = true end
	self.suspend_id = self.suspend_id + 1
	coroutine.resume(self.thread, nil, "canceled")
	return self.reader:push(nil, err)
end

BaseServer = (require "Object"):extend()

function BaseServer:start(backlog)
	assert(self.handle, "server handle has not been setted up")
	assert(type(backlog) == "number", "number expected for backlog")
	return assert(self.handle:listen(backlog, function()
		local client = uv.new_tcp()
			if self.handle:accept(client) then
				self:_handle(client, self:setup(client))
			else client:close() end
	end))
end

function BaseServer:_handle(stream, connection)
	if connection then
		function connection:core_write(...) return stream:write(...) end
		function connection:core_close()
			if connection.dont_shutdown then
				return stream:close()
			else
				return stream:shutdown(function() stream:close() end)
			end
		end
		connection:start()
		stream:read_start(function(err, chunk)
			if err then
				return connection:handleClose(err)
			elseif chunk then
				return connection:handleChunk(chunk)
			else
				return connection:handleClose()
			end
		end)
	else return stream:close() end
end

function BaseServer:close()
	return self.handle:close()
end