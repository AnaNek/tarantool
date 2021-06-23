local t = require('luatest')
local g = t.group()
local log = require('log')
local helper = require('test.helper')
local fio = require('fio')
local Process = t.Process
local Server = t.Server
local fiber = require('fiber')
local root = fio.dirname(fio.dirname(fio.abspath(package.search('test.helper'))))
local datadir = fio.pathjoin(root, 'tmp', 'quorum_test')
local command = fio.pathjoin(root, 'test', 'server_instance.lua')
local test_run = require('test_run')

-- discuss: move to helpers/create cluster class
DEFAULT_CHECKPOINT_PATTERNS = {"*.snap", "*.xlog", "*.vylog", "*.inprogress",
                               "[0-9]*/"}

local function cleanup(path)
    for _, pattern in ipairs(DEFAULT_CHECKPOINT_PATTERNS) do
        fio.rmtree(fio.pathjoin(path, pattern))
    end
end

local function start_servers(servers)
    for _, server in ipairs(servers) do
        log.info('try to start server: %s', server.alias)
        server:start()
    end

    t.helpers.retrying({timeout = 20},
        function()
            for _, server in ipairs(servers) do
                t.assert(Process.is_pid_alive(server.process.pid),
                    server.alias .. ' failed on start')
                server:connect_net_box()
            end
        end
    )
    for _, server in ipairs(servers) do
        t.assert_equals(server.net_box.state, 'active',
        'wrong state for server="%s"', server.alias)
    end
end

local function stop_servers(servers)
    for _, server in ipairs(servers) do
        server:stop()
    end
end

local function drop_cluster(servers)
    for _, server in ipairs(servers) do
        if server ~= nil then
            log.info('try to stop server: %s', server.alias)
            server:stop()
            cleanup(server.workdir)
            fio.rmtree(server.workdir)
        end
    end
end

-- discuss: move to luatest
local function server_restart(server, args)
    log.info('try to restart server: %s', server.alias)
    server:stop()
    server.args = args
    server:start()
    t.helpers.retrying({timeout = 15}, function()
        t.assert(Process.is_pid_alive(server.process.pid))
        server:connect_net_box()
    end)
    t.assert_equals(server.net_box.state, 'active')
end

g.before_all = function()
    pcall(log.cfg, {level = 6})
    fio.rmtree(datadir)
    fio.mktree(fio.pathjoin(datadir, 'common'))

    local workdir = fio.pathjoin(datadir, 'master')
    fio.mktree(workdir)
    s = Server:new({
        command = command,
        workdir = workdir,
        net_box_port = 3310,
        alias = 'master'
    })
    s:start()

    local quorum1_dir = fio.pathjoin(datadir, 'quorum1')
    local command_quorum1 = fio.pathjoin(root, '../test/luatest', 'quorum1.lua')
    fio.mktree(quorum1_dir)
    quorum1 = Server:new({
        command = command_quorum1,
        workdir = fio.pathjoin(datadir, 'quorum1'),
        net_box_port = 3311,
        args = {'0.1'},
        alias = 'quorum1'
    })
    local quorum2_dir = fio.pathjoin(datadir, 'quorum2')
    local command_quorum2 = fio.pathjoin(root, '../test/luatest', 'quorum2.lua')
    fio.mktree(quorum2_dir)
    quorum2 = Server:new({
        command = command_quorum2,
        workdir = quorum2_dir,
        net_box_port = 3312,
        args = {'0.1'},
        alias = 'quorum2'
    })
    local quorum3_dir = fio.pathjoin(datadir, 'quorum3')
    local command_quorum3 = fio.pathjoin(root, '../test/luatest', 'quorum3.lua')
    fio.mktree(quorum3_dir)
    quorum3 = Server:new({
        command = command_quorum3,
        workdir = quorum3_dir,
        net_box_port = 3313,
        args = {'0.1'},
        alias = 'quorum3'
    })

    t.helpers.retrying({timeout = 0.5}, function()
        t.assert(Process.is_pid_alive(s.process.pid))
        s:connect_net_box()
    end)
    t.assert_equals(s.net_box.state, 'active')

    start_servers({quorum1, quorum2, quorum3})

    local replica_dir = fio.pathjoin(datadir, 'replica_no_quorum')
    local command_replica = fio.pathjoin(root, '../test/luatest', 'replica_no_quorum.lua')
    fio.mktree(replica_dir)
    replica = Server:new({
        command = command_replica,
        workdir = fio.pathjoin(datadir, 'replica_no_quorum'),
        net_box_port = 3314,
        alias = 'replica'
    })
