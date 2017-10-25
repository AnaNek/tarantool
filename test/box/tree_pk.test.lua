utils = dofile('utils.lua')

s0 = box.schema.space.create('tweedledum')
i0 = s0:create_index('primary', { type = 'tree', parts = {1, 'unsigned'}, unique = true })

bsize = i0:bsize()

-- integer keys
s0:insert{1, 'tuple'}
box.snapshot()
s0:insert{2, 'tuple 2'}
box.snapshot()

i0:bsize() > bsize

s0:insert{3, 'tuple 3'}
s0.index['primary']:get{1}
s0.index['primary']:get{2}
s0.index['primary']:get{3}

-- Cleanup
s0:delete{1}
s0:delete{2}
s0:delete{3}

-- Test incorrect keys - supplied key field type does not match index type
-- https://bugs.launchpad.net/tarantool/+bug/1072624
s0:insert{'xxxxxxx'}
s0:insert{''}
s0:insert{'12'}

s1 = box.schema.space.create('tweedledee')
i1 = s1:create_index('primary', { type = 'tree', parts = {1, 'string'}, unique = true })

s2 = box.schema.space.create('alice')
i2 = s2:create_index('primary', { type = 'tree', parts = {1, 'string'}, unique = true })

-- string keys
s1:insert{'identifier', 'tuple'}
box.snapshot()
s1:insert{'second', 'tuple 2'}
box.snapshot()
s1.index['primary']:select('second', { limit = 100, iterator = 'GE' })
s1.index['primary']:select('identifier', { limit = 100, iterator = 'GE' })

s1:insert{'third', 'tuple 3'}
s1.index['primary']:get{'identifier'}
s1.index['primary']:get{'second'}
s1.index['primary']:get{'third'}

-- Cleanup
s1:delete{'identifier'}
s1:delete{'second'}
s1:delete{'third'}
env = require('test_run')
test_run = env.new()

test_run:cmd("setopt delimiter ';'")
function crossjoin(space0, space1, limit)
    local result = {}
    for state, v0 in space0:pairs() do
        for state, v1 in space1:pairs() do
            if limit <= 0 then
                return result
            end
            local newtuple = v0:totable()
            for _, v in v1:pairs() do
                table.insert(newtuple, v)
            end
            table.insert(result, box.tuple.new(newtuple))
            limit = limit - 1
        end
    end
    return result
end;
test_run:cmd("setopt delimiter ''");

s2:insert{'1', 'tuple'}
s1:insert{'1', 'tuple'}
s1:insert{'2', 'tuple'}

crossjoin(s1, s1, 0)
crossjoin(s1, s1, 5)
crossjoin(s1, s1, 10000)
crossjoin(s1, s2, 10000)
s1:truncate()
s2:truncate()

-- Bug #922520 - select missing keys
s0:insert{200, 'select me!'}
s0.index['primary']:get{200}
s0.index['primary']:get{199}
s0.index['primary']:get{201}

s1:drop()
s1 = nil
s2:drop()
s2 = nil

--
-- tree::replace tests
--
s0:truncate()

i1 = s0:create_index('i1', { type = 'tree', parts = {2, 'unsigned'}, unique = true })
i2 = s0:create_index('i2', { type = 'tree', parts = {3, 'unsigned'}, unique = false })
i3 = s0:create_index('i3', { type = 'tree', parts = {4, 'unsigned'}, unique = true })

s0:insert{0, 0, 0, 0}
s0:insert{1, 1, 1, 1}
s0:insert{2, 2, 2, 2}

-- OK
s0:replace{1, 1, 1, 1}
s0:replace{1, 10, 10, 10}
s0:replace{1, 1, 1, 1}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['primary']:get{1}
s0.index['i1']:select{1}
s0.index['i2']:select{1}
s0.index['i3']:select{1}

-- OK
s0:insert{10, 10, 10, 10}
s0:delete{10}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}


