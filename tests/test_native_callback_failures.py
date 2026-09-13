"""A native RPS callback error must not become a successful outer load/save."""
from pathlib import Path

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
@pytest.mark.parametrize('stage', ['beforeReadSav', 'afterReadSav', 'beforeWriteSav',
                                  'afterWriteSav', 'afterReadDirectoryOfSav', 'wrongSections'])
def test_native_failure_uses_framework_fatal_path(runtime, stage):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root, lua.globals().stage = ROOT.as_posix(), stage
    lua.execute('''
      package.path=root..'/?.lua;'..package.path
      FATAL=-3; WARNING=-1; fatalMessage=nil; details=nil; nativeCalls=0
      log=function(level,message)
        if level==WARNING then details=message end
        if level==FATAL then fatalMessage=message;error('PROCESS_STOPPED') end
      end
      local address=100000
      local hooks={}
      core={AOBScan=function() address=address+100;return address end,
        readInteger=function()return 200000 end,
        readString=function()return '' end,
        hookCode=function(callback,site)
          hooks[#hooks+1]=callback
          return function() nativeCalls=nativeCalls+1;return 123 end
        end,
        detourCode=function(callback) directory=callback end}
      utils={unpack=function()return {} end}
      CallingConvention={THISCALL=1}
      local callbacks={}
      for _,name in ipairs({'beforeReadSav','afterReadSav','beforeWriteSav',
          'afterWriteSav','afterReadDirectoryOfSav'}) do
        local label=name
        callbacks[label]=function() if stage==label then error('injected '..label) end end
      end
      local game=require('mapextensions.game')
      game.registerReadWriteSavHooks(300000,1337,callbacks)
      local interface=game.getNativeSaveInterface()
      -- Stock RPS catches a Lua error and returns zero to native code. Only the
      -- framework fatal logger stops the process instead of continuing the load.
      local function rps(callback,...)
        local ok,value=pcall(callback,...)
        return ok and value or 0
      end
      if stage=='afterReadDirectoryOfSav' then rps(directory,{})
      elseif stage:find('Write') then rps(hooks[2],200000,interface.sections)
      else rps(hooks[1],200000,stage=='wrongSections' and 1 or interface.sections) end
      assert(fatalMessage and fatalMessage:find('Map Extensions',1,true),
        'Native callback failures must reach the framework fatal logger')
      assert(fatalMessage:find(stage=='wrongSections' and 'argument' or 'injected',1,true))
      assert(not fatalMessage:find('stack traceback',1,true) and not fatalMessage:find('[string',1,true))
      assert(details and details:find('stack traceback',1,true),'Keep full diagnostic detail in the log')
      local expected=(stage=='afterReadSav' or stage=='afterWriteSav') and 1 or 0
      assert(nativeCalls==expected,'No native operation may run after its admission callback fails')
    ''')