end

g.after_all = function()
    stop_servers({quorum1, quorum2, quorum3, s, replica})
    fio.rmtree(datadir)
end

local function check_replica_follows_all_masters(servers)
    -- Check that the replica follows all masters.
    for i = 1, #servers do
        if servers[i].net_box:eval('return box.info.id') ~= i then
            t.helpers.retrying({timeout = 20}, function()
               t.assert_equals(servers[i].net_box:eval(
                   'return box.info.replication[' .. i .. '].upstream.status'),
                   'follow',
                   servers[i].alias .. ': this server does not follow others.')
            end)
        end
    end
end

local function check_replica_is_orphan_after_restart(quorum1, quorum2)
    -- Stop one replica and try to restart another one.
    -- It should successfully restart, but stay in the
    -- 'orphan' mode, which disables write accesses.
    -- There are three ways for the replica to leave the
    -- 'orphan' mode:
    -- * reconfigure replication
    -- * reset box.cfg.replication_connect_quorum
    -- * wait until a quorum is formed asynchronously
    log.info('start check: %s', 'check_replica_is_orphan_after_restart')
    quorum1:stop()
    server_restart(quorum2, {'0.1', '10'})
    t.assert_str_matches(quorum2.net_box:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2.net_box:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2.net_box:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2.net_box:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2.net_box:eval('return box.space.test:replace{100}')
        end
    )
    quorum2.net_box:eval('box.cfg{replication={}}')
    t.assert_str_matches(quorum2.net_box:eval('return box.info.status'), 'running')
    server_restart(quorum2, {'0.1', '10'})
    t.assert_str_matches(quorum2.net_box:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2.net_box:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2.net_box:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2.net_box:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2.net_box:eval('return box.space.test:replace{100}')
        end
    )
    quorum2.net_box:eval('box.cfg{replication_connect_quorum = 2}')
    quorum2.net_box:eval('return box.ctl.wait_rw()')
    t.assert_not(quorum2.net_box:eval('return box.info.ro'))
    t.assert_str_matches(quorum2.net_box:eval('return box.info.status'), 'running')
    server_restart(quorum2, {'0.1', '10'})
    t.assert_str_matches(quorum2.net_box:eval('return box.info.status'), 'orphan')
    t.assert_error_msg_content_equals('timed out', function()
            quorum2.net_box:eval('return box.ctl.wait_rw(0.001)')
    end)
    t.assert(quorum2.net_box:eval('return box.info.ro'))
    t.helpers.retrying({timeout = 20}, function()
        t.assert(quorum2.net_box:eval('return box.space.test ~= nil'))
    end)
    t.assert_error_msg_content_equals(
        "Can't modify data because this instance is in read-only mode.",
        function()
            quorum2.net_box:eval('return box.space.test:replace{100}')
        end
    )
    quorum1.args = {'0.1'}
    start_servers({quorum1})
    quorum1.net_box:eval('return box.ctl.wait_rw()')
    t.assert_not(quorum1.net_box:eval('return box.info.ro'))
    t.assert_str_matches(quorum1.net_box:eval('return box.info.status'), 'running')
end

