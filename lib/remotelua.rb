#
# This is a Ruby library that implements a client of RpcServer.lua.
# It provides a stack-based-API to do remote proc calling.
# It also provides a base class called RemoteLua::Base to help you
# redefine Lua classes in the remote process as Ruby classes.
#
# to create an server in Lua:
#
## rpc-server.lua
#
#  require "HttpMisc"
#  require "RpcServer"
#
#  rpc_server = RpcServer:new '/tmp/test-rpc.sock'
#  HttpMisc.backend.run()
#

require 'socket'
require 'digest/md5'

class RemoteLua
	
	class RemoteObject
		
		def initialize(remote_lua)
			@l = remote_lua
			@ref = self.object_id.to_s
			@l.setlocal(@ref)
		end
		
		def object_ref
			@ref
		end
		
		def _call_remote_method(args)
			narg = 1
			args.each do |a|
				@l.push a
				narg += 1
			end
			@l.call narg
		end
		
		def [](key)
			@l.getlocal @ref
			@l.getfield key
			value = @l[-1]
			@l.pop      1
			value
		end
		
		def []=(key, value)
			@l.getlocal @ref
			@l.push     value
			@l.setfield key
			@l.pop      1
		end
		
		def method_missing(method, *args)
			raise 'objected unreferenced' unless @ref
			@l.settop    0
			@l.getlocal  @ref
			@l.exec_inst 'MCPREP', method.to_s
			self._call_remote_method args
		end
		
		def unref
			@l.push nil
			@l.setlocal @ref
		end
		
	end
	
	class Base < RemoteObject
	
		def initialize(remote_lua, *args)
			@l = remote_lua
			@l.settop    0
			@l.getglobal self.class.name
			raise 'not a class' unless @l.type(1) == "table"
			@l.exec_inst 'MCPREP', 'new'
			self._call_remote_method args
			super remote_lua
		end
		
	end
	
	def initialize(socket, auth = 'It just works.')
		@socket = socket
		@socket.write(Digest::MD5.digest(auth + @socket.read(8)))
		@hello_line = @socket.gets
		if @hello_line.start_with? 'ERR:' then
			raise "remote #{@hello_line}"
		end
	end
	
	def exec_inst(inst, value)
		if value == nil then
			@socket.puts "#{inst}:B0"
		elsif value == true then
			@socket.puts '#{inst}:B1'
		elsif value == false then
			@socket.puts '#{inst}:B2'
		elsif value.is_a? Integer then
			if value < 0 then
				@socket.puts "#{inst}:N#{(-value).to_s}"
			else
				@socket.puts "#{inst}:I#{value.to_s}"
			end
		elsif value.is_a? String then
			@socket.puts "#{inst}:S#{value.bytesize}"
			@socket.write(value)
		else
			raise 'can not push this value'
		end
		result = @socket.gets
		raise 'connection is down' unless result
		result = result.match /\A([ES])([SBIN])([\d]+)/
		raise 'protocol out of data' unless result
		data = result[3].to_i
		case result[2]
		when 'B'
			if data == 0 then
				data = nil
			else
				data = data == 1
			end
		when 'I'
			data = data.to_i
		when 'N'
			data = - data.to_i
		when 'S'
			data = @socket.read(data)
		else
			raise 'protocol out of date'
		end
		if result[1] == 'E' then
			raise data
		else
			data
		end
	end
	
	def push(value)
		if value.is_a? RemoteObject then
			getlocal value.object_ref
		else
			exec_inst('PUSH', value)
		end
	end
	
	def pushvalue(at)
		exec_inst('PUSHVALUE', at)
	end
	
	def settop(at)
		exec_inst('SETTOP', at)
	end
	
	def gettop()
		exec_inst('GETTOP', nil)
	end
	
	def getglobal(field)
		exec_inst('GETGLOBAL', field)
	end
	
	def setglobal(field)
		exec_inst('SETGLOBAL', field)
	end
	
	def getfield(field)
		exec_inst('GETFIELD', field)
	end
	
	def setfield(field)
		exec_inst('SETFIELD', field)
	end
	
	def getlocal(field)
		exec_inst('GETLOCAL', field)
	end
	
	def setlocal(field)
		exec_inst('SETLOCAL', field)
	end
	
	def newtable()
		exec_inst('NEWTABLE', nil)
	end
	
	def load(code)
		exec_inst('LOAD', code)
	end
	
	def eval(code)
		exec_inst('LOAD', code)
		exec_inst('CALL', 0)
	end
	
	def call(nargs)
		exec_inst('CALL', nargs)
	end
	
	def [](n)
		exec_inst('AT', n)
	end
	
	def type(n)
		exec_inst('TYPE', n)
	end
	
	def pop(n)
		exec_inst('POP', n)
	end
	
	def close
		@socket.close
	end
	
	def self.connect(path)
		l = RemoteLua.new(UNIXSocket.open(path))
		if block_given?
			yield l
			l.close
		else
			l
		end
	end
	
end