buffer = require('buffer')
msgpack = require('msgpack')
ffi = require('ffi')
local t = require('luatest')
local g = t.group()

local log = require('log')
local helper = require('test.helper')
local HTTPResponse = require('luatest.http_response')
local fio = require('fio')
local json = require('json')


local Process = t.Process
local Server = t.Server

local root = fio.dirname(fio.dirname(fio.abspath(package.search('test.helper'))))
local datadir = fio.pathjoin(root, 'tmp', 'db_test')
local command = fio.pathjoin(root, 'test', 'server_instance.lua')

local server = Server:new({
    command = command,
    workdir = fio.pathjoin(datadir, 'common'),
    env = {custom_env = 'test_value'},
    http_port = 8182,
    net_box_port = 3133,
})

g.before_all = function()
    pcall(log.cfg, {level = 6})
    fio.rmtree(datadir)
    fio.mktree(server.workdir)
    server:start()
    -- wait until booted
    t.helpers.retrying(
        {timeout = 2}, function() server:http_request('get', '/ping') end)

    local workdir = fio.pathjoin(datadir, 'start_stop')
    fio.mktree(workdir)
    s = Server:new({command = command, workdir = workdir, net_box_port = 3301})
    local orig_args = table.copy(s.args)
    s:start()

    local pid = s.process.pid
    t.helpers.retrying({timeout = 0.5}, function()
        t.assert(Process.is_pid_alive(pid))
        s:connect_net_box()
    end)

    buf = buffer.ibuf()
    t.assert_equals(s.net_box.state, 'active')
end

g.after_all = function()
    s:stop()
    if server.process then
        server:stop()
    end
    fio.rmtree(datadir)
end

g.test_errors = function()
    -- Encode/decode error messages
    t.assert_error_msg_content_equals("msgpack.encode: a Lua object expected",
        function() msgpack.encode() end)
    t.assert_error_msg_content_equals(
        "msgpack.encode: argument 2 must be of type 'struct ibuf'",
        function() msgpack.encode('test', 'str') end)
    t.assert_error_msg_content_equals(
        "msgpack.encode: argument 2 must be of type 'struct ibuf'",
        function()
            msgpack.encode('test', buf.buf)
        end)

    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode() end)
    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode(123) end)
    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode(buf) end)

    t.assert_error_msg_content_equals("bad argument #2 to 'decode' (number expected, got string)",
    function() msgpack.decode(buf.buf, 'size') end)
    t.assert_error_msg_content_equals("msgpack.decode: offset is out of bounds",
    function() msgpack.decode('test', 0) end)
    t.assert_error_msg_content_equals("msgpack.decode: offset is out of bounds",
    function() msgpack.decode('test', 5) end)

    t.assert_error_msg_content_equals("bad argument #2 to 'decode' (number expected, got string)",
    function() msgpack.decode('test', 'offset') end)
    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode_unchecked() end)
    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode_unchecked(123) end)
    t.assert_error_msg_content_equals("msgpack.decode: a Lua string or 'char *' expected",
    function() msgpack.decode_unchecked(buf) end)

    t.assert_error_msg_content_equals("msgpack.decode: offset is out of bounds",
    function() msgpack.decode_unchecked('test', 0) end)
    t.assert_error_msg_content_equals("msgpack.decode: offset is out of bounds",
    function() msgpack.decode_unchecked('test', 5) end)
    t.assert_error_msg_content_equals("bad argument #2 to 'decode_unchecked' (number expected, got string)",
    function() msgpack.decode_unchecked('test', 'offset') end)
end

