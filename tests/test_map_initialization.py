"""Opted-in saved battle state must not lock or leak into editable .map scenarios."""
import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT
from test_required_state import runtime


@pytest.mark.parametrize('runtime_type', [Lua54, LuaJIT])
def test_map_policy_missing_changed_provider_and_save_admission(runtime_type):
    lua = runtime(runtime_type)
    lua.execute('''
      local function add(name, policy)
        required.register(name,callbacks,{required=true,format='state-1',
          fingerprint=string.rep('a',64),initializeOnMap=policy})
        registry[name]=callbacks
      end
      add('tunnelers',true)
      local entries=required.capture()
      assert(entries['framework/required-state.yml']:find('initializeOnMap: true',1,true))
      -- Only .map opts out: saves, autosaves and replay .sav snapshots stay strict.
      required.validate(zip(entries),{kind='save'})
      assert(validates==1)
      entries['tunnelers/state.bin']='stale battle data'
      required.validate(zip(entries),{kind='map'})
      assert(validates==1)
      assert(not pcall(required.validate,zip(entries),{kind='save'}))
      required.providers.tunnelers.fingerprint=string.rep('b',64)
      required.validate(zip(entries),{kind='map'})
      assert(not pcall(required.validate,zip(entries),{kind='save'}))
      registry.tunnelers=nil;required.providers.tunnelers=nil
      required.validate(zip(entries),{kind='map'})
      assert(not pcall(required.validate,zip(entries),{kind='save'}))
      -- Existing providers keep their previous contract, including on .map.
      add('legacy',nil)
      entries=required.capture();registry.legacy=nil;required.providers.legacy=nil
      assert(not pcall(required.validate,zip(entries),{kind='map'}))
      assert(not pcall(add,'invalid','yes'))
    ''')


@pytest.mark.parametrize('runtime_type', [Lua54, LuaJIT])
def test_map_initializes_instead_of_restoring_and_editor_save_roundtrip(runtime_type):
    lua = runtime(runtime_type)
    lua.execute('''
      local world,initialized,restored=99,0,0
      callbacks.initialize=function(_,context)
        assert(context.kind=='map');world=0;initialized=initialized+1
      end
      callbacks.deserialize=function(_,handle)
        assert(handle.loadKind=='save');world=tonumber(handle:get('state.bin'));restored=restored+1
      end
      callbacks.validate=function(_,handle) assert(tonumber(handle:get('state.bin'))) end
      callbacks.capture=function(_,handle) handle:put('state.bin',tostring(world)) end
      callbacks.serialize=callbacks.capture
      required.register('tunnelers',callbacks,{required=true,format='state-1',
        fingerprint=string.rep('a',64),initializeOnMap=true})
      registry.tunnelers=callbacks
      local entries=required.capture()
      package.loaded['mapextensions.memory']={customSectionInfoObject={size=100}}
      package.loaded['mapextensions.game']={}
      package.loaded['luamemzip.dll']={MemoryZip=function()
        local handle=zip(entries);handle.close=function()end;return handle
      end}
      core={readString=function()return 'archive bytes' end}
      io.open=function()return {write=function()end,close=function()end} end
      local owner=require('mapextensions.callbacks')
      owner.afterReadSav({kind='save'});assert(world==99 and restored==1)
      owner.afterReadSav({kind='map'});assert(world==0 and initialized==1 and restored==1)
      -- Editing/re-saving a map carries fresh state; reopening still initializes.
      entries=required.capture()
      world=20;owner.afterReadSav({kind='map'});assert(world==0 and initialized==2)
      -- A new game's save keeps its newly accumulated state.
      world=7;entries=required.capture();world=9
      owner.afterReadSav({kind='save'});assert(world==7 and restored==2)
    ''')
