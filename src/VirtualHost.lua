require "HttpMisc"
require "FcgiProvider"

local uv = require "luv"
local mmin = math.min

VirtualHost = (require "Object"):extend()

function VirtualHost:initialize(initial)
	self.fastcgi_providers = {}
	if type(initial) == "table" then
		self.document_root = assert(initial.DocRoot, "no document root specified")
		if initial.Error404 then self.error_page_404 = "/" .. initial.Error404 end
		self.default_docs = initial.DefaultDoc or HttpMisc.defaultdocs
	else
		assert(type(initial) == "string", "document root must be a string")
		self.document_root = initial
		self.default_docs = HttpMisc.defaultdocs
	end
end

function VirtualHost:errorPage404(error_page)
	assert(type(error_page) == "string", "string expected for error page")
	self.error_page_404 = "/" .. error_page
	return self
end

function VirtualHost:useFCGI(suffix, provider)
	self.fastcgi_providers[suffix] = FcgiProvider:check(provider)
	return self
end

function VirtualHost:logRequestsTo(logger)
	self.log_to = HttpLogger:check(logger)
	return self
end

function VirtualHost:rewriteRules(rules)
	if type(rules) == "string" then
		local rules_json = HttpMisc.readall(rules)
		self.rewriting = (require "cjson").decode(rules_json)
	else
		assert(type(rules) == "table", "table expected for rules")
		self.rewriting = rules
	end
	return self
end

function VirtualHost:handle(req, res)
	local f_path = ""
	local f_attr
	local f_index = true
	for p in req.resource:gmatch("([^/\\]+)") do
		if p:find("^%.") then f_attr, f_index = nil, false; break else
			f_path = f_path .. "/" .. p
			f_attr = uv.fs_stat(self.document_root .. f_path)
			if f_attr then
				if f_attr.type == "file" then f_index = false; break end
			else f_index = false; break end
		end
	end
	if f_index then
		if req.resource:sub(-1, -1) == "/" then
			local base_path = f_path .. "/"
			for i, v in ipairs(self.default_docs) do
				f_path = base_path .. v
				f_attr = uv.fs_stat(self.document_root .. f_path)
				if f_attr then break end
			end
		else
			local location = req.resource .. "/"
			if #req.query > 0 then location = location .. "?" .. req.query end
			return res:redirectTo(location)
		end
	end
	if self.log_to then self.log_to:record(req) end
	if not f_attr and self.rewriting then
		for k, v in pairs(self.rewriting) do
			local args = { req.resource:match(k) }
			if next(args) then
				local query
				f_path, query = v:gsub("([%%$])([0-9])", function(m, n)
					if m == "$" then return args[tonumber(n)]
					elseif m == "%" and n == "1" then return req.query end
				end):match("(/[^ %?]+)%??(.*)")
				if #query > 0 then req.query = query end
				f_attr = uv.fs_stat(self.document_root .. f_path)
				break
			end
		end
	end
	if not f_attr and self.error_page_404 then
		f_path = self.error_page_404
		f_attr = uv.fs_stat(self.document_root .. f_path)
	end
	if f_attr then
		local suffix = f_path:match("%.([A-Za-z0-9]+)$")
		if suffix then suffix = suffix:lower() end
		if self.fastcgi_providers[suffix] then
			local reader = res.connection.reader
			local pc = tonumber(req.headers["content-length"])
			if pc then
				if pc > 8388608 then
					return res:displayError(413, "<html><h1>Request Entity Too Large</h1></body></html>")
				else
					local left = pc
					pc = {}
					while left > 0 do
						local blk = reader:read(mmin(left, 32768))
						if blk then pc[#pc + 1], left = blk, left - #blk else return res:close() end
					end
				end
			end
			return self.fastcgi_providers[suffix]:handle(
				HttpMisc.servervars(req, {
					SCRIPT_FILENAME = self.document_root .. f_path,
					SCRIPT_NAME = f_path,
					SERVER_NAME = req.headers["host"],
					SERVER_PORT = "80",
					DOCUMENT_ROOT = self.document_root,
					CONTENT_TYPE = req.headers["content-type"],
					CONTENT_LENGTH = pc and req.headers["content-length"]
				}), pc, res)
		else
			if req.method ~= "GET" and req.method ~= "HEAD" then
				return res:DisplayError(405, [[<html><body><h1>405 Method Not Allowed</h1></body></html>]])
			end
			local last_m = os.date("!%a, %d %b %Y %H:%M:%S GMT", f_attr.mtime.sec)
			if last_m == req.headers["if-modified-since"] then
				return res:writeHeader(304, { })
			else
				return res:serveFile{
					self.document_root .. f_path, f_attr,
					content_type = HttpMisc.mimetypes[suffix],
					only_header = req.method == "HEAD",
					last_modified = last_m
				}
			end
		end
	end
end