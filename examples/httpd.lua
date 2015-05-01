package.path = package.path .. ";../src/?.lua"

require "HttpServer"package.path = package.path .. ";../src/?.lua"

require "HttpServer"
require "VirtualHost"

uv = HttpMisc.backend

HttpMisc.setupSignals() -- to make sure GC runs

htdocs =
	VirtualHost:new(uv.cwd() .. "/htdocs")
		:logRequestsTo(HttpLogger:new())

server = HttpServer:new(8080, function(req, res)
	htdocs:handle(req, res)
	if res:handled() then return end
	res:displayError(404, "<h1>Not Found</h1>")
end)

print "Visit http://127.0.0.1:8080 to see the magic."

uv.run()
require "VirtualHost"

uv = HttpMisc.backend

HttpMisc.setupSignals() -- to make sure GC runs

htdocs =
	VirtualHost:new(uv.cwd() .. "/htdocs")
		:logRequestsTo(HttpLogger:new())

server = HttpServer:new(8080, function(req, res)
	htdocs:handle(req, res)
	if res:handled() then return end
	res:displayError(404, "<h1>Not Found</h1>")
end)

print "Visit http://127.0.0.1:8080 to see the magic."

uv.run()