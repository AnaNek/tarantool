env = require('test_run')
net_box = require('net.box')
fio = require('fio')
fiber = require('fiber')
test_run = env.new()
test_run:cmd("create server test with script='box/gh-5928-several-listen-sockets.lua'")

test_run:cmd("setopt delimiter ';'")
function str_split (inputstr, sep)
        local t = {}
        if string.find(inputstr, sep) == nil then
            t[#t + 1] = inputstr
            return t
        end
        for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
                t[#t + 1] = str
        end
        return t
end;
function check_connection(server_addr)
     local conn = net_box.new(server_addr)
     if not conn then
     	return false
     end
     local rc = true
     if conn:ping() == false then
         rc = false
     end
     conn:close()
     return rc
end;
function prepare_several_listen_uri(default_server_addr, listen_sockets_count)
    local listen = ""
    for i = 1, listen_sockets_count do
        local number = 97 + i - 1
        local listen_addr = default_server_addr .. string.upper(string.char(number))
        listen = listen .. listen_addr
        if i ~= listen_sockets_count then
            listen = listen .. ", "
        end
    end
    return listen
end;
function check_connection_for_string_uri(server_addresses_str)
    local connection_result = true
    local server_addresses_table = str_split(server_addresses_str, ", ")
    for i = 1, #server_addresses_table do
        local t = str_split(server_addresses_table[i], "?")
        if check_connection(t[1]) ~= true then
            connection_result = false
        end
    end
    return connection_result
end;
function check_connection_for_table_uri(server_addresses_table)
    local connection_result = true
    for _, server_addresses_str in pairs(server_addresses_table) do
        connection_result = check_connection_for_string_uri(server_addresses_str)
    end
    return connection_result
end;
function check_connection_ex()
    local server_addresses = test_run:eval('test', 'return box.cfg.listen')[1]
    if type(server_addresses) == 'table' then
        return check_connection_for_table_uri(server_addresses)
    else
        return check_connection_for_string_uri(server_addresses)
    end
end;
function prepare_several_listen_uri(default_server_addr, listen_sockets_count)
    local listen = ""
    for i = 1, listen_sockets_count do
        local number = 97 + i - 1
        local listen_addr = default_server_addr .. string.upper(string.char(number))
        listen = listen .. listen_addr
        if i ~= listen_sockets_count then
            listen = listen .. ", "
        end
    end
    return listen
end;
test_run:cmd("setopt delimiter ''");

test_run:cmd(string.format("start server test with args=\"%s\"", 1))
default_server_addr = test_run:eval('test', 'return box.cfg.listen')[1]
test_run:cmd("stop server test")

connection_result = true
graceful_release = true
test_run:cmd("setopt delimiter ';'")
for thread_count = 1, 3 do
    for listen_count = 1, 2 do
    	test_run:cmd(string.format("start server test with args=\"%s\"", thread_count))
        local addr = prepare_several_listen_uri(default_server_addr, listen_count)
        test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", addr))
        local server_addresses_str = test_run:eval('test', 'return box.cfg.listen')[1]
        local server_addresses_table = str_split(server_addresses_str, ", ")
        for i = 1, #server_addresses_table do
            if check_connection(server_addresses_table[i]) ~= true then
                connection_result = false
            end
        end
        test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", default_server_addr))
        server_addresses_str = test_run:eval('test', "return box.cfg.listen")[1]
        assert(default_server_addr == server_addresses_str)
        test_run:cmd("stop server test")
        for i = 1, #server_addresses_table do
            if fio.path.exists(server_addresses_table[i]) then
                graceful_release = false
            end
        end
        if fio.path.exists(server_addresses_str) then
                graceful_release = false
        end
    end
end
test_run:cmd("setopt delimiter ''");
assert(connection_result == true)
assert(graceful_release == true)

-- Now tarantool accepts the table as a parameter of the listen option
-- Check this new ability. Be careful, `12` - it is a size of table in
-- corresponding `gh-5928-several-listen-sockets.lua` file.
test_run:cmd("setopt delimiter ';'")
for i = 1, 12 do
    test_run:cmd(string.format("start server test with args=\"1 %s\"", i))
    connection_result = check_connection_ex()
    assert(connection_result == true)
    test_run:eval('test', string.format("box.cfg{ listen = \"%s\" }", default_server_addr))
    test_run:cmd("stop server test")
end;
test_run:cmd("setopt delimiter ''");

test_run:cmd(string.format("start server test with args=\"%s\"", 1))
test_run:cmd("switch test")
test_run:cmd("setopt delimiter ';'")
function listen_with_bad_uri(idx)
    local default_server_addr = box.cfg.listen
    local table_uries = {
        { "  " },
        { { uri = string.format("%s", default_server_addr) }, { uri = "  " } },
        { { uri = string.format("%s", default_server_addr) }, { uri = "?" } },
        { uri = string.format("%s", default_server_addr), transport = "unexpected_value" },
        { default_server_addr, uri = string.format("%s", default_server_addr), transport = "plain" },
        default_server_addr .. "?transport=",
        default_server_addr .. "?transport=plain&plain",
        default_server_addr .. "?unexpercted_option=unexpected_value",
        default_server_addr .. "?transport=plain,plain",
        "?/transport=plain",
        { transport="plain" },
    }
    assert(idx and idx > 0 and idx <= #table_uries)
    box.cfg ({ listen = table_uries[idx] })
end;
function get_corresponding_error(idx)
    local table_uries_corresponding_errors = {
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': invalid value `unexpected_value` for transport option",
        "Incorrect value for option 'listen': passing uri in table format requires a string key for each value",
        "Incorrect value for option 'listen': invalid value `null` for uri `transport` option",
        "Incorrect value for option 'listen': invalid value `null` for uri `plain` option",
        "Incorrect value for option 'listen': invalid option `unexpercted_option` for uri",
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': expected host:service or /unix.socket",
        "Incorrect value for option 'listen': missing uri",
    }
    assert(idx and idx > 0 and idx <= #table_uries_corresponding_errors)
    return table_uries_corresponding_errors[idx]
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("switch default")
-- Here we check incorrect listen options
-- rc contains error message!
test_run:cmd("setopt delimiter ';'")
for i = 1, 11 do
    local rc = test_run:eval('test', string.format("return listen_with_bad_uri(%d)", i))
    assert(type(rc) == 'table' and rc[1] and type(rc[1]) == 'table')
    local err = test_run:eval('test', string.format("return get_corresponding_error(%d)", i))
    assert(rc[1].error == err[1])
end;
test_run:cmd("setopt delimiter ''");
test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", default_server_addr))
test_run:cmd("stop server test")

test_run:cmd(string.format("start server test with args=\"%s\"", 1))
test_run:cmd("switch test")
test_run:cmd("setopt delimiter ';'")
function stop_listen(idx)
    assert(idx)
    local table_uries_stop_listen = {
        "",
        {},
        {""}
    }
    assert(idx and idx > 0 and idx <= #table_uries_stop_listen)
    box.cfg ({ listen = table_uries_stop_listen[idx] })
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("switch default")

test_run:cmd("setopt delimiter ';'")
for i = 1, 3 do
    test_run:eval('test', string.format("return stop_listen(%d)", i))
    assert(test_run:grep_log('test', "set 'listen' configuration option to null") ~= nil)
    test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", default_server_addr))
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("stop server test")

-- Special test case to check that all unix socket paths deleted
-- in case when `listen` fails because of invalid uri. Iproto performs
-- `bind` and `listen` operations sequentially to all uris from the list,
-- so we need to make sure that all resources for those uris for which
-- everything has already completed will be successfully cleared in case
-- of error for one of the next uri in list.
test_run:cmd(string.format("start server test with args=\"%s\"", 1))
test_run:cmd("switch test")
test_run:cmd("setopt delimiter ';'")
function listen_with_bad_uri()
    local default_server_addr = box.cfg.listen
    local baduri = { default_server_addr .. "A", default_server_addr .. "B ", "baduri:1" }
    box.cfg ({ listen = baduri })
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("switch default")
-- can't resolve uri for bind
assert(test_run:eval('test', "return listen_with_bad_uri()")[1].error)
assert(not fio.path.exists(default_server_addr .. "A"))
assert(not fio.path.exists(default_server_addr .. "B"))
test_run:cmd("stop server test")

-- Special test case that user unable to set same uris
test_run:cmd(string.format("start server test with args=\"%s\"", 1))
test_run:cmd("switch test")
test_run:cmd("setopt delimiter ';'")
function listen_with_bad_uri()
    local default_server_addr = box.cfg.listen
    local baduri = default_server_addr .. "A, " .. default_server_addr .. "A"
    box.cfg ({ listen = baduri })
end;
test_run:cmd("setopt delimiter ''");
test_run:cmd("switch default")
same_uris_error = test_run:eval('test', "return listen_with_bad_uri()")[1]
assert(same_uris_error.error)
test_run:eval('test', string.format("box.cfg{ listen = \'%s\' }", default_server_addr))
test_run:cmd("stop server test")

test_run:cmd("cleanup server test")
test_run:cmd("delete server test")
