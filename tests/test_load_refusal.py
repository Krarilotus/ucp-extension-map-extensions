"""The early refusal at the single-player Load action, and the bytes it patches in.

Multiplayer loads run inside a synchrony command: one peer returning to the menu
would leave the others loading, so they keep the fatal path. A file whose section
cannot be read is refused like a missing module, before the world is touched.
"""
import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

from test_native_hooks import lua_host

RUNTIMES = pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])

SETUP = """
status, menus, notices, progress, admitted = 1, 0, {}, 0x493690, 0
package.loaded['mapextensions.loadrefusal']={
  resolve=function() return 100, 200, 400 end, install=function() return 300 end,
  singlePlayer=require('mapextensions.loadrefusal').singlePlayer}
probeResult=function() return 'archive' end
package.loaded['mapextensions.archiveprobe']={resolveDecoder=function() end,
  read=function() return probeResult() end,
  openGameSave=function() return {close=function() return true end} end}
package.loaded['mapextensions.readcontext'].resolve=function()
  return {},function() return {kind='save'}, 'test.sav' end
end
package.loaded['mapextensions.loadmessage']=function(name, version) notices[#notices+1]=name or 'unreadable' end
switch=function() menus=menus+1 end
modules={ui={switchToMenu=function() return switch() end}}
core.readInteger=function(address)
  if address == 400 then return mode end
  return address == 300 and status or 200000
end
core.writeInteger=function(address,value)
  if address == 200000 + 0x20 then progress=value; return end
  assert(address == 300); status=value
end
missing=function() error({name='battle',version='1.2.3'},0) end
install({admit=function() admitted=admitted+1; missing() end,
  afterReadSav=function() missing() end,
  missingOwner=function(reason) if type(reason)=='table' then return reason.name, reason.version end end},true)
"""


@RUNTIMES
@pytest.mark.parametrize('mode', [0, 99])
def test_single_player_modes_refuse_a_missing_module_before_the_read(runtime, mode):
    lua = lua_host(runtime)
    lua.globals().mode = mode
    lua.execute(SETUP + """
      assert(hooks[1](200000,sections)==0)
      assert(admitted==1 and nativeCalls==0 and menus==1 and status==2 and progress==0)
      assert(notices[1]=='battle' and game.takeLoadRefusal()=='battle')
    """)


@RUNTIMES
@pytest.mark.parametrize('mode', [1, 2, 666])
def test_multiplayer_loads_keep_the_fatal_path(runtime, mode):
    lua = lua_host(runtime)
    lua.globals().mode = mode
    lua.execute(SETUP + """
      rps(hooks[1],200000,sections)
      assert(admitted==0, 'no early check outside the single-player Load case')
      assert(nativeCalls==1 and menus==0 and #notices==0 and status==1 and progress==0x493690)
      assert(levels():find('-3',1,true), 'FATAL as before: '..levels())
      assert(game.takeLoadRefusal()==nil)
    """)


@RUNTIMES
def test_an_unreadable_section_is_refused_with_the_generic_message(runtime):
    lua = lua_host(runtime)
    lua.globals().mode = 99
    lua.execute(SETUP + """
      probeResult=function() error('Save section checksum does not match') end
      assert(hooks[1](200000,sections)==0)
      assert(admitted==0 and nativeCalls==0 and menus==1 and status==2 and progress==0)
      assert(notices[1]=='unreadable' and game.takeLoadRefusal()=='map-extensions')
      assert(messages[1].text:find('unreadable save before native read',1,true))
      assert(messages[1].text:find('checksum',1,true))
    """)


@RUNTIMES
def test_a_failing_menu_switch_still_refuses(runtime):
    lua = lua_host(runtime)
    lua.globals().mode = 0
    lua.execute(SETUP + """
      switch=function() error('menu owner unavailable') end
      assert(hooks[1](200000,sections)==0)
      assert(nativeCalls==0 and status==2 and progress==0 and notices[1]=='battle')
      assert(levels()=='-2,-1', levels())
      assert(messages[1].text:find('menu owner unavailable',1,true))
    """)


