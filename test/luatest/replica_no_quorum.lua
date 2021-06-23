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
-- require('console').listen(3010)

box.cfg({
    listen              = 'localhost:3314',
    replication         = 'localhost:3310',
    memtx_memory        = 107374182,
    replication_connect_quorum = 0,
    replication_timeout = 0.1,
})


-- box.schema.user.grant('guest','read,write,execute,create,drop,alter,replication','universe')
