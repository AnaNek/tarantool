#!/usr/bin/env tarantool

-- get instance name from filename (quorum1.lua => quorum1)
local INSTANCE_ID = string.match(arg[0], "%d")

local SOCKET_DIR = require('fio').cwd()

local TIMEOUT = arg[1] and tonumber(arg[1]) or 0.1
local CONNECT_TIMEOUT = arg[2] and tonumber(arg[2]) or 10

local function instance_uri(instance_id)
    return 'localhost:'..(3310 + instance_id)
--     return SOCKET_DIR..'/quorum'..instance_id..'.sock';
end

-- start console first
-- require('console').listen(os.getenv('ADMIN'))

local workdir = os.getenv('TARANTOOL_WORKDIR')
box.cfg({
    work_dir = workdir,
    listen = os.getenv('TARANTOOL_LISTEN');
    replication_timeout = TIMEOUT;
    replication_connect_timeout = CONNECT_TIMEOUT;
    replication_sync_lag = 0.01;
    replication_connect_quorum = 3;
    replication = {
        instance_uri(1);
        instance_uri(2);
        instance_uri(3);
    };
})

box.once("bootstrap", function()
    local test_run = require('test_run').new()
    box.schema.user.grant('guest','read,write,execute,create,drop,alter,replication','universe')
    box.schema.space.create('test', {engine = test_run:get_cfg('engine')})
    box.space.test:create_index('primary')
end)