def test_resolve_reads_the_game_mode_from_the_verified_load_case():
    lua = lua_host(Lua54)
    lua.execute("""
      local bytes={}
      local function put(address, list) for i,b in ipairs(list) do bytes[address+i-1]=b end end
      local function int(address, value)
        for i=0,3 do bytes[address+i]=(value >> (8*i)) & 0xff end
      end
      local call, mode = 0x495594, 0x4953c9
      -- The game-mode branch: mov eax,[0x191dd80]; cmp eax,ebx; je sp; cmp eax,0x63; je sp
      put(mode, {0xA1}); int(mode+1, 0x191dd80)
      put(mode+5, {0x3B,0xC3,0x0F,0x84}); int(mode+9, 0xAA)
      put(mode+13, {0x83,0xF8,0x63,0x0F,0x84}); int(mode+18, 0xA1)
      put(call, {0xE8}); int(call+1, 0x474a20 - call - 5)
      core.readInteger=function(address)
        local v=0; for i=3,0,-1 do v=(v << 8) | (bytes[address+i] or 0) end
        return v >= 0x80000000 and v - 0x100000000 or v
      end
      core.AOBScan=function(pattern, from, to)
        if pattern:sub(1,2)=='6A' then return call - 32 end
        if pattern:sub(1,2)=='5F' then assert(from==call+5 and to==call+0x300); return 0x4957d2 end
        assert(pattern=='A1 ? ? ? ? 3B C3 0F 84 ? ? ? ? 83 F8 63 0F 84' and from==call-0x300 and to==call)
        return mode
      end
      int(call-32+13, 0xb92a58); int(call-32+18, 0xf2b3d0); int(call-32+24, 0xf2b3d0+0x20)
      local refusal=require('mapextensions.loadrefusal')
      local site, cleanup, gameMode=refusal.resolve(0x474a20, 0xb92a58, 0xf2b3d0)
      assert(site==call and cleanup==0x4957d2 and gameMode==0x191dd80)
      for value, single in pairs({[0]=true,[99]=true,[1]=false,[2]=false,[666]=false}) do
        int(0x191dd80, value); assert(refusal.singlePlayer(0x191dd80)==single, value)
      end
      -- The two branches must reach the same single-player path.
      int(mode+18, 0xA2)
      assert(not pcall(refusal.resolve, 0x474a20, 0xb92a58, 0xf2b3d0))
    """)


def test_install_emits_the_reviewed_bytes():
    lua = lua_host(Lua54)
    lua.execute("""
      local written, inserted = {}, nil
      core.allocate=function(size, zero) assert(size==4 and zero); return 0x11223344 end
      core.writeInteger=function(address, value) written[address]=value end
      core.callTo=function(target) return {lambda='call', target=target} end
      core.jmpTo=function(target) return {lambda='jmp', target=target} end
      core.insertCode=function(address, size, code, original)
        assert(address==0x495594 and size==5 and original==nil, 'the original call must not be replayed')
        inserted=code
      end
      utils.itob=function(value)
        return {value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff}
      end
      local status=require('mapextensions.loadrefusal').install(0x495594, 0x4957d2, 0x474a20)
      assert(status==0x11223344 and written[status]==0)
      local flat={}
      local function walk(code)
        for _, item in ipairs(code) do
          if type(item)=='table' and item.lambda then
            flat[#flat+1]=item.lambda..':'..string.format('%x', item.target)
          elseif type(item)=='table' then walk(item)
          else flat[#flat+1]=string.format('%02X', item) end
        end
      end
      walk(inserted)
      local s='44 33 22 11'
      local expected=table.concat({'C7 05', s, '01 00 00 00', 'call:474a20', '83 3D', s, '02',
        'C7 05', s, '00 00 00 00', '75 05', 'jmp:4957d2'}, ' ')
      assert(table.concat(flat,' ')==expected, table.concat(flat,' '))
    """)
