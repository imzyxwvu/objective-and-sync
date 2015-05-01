local uv = require "luv"
local coresume, schar = coroutine.resume, string.char

math.randomseed(os.time())

HttpMisc = {
	backend = uv,
	serverver = "ZyWebD/15.04",
	defaultdocs = {"index.html", "index.php"} }

HttpMisc.mimetypes = {
	atom = "application/atom+xml",
	hqx = "application/mac-binhex40",
	mathml = "application/mathml+xml",
	doc = "application/msword",
	bin = "application/octet-stream",
	exe = "application/octet-stream",
	class = "application/octet-stream",
	so = "application/octet-stream",
	dll = "application/octet-stream",
	dmg = "application/octet-stream",
	ogg = "application/ogg",
	pdf = "application/pdf",
	eps = "application/postscript", ps = "application/postscript",
	xul = "application/vnd.mozilla.xul+xml",
	xls = "application/vnd.ms-excel",
	ppt = "application/vnd.ms-powerpoint",
	rm = "application/vnd.rn-realmedia",
	xhtml = "application/xhtml+xml", xht = "application/xhtml+xml",
	js = "application/x-javascript", lua = "application/x-lua",
	py = "application/x-python", rb = "application/x-ruby",
	xml = "application/xml", xsl = "application/xml",
	dtd = "application/xml-dtd",
	sh = "application/x-sh",
	swf = "application/x-shockwave-flash",
	tar = "application/x-tar",
	tex = "application/x-tex", latex = "application/x-latex",
	zip = "application/zip",
	au = "audio/basic", snd = "audio/basic",
	mid = "audio/midi", midi = "audio/midi", kar = "audio/midi",
	mpga = "audio/mpeg", mp2 = "audio/mpeg", mp3 = "audio/mpeg",
	aif = "audio/x-aiff", aiff = "audio/x-aiff", aifc = "audio/x-aiff",
	m3u = "audio/x-mpegurl",
	ram = "audio/x-pn-realaudio", ra = "audio/x-pn-realaudio",
	wav = "audio/x-wav",
	bmp = "image/bmp", gif = "image/gif", png = "image/png",
	jpeg = "image/jpeg", jpg = "image/jpeg", jpe = "image/jpeg",
	svg = "image/svg+xml", svgz = "image/svg+xml",
	tiff = "image/tiff", tif = "image/tiff",
	wbmp = "image/vnd.wap.wbmp",
	ico = "image/x-icon", rgb = "image/x-rgb",
	xbm = "image/x-xbitmap", xpm = "image/x-xpixmap",
	ics = "text/calendar", ifb = "text/calendar",
	html = "text/html", htm = "text/html", css = "text/css",
	asc = "text/plain", pod = "text/plain", txt = "text/plain",
	rtx = "text/richtext", rtf = "text/rtf", tsv = "text/tab-separated-values",
	wml = "text/vnd.wap.wml", wmls = "text/vnd.wap.wmlscript",
	mpeg = "video/mpeg", mpg = "video/mpeg", mpe = "video/mpeg",
	qt = "video/quicktime", mov = "video/quicktime",
	avi = "video/x-msvideo", movie = "video/x-sgi-movie"
}

function HttpMisc.resumefunc(thread, ...)
	local s, err = coresume(thread, ...)
	if not s then
		-- print error with stack backtrace
		print(debug.traceback(thread, string.format(
			"error in %s: %s", thread, err)))
	end
end

function HttpMisc.urldecode(is)
	return is:gsub(
		"%%([A-Fa-f0-9][A-Fa-f0-9])",
		function(m) return schar(tonumber(m, 16)) end)
end

function HttpMisc.servervars(req, base)
	local server_vars = base or {
		SERVER_PROTOCOL = "HTTP/1.1",
		CONTENT_TYPE = req.headers["content-type"],
		CONTENT_LENGTH = req.headers["content-length"],
		PATH_INFO = req.resource
	}
	server_vars.SERVER_SOFTWARE = HttpMisc.serverver
	server_vars.REQUEST_URI = req.resource_orig
	server_vars.QUERY_STRING = req.query
	server_vars.REQUEST_METHOD = req.method
	server_vars.REMOTE_ADDR = req.peername
	for k, v in pairs(req.headers) do
		if k ~= "content-type" and k ~= "content-length" then
			server_vars["HTTP_" .. k:gsub("%-", "_"):upper()] = v
		end
	end
	return server_vars
end

function HttpMisc.signal(signame, callback)
	local signal = uv.new_signal()
	uv.signal_start(signal, signame, callback)
	return signal
end

function HttpMisc.setupSignals()
	if HttpMisc.sigpipe and HttpMisc.sigint and HttpMisc.sigterm then return end
	HttpMisc.sigpipe = HttpMisc.signal("sigpipe")
	HttpMisc.sigint = HttpMisc.signal("sigint", function() uv.stop() end)
	HttpMisc.sigterm = HttpMisc.signal("sigterm", function() uv.stop() end)
end

if jit then
	local ffi = require "ffi"
	ffi.cdef[[ int fork(void); int setsid(void); ]]

	function HttpMisc.daemonize(pidfile)
		assert(type(pidfile) == "string", "string expected for pidfile")
		local pid = ffi.C.fork()
		if pid == 0 then
			ffi.C.setsid()
		elseif pid > 0 then
			local fpid = assert(io.open(pidfile, "w"))
			fpid:write(tostring(pid));
			fpid:close();
			print("zywebd: daemon process started, pid=" .. pid)
			os.exit()
			error "os.exit() failed: process should exit"
		else error"fork() failed" end
	end
end

function HttpMisc.finduidof(username)
	local fp = assert(io.open("/etc/passwd", "r"))
	for l in fp:lines() do
		local un, uid = l:match
			"^([A-Za-z0-9%-_]+):[A-Za-z]*:([0-9]+):"
		if un == username then
			fp:close()
			return tonumber(uid)
		end
	end
	fp:close()
end

function HttpMisc.readall(file)
	local fh = assert(io.open(file, "r"))
	local content = fh:read "*a"
	fh:close()
	return content
end

function HttpMisc.getrssof(pid)
	local statm = ("/proc/%d/statm"):format(pid)
	local rsspage = HttpMisc.readall(statm):match "%d+ (%d+) "
	assert(rsspage, "unsupported statm format")
	return tonumber(rsspage) * 4
end

function HttpMisc.gcanchor(anchor)
	local proxy = newproxy(true)
	getmetatable(proxy).__gc = anchor
	return proxy
end

HttpLogger = (require "Object"):extend()

function HttpLogger:initialize(logpath)
	if logpath then
		assert(type(logpath) == "string", "string expected for logpath")
		self[1] = assert(io.open(logpath, "a"))
	else
		self[1] = io.stdout
	end
end

function HttpLogger:record(req)
	return self[1]:write(os.date("[%y-%m-%d %H:%M:%S ") .. req.headers.host .. "] " ..
		req.peername .. " " .. req.method .. " " .. req.resource_orig .. "\n")
end

return HttpMisc