-- TupleFound (primary key)
s0:insert{1, 10, 10, 10}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['primary']:get{1}

-- TupleNotFound (primary key)
s0:replace{10, 10, 10, 10}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}

-- TupleFound (key #1)
s0:insert{10, 0, 10, 10}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['i1']:select{0}

-- TupleFound (key #1)
s0:replace{2, 0, 10, 10}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['i1']:select{0}

-- TupleFound (key #3)
s0:insert{10, 10, 10, 0}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['i3']:select{0}

-- TupleFound (key #3)
s0:replace{2, 10, 10, 0}
s0.index['primary']:get{10}
s0.index['i1']:select{10}
s0.index['i2']:select{10}
s0.index['i3']:select{10}
s0.index['i3']:select{0}

-- Non-Uniq test (key #2)
s0:insert{4, 4, 0, 4}
s0:insert{5, 5, 0, 5}
s0:insert{6, 6, 0, 6}
s0:replace{5, 5, 0, 5}
utils.sort(s0.index['i2']:select(0))
s0:delete{5}
utils.sort(s0.index['i2']:select(0))

s0:drop()
s0 = nil

-- Stable non-unique indexes
-- https://github.com/tarantool/tarantool/issues/2476
s = box.schema.space.create('test')
i1 = s:create_index('i1', { type = 'tree', parts = {1, 'unsigned'}, unique = true })
i2 = s:create_index('i2', { type = 'tree', parts = {2, 'unsigned'}, unique = false })
s:replace{5, 1, 1}
s:replace{4, 1, 3}
s:replace{6, 1, 2}
s:replace{3, 1, 0}
s:replace{7, 1, 100}
s:replace{15, 2, 11}
s:replace{14, 2, 41}
s:replace{16, 2, 31}
s:replace{13, 2, 13}
s:replace{17, 2, 10}
i2:select{1}
i2:select{2}
i2:select{1, 5}

i1:alter{parts = {3, 'unsigned'}}
i2:select{1}
i2:select{2}
i2:select{1, 1}

s:truncate()
i1:alter{parts = {1, 'str'}}
s:replace{"5", 1}
s:replace{"4", 1}
s:replace{"6", 1}
s:replace{"3", 1}
s:replace{"7", 1}
s:replace{"15", 2}
s:replace{"14", 2}
s:replace{"16", 2}
s:replace{"13", 2}
s:replace{"17", 2}
i2:select{1}
i2:select{2}

s:drop()

--https://github.com/tarantool/tarantool/issues/2649
-- create standart index and alter it to collation index
box.internal.collation.create('test', 'ICU', 'ru-RU')
box.internal.collation.create('test-ci', 'ICU', 'ru-RU', {strength = 'secondary'})
s = box.schema.space.create('test')
i1 = s:create_index('i1', { type = 'tree', parts = {{1, 'str'}}, unique = true })

_ = s:replace{"ааа"}
_ = s:replace{"еее"}
_ = s:replace{"ёёё"}
_ = s:replace{"жжж"}
_ = s:replace{"яяя"}
_ = s:replace{"ААА"}
_ = s:replace{"ЯЯЯ"}

-- bad output
s:select{}

i1:alter({parts = {{1, 'str', collation='test'}}})

-- good output
s:select{}

i1:alter({parts = {{1, 'str', collation='test-ci'}}})

_ = s:delete{"ААА"}
_ = s:delete{"ЯЯЯ"}

i1:alter({parts = {{1, 'str', collation='test-ci'}}})

-- good output
s:select{}

s:insert{"ААА"}
s:replace{"ЯЯЯ"}

-- good output
s:select{}

s:drop()

-- create collation index and alter it to standart index
s = box.schema.space.create('test')
i1 = s:create_index('i1', { type = 'tree', parts = {{1, 'str', collation='test'}}, unique = true })

_ = s:replace{"ааа"}
_ = s:replace{"еее"}
_ = s:replace{"ёёё"}
_ = s:replace{"жжж"}
_ = s:replace{"яяя"}
_ = s:replace{"ААА"}
_ = s:replace{"ЯЯЯ"}

-- good output
s:select{}

i1:alter({parts = {{1, 'str'}}})

-- bad output
s:select{}

s:drop()

box.internal.collation.drop('test')
box.internal.collation.drop('test-ci')

-- hints
s = box.schema.space.create('test')
s:create_index('test', {type = 'tree', hint = 'true'} )
s:create_index('test', {type = 'hash', hint = true} )
s:create_index('test', {type = 'hash'}):alter({hint = true})
s:drop()

s = box.schema.space.create('test', {engine = 'vinyl'})
s:create_index('test', {type = 'tree', hint = true} )
s:drop()

-- numeric hints
s1 = box.schema.space.create('test1')
s1:create_index('test', {type = 'tree', hint = false}).hint
s2 = box.schema.space.create('test2')
s2:create_index('test', {type = 'tree', hint = true}).hint

N = 2000
for i = 1,N do local v = math.random(10 * N) s1:replace{v} s2:replace{v} end
s1:count() == s2:count()

good = true r1 = s1:select{} r2 = s2:select{}
if #r1 ~= #r2 then good = false end
for k,v in pairs(r1) do if r2[k][1] ~= v[1] then good = false end end
good
r1 = nil r2 = nil

function diff(t1, t2) if t1 then return t1[1] ~= t2[1] else return t2 ~= nil end end
for i = 1, N * 10 do if diff(s1:get{i}, s2:get{i}) then good = false end end
good

s1:drop()
s2:drop()

-- string hints
s1 = box.schema.space.create('test1')
s1:create_index('test', {type = 'tree', parts = {1, 'str'}, hint = false}).hint
s2 = box.schema.space.create('test2')
s2:create_index('test', {type = 'tree', parts = {1, 'str'}, hint = true}).hint

N = 1000
for i = 1,N do local v = ''..math.random(10 * N) s1:replace{v} s2:replace{v} end
s1:count() == s2:count()

good = true r1 = s1:select{} r2 = s2:select{}
if #r1 ~= #r2 then good = false end
for k,v in pairs(r1) do if r2[k][1] ~= v[1] then good = false end end
good
r1 = nil r2 = nil

function diff(t1, t2) if t1 then return t1[1] ~= t2[1] else return t2 ~= nil end end
for i = 1, N * 10 do v = ''..i if diff(s1:get{v}, s2:get{v}) then good = false end end
good

s1:drop()
s2:drop()

-- string with collation hints
s1 = box.schema.space.create('test1')
s1:create_index('test', {type = 'tree', parts = {{1, 'str', collation = 'unicode_s1'}}, hint = false}).hint
s2 = box.schema.space.create('test2')
s2:create_index('test', {type = 'tree', parts = {{1, 'str', collation = 'unicode_s1'}}, hint = true}).hint

N = 500
syms = {'a', 'B', 'c', 'D', 'ж', 'Ё', '~', '1', '%', '2'}
syms_size = #syms
len = 20
vals = {}
for i = 1,2*N do str = '' for j=1,len do str = str .. syms[math.random(syms_size)] end vals[i] = str end

for i = 1,N do local v = vals[i] s1:replace{v} s2:replace{v} end
s1:count() == s2:count()

good = true r1 = s1:select{} r2 = s2:select{}
if #r1 ~= #r2 then good = false end
for k,v in pairs(r1) do if r2[k][1] ~= v[1] then good = false end end
good
r1 = nil r2 = nil

function diff(t1, t2) if t1 then return t1[1] ~= t2[1] else return t2 ~= nil end end
for i = 1, N * 2 do v = vals[i] if diff(s1:get{v}, s2:get{v}) then good = false end end
good

s1:drop()
s2:drop()
