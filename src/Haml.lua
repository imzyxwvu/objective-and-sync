--
-- This file binds github.com/norman/lua-haml to
-- Object.lua Lua class system.
-- You need a lua-haml installed in your Lua
-- package searching directories.
--

local ext      = require "haml.ext"

package.preload["haml.renderer"] = function()

	local _G           = _G
	local assert       = assert
	local concat       = table.concat
	local error        = error
	local getfenv      = getfenv
	local insert       = table.insert
	local loadstring   = loadstring
	local open         = io.open
	local pairs        = pairs
	local pcall        = pcall
	local setfenv      = setfenv
	local setmetatable = setmetatable
	local sorted_pairs = ext.sorted_pairs
	local tostring     = tostring
	local type         = type
	local rawset       = rawset

	module "haml.renderer"

	local methods = {}

	function methods:escape_html(...)
	  return ext.escape_html(..., self.options.html_escapes)
	end

	local function escape_newlines(a, b, c)
	  return a .. b:gsub("\n", "&#x000A;") .. c
	end

	function methods:preserve_html(string)
	  local string  = string
	  for tag, _ in pairs(self.options.preserve) do
	    string = string:gsub(("(<%s>)(.*)(</%s>)"):format(tag, tag), escape_newlines)
	  end
	  return string
	end

	function methods:attr(attr)
	  return ext.render_attributes(attr, self.options)
	end

	function methods:at(pos)
	  self.current_pos = pos
	end

	function methods:f(file)
	  self.current_file = file
	end

	function methods:b(string)
	  insert(self.buffer, string)
	end

	function methods:make_yield_func()
	  return function(content)
	    return ext.strip(content:gsub("\n", "\n" .. self.buffer[#self.buffer]))
	  end
	end

	function methods:render(locals)
	  local locals      = locals or {}
	  self.buffer       = {}
	  self.current_pos  = 0
	  self.current_file = nil
	  self.env.locals   = locals or {}

	  setmetatable(self.env, {__index = function(table, key)
	    return locals[key] or _G[key]
	  end,
	  __newindex = function(table, key, val) rawset(locals, key, val) end
	  })

	  local succeeded, err = pcall(self.func)
	  if not succeeded then

	    error( ("error in %s (offset %d):"):format(
		self.current_file or "<unknown>",
		self.current_pos - 1) ..
	      tostring(err):gsub('%[.*:', '') )
	  end
	  -- strip trailing spaces
	  if #self.buffer > 0 then
	    self.buffer[#self.buffer] = self.buffer[#self.buffer]:gsub("%s*$", "")
	  end
	  return concat(self.buffer, "")

	end

	function new(precompiled, options)
	  local renderer = {
	    options = options or {},
	    -- TODO: capture compile errors here and determine line number
	    func    = assert(loadstring(precompiled)),
	    env     = {}
	  }
	  setmetatable(renderer, {__index = methods})
	  renderer.env = {
	    r       = renderer,
	    yield   = renderer:make_yield_func()
	  }
	  setfenv(renderer.func, renderer.env)
	  return renderer
	end

end

local parser = require "haml.parser"
local precompiler = require "haml.precompiler"
local renderer = require "haml.renderer"
local assert = assert
local open = io.open
local setmetatable = setmetatable

--- An implementation of the Haml markup language for Lua.
-- <p>
-- For more information on Haml, please see <a href="http://haml.info">The Haml website</a>
-- and the <a href="http://haml.info/docs/yardoc/file.HAML_REFERENCE.html">Haml language reference</a>.
-- </p>

--- Default Haml options.
-- @field format The output format. Can be xhtml, html4 or html5. Defaults to xhtml.
-- @field encoding The output encoding. Defaults to utf-8. Note that this is merely informative; no recoding is done.
-- @field newline The string value to use for newlines. Defaults to "\n".
-- @field space The string value to use for spaces. Defaults to " ".
local options = {
	adapter = "lua",
	attribute_wrapper = "'",
	auto_close = true,
	escape_html = false,
	encoding = "utf-8",
	format = "html5",
	indent = " ",
	newline = "\n",
	preserve = {pre = true, textarea = true},
	space = " ",
	suppress_eval = false,
	-- provided for compatiblity; does nothing
	ugly = false,
	html_escapes = {
		["'"] = '&#039;', ['"'] = '&quot;',
		['&'] = '&amp;',
		['<'] = '&lt;', ['>'] = '&gt;'
	},
	--- These tags will be auto-closed if the output format is XHTML (the default).
	auto_closing_tags = {
		area = true,
		base = true,
		br = true,
		col = true,
		hr = true,
		img = true,
		input = true,
		link = true,
		meta = true,
		param = true
	}
}

function string.htmlsafe(str)
	return ext.escape_html(str, options.html_escapes)
end

Haml = (require "Object"):extend()

function Haml:initialize(haml_code, file_name)
	self.options = { file = file_name }
	for k, v in pairs(options) do self.options[k] = v end
	self[1] = precompiler.new(self.options)
		:precompile(parser.tokenize(haml_code))
end

function Haml:render(...)
	return renderer.new(self[1], self.options):render(...)
end

return Haml