local function check_id_for_rebootstrapped_replica_with_removed_xlog(quorum1, quorum2, quorum3)
    log.info('start check: %s', 'check_id_for_rebootstrapped_replica_with_removed_xlog')
    quorum1:stop()
    cleanup(quorum1.workdir)
    fio.rmtree(quorum1.workdir)
    fio.mktree(quorum1.workdir)
    -- The rebootstrapped replica will be assigned id = 4,
    -- because ids 1..3 are busy.
    quorum1.args = {'0.1'}
    start_servers({quorum1})

    t.helpers.retrying({timeout = 20}, function()
        t.assert_equals(quorum1.net_box:eval('return box.space.test:count()'), COUNT)
        t.assert_equals(quorum2.net_box:eval('return box.info.replication[4].upstream.status'), 'follow')
        t.assert(quorum3.net_box:eval('return box.info.replication ~= nil'))
        t.assert_equals(quorum3.net_box:eval('return box.info.replication[4].upstream.status'), 'follow')
    end)

    t.assert_equals(quorum2.net_box:eval('return box.info.replication[4].upstream.status'), 'follow')
    t.assert_equals(quorum3.net_box:eval('return box.info.replication[4].upstream.status'), 'follow')
    local servers = {quorum1, quorum2, quorum3}
    drop_cluster(servers)
end


local function check_quorum_during_reconfiguration()
    -- Test that quorum is not ignored neither during bootstrap, nor
    -- during reconfiguration.
    log.info('start check: %s', 'check_quorum_during_reconfiguration')
    local replica_quorum_dir = fio.pathjoin(datadir, 'replica_quorum')
    local command_replica = fio.pathjoin(root, '../test/luatest', 'replica_quorum.lua')
    fio.mktree(replica_quorum_dir)
    replica_quorum = Server:new({
        command = command_replica,
        workdir = fio.pathjoin(datadir, 'replica_quorum'),
        net_box_port = 3317,
        alias = 'replica_quorum',
        args = {'1', '0.05', '10'}
    })
    start_servers({replica_quorum})
    -- If replication_connect_quorum was ignored here, the instance
    -- would exit with an error.
    t.assert_equals(replica_quorum.net_box:eval('return box.cfg{replication={INSTANCE_URI, nonexistent_uri(1)}}'), nil)

--     TODO: why master and replica establish the connection
--     t.assert_equals(replica_quorum.net_box:eval('return box.info.id'), 1)
    drop_cluster({replica_quorum})
end

local function check_master_master_works()
    log.info('start check: %s', 'check_master_master_works')
    local master_quorum1_dir = fio.pathjoin(datadir, 'master_quorum1')
    local command_replica = fio.pathjoin(root, '../test/luatest', 'master_quorum1.lua')
    fio.mktree(master_quorum1_dir)
    master_quorum1 = Server:new({
        command = command_replica,
        workdir = fio.pathjoin(datadir, 'master_quorum1'),
        net_box_port = 3315,
        args = {'0.1'},
        alias = 'master_quorum1'
    })
    local master_quorum2_dir = fio.pathjoin(datadir, 'master_quorum2')
    local command_replica = fio.pathjoin(root, '../test/luatest', 'master_quorum2.lua')
    fio.mktree(master_quorum2_dir)
    master_quorum2 = Server:new({
        command = command_replica,
        workdir = fio.pathjoin(datadir, 'master_quorum2'),
        net_box_port = 3316,
        args = {'0.1'},
        alias = 'master_quorum2'
    })

    start_servers({master_quorum1, master_quorum2})
    master_quorum1.net_box:eval('repl = box.cfg.replication')
    master_quorum1.net_box:eval('box.cfg{replication = ""}')
    t.assert_equals(master_quorum1.net_box:eval('return box.space.test:insert{1}'), {1})
    master_quorum1.net_box:eval('box.cfg{replication = repl}')
    vclock = master_quorum1.net_box:eval('return box.info.vclock')
    vclock[0] = nil

--     TODO: fix vclock
    fiber.sleep(2)
    t.assert_equals(master_quorum2.net_box:eval('return box.space.test:select()'), {{1}})

    drop_cluster({master_quorum1, master_quorum2})
end

