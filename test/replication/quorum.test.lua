test_run = require('test_run').new()

SERVERS = {'quorum1', 'quorum2', 'quorum3'}

-- Deploy a cluster.
test_run:create_cluster(SERVERS)
test_run:wait_fullmesh(SERVERS)

-- Stop one replica and try to restart another one.
-- It should successfully restart, but stay in the
-- 'orphan' mode, which disables write accesses.
-- There are three ways for the replica to leave the
-- 'orphan' mode:
-- * reconfigure replication
-- * reset box.cfg.replication_connect_quorum
-- * wait until a quorum is formed asynchronously
test_run:cmd('stop server quorum1')

test_run:cmd('switch quorum2')

test_run:cmd('restart server quorum2')
box.info.status -- orphan
box.ctl.wait_rw(0.001) -- timeout
box.info.ro -- true
box.space.test:replace{100} -- error
box.cfg{replication={}}
box.info.status -- running

test_run:cmd('restart server quorum2')
box.info.status -- orphan
box.ctl.wait_rw(0.001) -- timeout
box.info.ro -- true
box.space.test:replace{100} -- error
box.cfg{replication_connect_quorum = 2}
box.ctl.wait_rw()
box.info.ro -- false
box.info.status -- running

test_run:cmd('restart server quorum2')
box.info.status -- orphan
box.ctl.wait_rw(0.001) -- timeout
box.info.ro -- true
box.space.test:replace{100} -- error
test_run:cmd('start server quorum1')
box.ctl.wait_rw()
box.info.ro -- false
box.info.status -- running

-- Check that the replica follows all masters.
box.info.id == 1 or box.info.replication[1].upstream.status == 'follow'
box.info.id == 2 or box.info.replication[2].upstream.status == 'follow'
box.info.id == 3 or box.info.replication[3].upstream.status == 'follow'

-- Check that box.cfg() doesn't return until the instance
-- catches up with all configured replicas.
test_run:cmd('switch quorum3')
box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)
test_run:cmd('switch quorum2')
box.error.injection.set("ERRINJ_RELAY_TIMEOUT", 0.001)
test_run:cmd('stop server quorum1')

for i = 1, 100 do box.space.test:insert{i} end
fiber = require('fiber')
fiber.sleep(0.1)

test_run:cmd('start server quorum1')
test_run:cmd('switch quorum1')
box.space.test:count() -- 100

-- Rebootstrap one node of the cluster and check that others follow.
-- Note, due to ERRINJ_RELAY_TIMEOUT there is a substantial delay
-- between the moment the node starts listening and the moment it
-- completes bootstrap and subscribes. Other nodes will try and
-- fail to subscribe to the restarted node during this period.
-- This is OK - they have to retry until the bootstrap is complete.
test_run:cmd('switch quorum3')
box.snapshot()
test_run:cmd('switch quorum2')
box.snapshot()

test_run:cmd('switch quorum1')
test_run:cmd('restart server quorum1 with cleanup=1')

box.space.test:count() -- 100

-- The rebootstrapped replica will be assigned id = 4,
-- because ids 1..3 are busy.
test_run:cmd('switch quorum2')
fiber = require('fiber')
while box.info.replication[4].upstream.status ~= 'follow' do fiber.sleep(0.001) end
box.info.replication[4].upstream.status
test_run:cmd('switch quorum3')
fiber = require('fiber')
while box.info.replication[4].upstream.status ~= 'follow' do fiber.sleep(0.001) end
box.info.replication[4].upstream.status

-- Cleanup.
test_run:cmd('switch default')
test_run:drop_cluster(SERVERS)

--
-- gh-3278: test different replication and replication_connect_quorum configs.
--

box.schema.user.grant('guest', 'replication')
test_run:cmd("create server replica with rpl_master=default, script='replication/replica_no_quorum.lua'")
test_run:cmd("start server replica")
test_run:cmd("switch replica")
box.info.status -- running
test_run:cmd("switch default")
test_run:cmd("stop server replica")
listen = box.cfg.listen
box.cfg{listen = ''}
test_run:cmd("start server replica")
test_run:cmd("switch replica")
box.info.status -- running
test_run:cmd("switch default")
test_run:cmd("stop server replica")
test_run:cmd("cleanup server replica")
box.schema.user.revoke('guest', 'replication')
box.cfg{listen = listen}
