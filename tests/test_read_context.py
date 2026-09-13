"""Native filename context uses the reader's existing binding, including overrides."""
from pathlib import Path
import struct

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_filename_binding_is_derived_once_and_calls_the_shared_entry(runtime):
    lua = runtime(unpack_returned_tuples=True)
    g = lua.globals()
    g.root = ROOT.as_posix()
    reader, entry, resources = 0x23000000, 0x18000000, 0x30000000
    site = reader + 0x44
    memory = {}
    caller = bytes.fromhex('55 57 B9 00 00 00 00 E8 00 00 00 00 53 68 00 80 00 00 50 E8 00 00 00 00 8B F8 83 CD FF 83 C4 0C 3B FD')
    leaf = bytes.fromhex('8B 81 C4 0B 00 00 69 C0 E9 03 00 00 8D 84 08 E0 AE 07 00 C3')
    for address, data in ((site, caller), (entry, leaf),
                          (site+3, struct.pack('<I', resources)),
                          (site+8, struct.pack('<i', entry-site-12))):
        memory.update({address+i: b for i, b in enumerate(data)})
    g.read_byte = lambda a: memory[a]
    g.read_int = lambda a: struct.unpack('<i', bytes(memory[a+i] for i in range(4)))[0]
    g.read_string = lambda a, n: bytes(memory[a+i] for i in range(n))
    lua.execute('''
package.path=root..'/?.lua;'..package.path
local exposed=0
path='Maps/Green Haven.MAP'
core={readByte=read_byte,readInteger=read_int,
 readString=function(a,n) if a==0x40000000 then return path end;return read_string(a,n) end,
 exposeCode=function(a,count,convention)
  assert(a==0x18000000 and count==1 and convention==7);exposed=exposed+1
  return function(this) assert(this==0x30000000);return 0x40000000 end
 end,
 AOBScan=function()error('No second scan')end,hookCode=function()error('No extra hook')end}
CallingConvention={THISCALL=7}
resolver=require('mapextensions.readcontext')
local binding,capture=resolver.resolve(0x23000000)
assert(binding.resources==0x30000000 and binding.resourceFileName==0x18000000)
assert(#binding.resourceFileNameBytes==20 and capture().kind=='map')
-- Recorder can redirect the same entry after Map resolves it.
path='ucp/.cache/recorder/snapshot.sav';assert(capture().kind=='save')
path='unknown';assert(capture().kind=='save')
path='map.sav';assert(capture().kind=='save')
for i=1,100 do capture() end
assert(exposed==1)
''')
    for address in (site, site+3, site+8, entry+14):
        original = memory[address]
        memory[address] ^= 0xff
        # Resource operands remain valid pointers if one low byte changes;
        # use an invalid range to test the operand, not an arbitrary relocation.
        if address == site+3:
            saved = bytes(memory[site+3+i] for i in range(4))
            for i in range(4): memory[site+3+i] = 0
        lua.execute('assert(not pcall(resolver.resolve,0x23000000))')
        if address == site+3:
            for i,b in enumerate(saved): memory[site+3+i] = b
        memory[address] = original


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
@pytest.mark.parametrize('archive', [False, True], ids=['native-only', 'custom-section'])
def test_context_reaches_validation_before_initialization_or_restore(runtime, archive):
    from test_required_state import runtime as fixture
    lua = fixture(runtime)
    lua.globals().archive = archive
    lua.execute('''
local initialized,restored=0,0
local entries={}
local mapMemory={customSectionInfoObject={size=archive and 100 or 0}}
package.loaded['mapextensions.memory']=mapMemory
package.loaded['mapextensions.game']={}
package.loaded['luamemzip.dll']={MemoryZip=function()
 local handle=zip(entries);handle.close=function()end;return handle
end}
core={readString=function()return 'archive bytes' end}
io.open=function()return {write=function()end,close=function()end} end
callbacks.validate=function(_,handle)
 validates=validates+1
 assert(handle.loadKind=='map','Missing state in a save')
end
callbacks.initialize=function(_,context)
 assert(context.kind=='map' and validates==1);initialized=initialized+1
end
callbacks.deserialize=function(_,handle)
 assert(handle.loadKind=='map' and validates==1);restored=restored+1
end
register('a')
local owner=require('mapextensions.callbacks')
for _,context in ipairs({{}, {kind='save'}}) do
 assert(not pcall(owner.afterReadSav,context))
 assert(initialized==0 and restored==0)
end
validates=0
owner.afterReadSav({kind='map'})
assert(initialized==(archive and 0 or 1) and restored==(archive and 1 or 0))
''')