local function check_box_cfg_doesnt_return_before_all_replicas_are_not_configured(quorum1, quorum2, quorum3)
    -- Check that box.cfg() doesn't return until the instance
    -- catches up with all configured replicas.
    log.info('start check: %s', 'check_box_cfg_doesnt_return_before_all_replicas_are_not_configured')
    t.assert_equals(quorum3.net_box:eval('return box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)'), 'ok')
    t.assert_equals(quorum2.net_box:eval('return box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)'), 'ok')
    quorum1:stop()
    t.helpers.retrying({timeout = 20}, function()
        t.assert_not_equals(quorum2.net_box:eval('return box.space.test.index.primary'), nil)
    end)
    COUNT = 100
    quorum2.net_box:eval('for i = 1, ' .. COUNT .. ' do box.space.test:insert{i} end')
    quorum2.net_box:eval("fiber = require('fiber')")
    quorum2.net_box:eval('fiber.sleep(0.1)')
    quorum1.args = {'0.1'}
    start_servers({quorum1})
    t.helpers.retrying({timeout = 20}, function()
        t.assert_equals(quorum1.net_box:eval('return box.space.test:count()'), COUNT)
    end)
    -- Rebootstrap one node of the cluster and check that others follow.
    -- Note, due to ERRINJ_RELAY_TIMEOUT there is a substantial delay
    -- between the moment the node starts listening and the moment it
    -- completes bootstrap and subscribes. Other nodes will try and
    -- fail to subscribe to the restarted node during this period.
    -- This is OK - they have to retry until the bootstrap is complete.
    local servers = {quorum1, quorum2, quorum3}
    for _, server in ipairs(servers) do
        t.assert_equals(server.net_box:eval('return box.snapshot()'), 'ok')
    end
end

local function check_replication_no_quorum()
     -- gh-3278: test different replication and replication_connect_quorum configs.

--   todo: use default server
    log.info('start check: %s', 'check_replication_no_quorum')
    s.net_box:eval("test_run = require('test_run').new()")
    s.net_box:eval("space = box.schema.space.create('test', {engine = test_run:get_cfg('engine')});")
    s.net_box:eval("index = box.space.test:create_index('primary')")
    -- Insert something just to check that replica with quorum = 0 works as expected.
    t.assert_equals(s.net_box:eval('return space:insert{1}'), {1})
    start_servers({replica})
    t.assert_str_matches(replica.net_box:eval('return box.info.status'), 'running')
    t.assert_equals(replica.net_box:eval('return box.space.test:select()'), {{1}})
    replica:stop()
    s.net_box:eval('listen = box.cfg.listen')
    s.net_box:eval("box.cfg{listen = ''}")
    start_servers({replica})
    t.assert_str_matches(replica.net_box:eval('return box.info.status'), 'running')

    -- Check that replica is able to reconnect, case was broken with earlier quorum "fix".
    s.net_box:eval('box.cfg{listen = listen}')
    t.assert_equals(s.net_box:eval('return space:insert{2}'), {2})
--  TODO: fix vclock
    local fiber = require('fiber')
    fiber.sleep(1)
    s.net_box:eval('vclock = box.info.vclock')
    s.net_box:eval('vclock[0] = nil')
    t.assert_str_matches(replica.net_box:eval('return box.info.status'), 'running')
    t.assert_equals(replica.net_box:eval('return box.space.test:select()'), {{1}, {2}})
    s.net_box:eval('return space:drop()')
    drop_cluster({s, replica})
end

g.test_quorum = function()
    check_replica_is_orphan_after_restart(quorum1, quorum2)
    check_replica_follows_all_masters({quorum1, quorum2, quorum3})
    check_box_cfg_doesnt_return_before_all_replicas_are_not_configured(quorum1, quorum2, quorum3)
    check_id_for_rebootstrapped_replica_with_removed_xlog(quorum1, quorum2, quorum3)
    check_replication_no_quorum()
    check_master_master_works()
    check_quorum_during_reconfiguration()
end