g.test_encode_decode_strings = function()
    -- Encode/decode strings.
    local first_table = {1, 2, 3}
    local second_table = {4, 5, 6}
    local s = msgpack.encode(first_table) .. msgpack.encode(second_table)
    local obj, offset = msgpack.decode(s)

    t.assert_equals(obj, first_table)
    t.assert_items_equals(obj, first_table)
    obj, offset = msgpack.decode(s, offset)
    t.assert_items_equals(obj, second_table)
    t.assert(offset == #s + 1)

    obj, offset = msgpack.decode_unchecked(s)
    t.assert_items_equals(obj, first_table)
    obj, offset = msgpack.decode_unchecked(s, offset)
    t.assert_items_equals(obj, second_table)
    t.assert_equals(offset, #s + 1)
end

g.test_encode_decode_buffer = function()
    -- Encode/decode a buffer.
    local first_buffer = {1, 2, 3}
    local second_buffer = {4, 5, 6}
    local buf = buffer.ibuf()
    local len = msgpack.encode(first_buffer, buf)
    len = msgpack.encode(second_buffer, buf) + len
    t.assert_equals(buf:size(), len)

    local orig_rpos = buf.rpos
    local obj, rpos = msgpack.decode(buf.rpos, buf:size())
    t.assert_items_equals(obj, first_buffer)

    buf.rpos = rpos
    obj, rpos = msgpack.decode(buf.rpos, buf:size())
    t.assert_items_equals(obj, second_buffer)

    buf.rpos = rpos
    t.assert_equals(buf:size(), 0)

    buf.rpos = orig_rpos
    obj, rpos = msgpack.decode_unchecked(buf.rpos, buf:size())
    t.assert_items_equals(obj, first_buffer)

    buf.rpos = rpos
    obj, rpos = msgpack.decode_unchecked(buf.rpos, buf:size())
    t.assert_items_equals(obj, second_buffer)

    buf.rpos = rpos
    t.assert_equals(buf:size(), 0)
end

g.test_invalid_msg_pack = function()
    -- Invalid msgpack.
    local first_buffer = {1, 2, 3}
    local s = msgpack.encode(first_buffer)
    s = s:sub(1, -2)
    t.assert_error_msg_content_equals("msgpack.decode: invalid MsgPack",
    function() msgpack.decode(s) end)

    local buf = buffer.ibuf()
    t.assert_equals(msgpack.encode(first_buffer, buf), 4)
    t.assert_error_msg_content_equals("msgpack.decode: invalid MsgPack",
    function() msgpack.decode(buf.rpos, buf:size() - 1) end)
end

g.test_encode_decode_struct_buffer = function()
    -- Provide a buffer. Try both 'struct ibuf' and 'struct ibuf *'.
    local buf_storage = buffer.ibuf()
    local buf = ffi.cast('struct ibuf *', buf_storage)
    local size = msgpack.encode({a = 1, b = 2}, buf)
    t.assert_equals((msgpack.decode(buf.rpos, size)), {a = 1, b = 2})

    buf_storage = nil
    buf = buffer.ibuf()
    size = msgpack.encode({c = 3, d = 4}, buf)
    t.assert_equals((msgpack.decode(buf.rpos, size)), {c = 3, d = 4})
end

g.test_encode_decode_char_buffer = function()
    -- Decode should accept both 'char *' and 'const char *'.
    local buf = buffer.ibuf()
    local elem = 100
    local size = msgpack.encode(elem, buf)
    t.assert_equals((msgpack.decode(ffi.cast('char *', buf.rpos), size)), elem)
    t.assert_equals((msgpack.decode(ffi.cast('const char *', buf.rpos), size)), elem)
end

g.test_size_not_negative = function()
    -- gh-4224: msgpack.decode(cdata, size) should check, that size
    -- is not negative.
    t.assert_error_msg_content_equals("msgpack.decode: size can't be negative",
    function() msgpack.decode(ffi.cast('char *', '\x04\x05\x06'), -1) end)
end

g.test_encode_decode_decimals = function()
    -- gh-4333: msgpack encode/decode decimals.
    decimal = require('decimal')
    local a = decimal.new('1e37')
    local b = decimal.new('1e-38')
    local c = decimal.new('1')
    local d = decimal.new('0.1234567')
    local e = decimal.new('123.4567')
    t.assert_equals(msgpack.decode(msgpack.encode(a)), a)
    t.assert_equals(msgpack.decode(msgpack.encode(b)), b)
    t.assert_equals(msgpack.decode(msgpack.encode(c)), c)
    t.assert_equals(msgpack.decode(msgpack.encode(d)), d)
    t.assert_equals(msgpack.decode(msgpack.encode(e)), e)
end

g.test_encode_decode_uuid = function()
    -- encode/decode uuid
    local uuid = require('uuid')
    for i = 1, 10 do
        local src = uuid.new()
        local res = msgpack.decode(msgpack.encode(src))
        t.assert_equals(src, res)
    end
end
