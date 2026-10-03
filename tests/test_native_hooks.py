"""What the game sees when a load or a save goes wrong inside Map Extensions.

Stock RPS catches a Lua error in a hook and returns 0 to the game. A load would then
carry on with part of the file applied; a save would be silently skipped.
"""
from pathlib import Path

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[1]

HOST = '''
package.path=root..'/?.lua;'..package.path
FATAL,ERROR,WARNING=-3,-2,-1
messages={}
log=function(level,message)
  if level<=WARNING then messages[#messages+1]={level=level,text=message} end
  if level==FATAL then error('PROCESS_STOPPED') end
end
local address=100000
hooks={}
nativeCalls=0
core={AOBScan=function() address=address+100;return address end,
  readInteger=function()return 200000 end,
  readString=function()return '' end,
  hookCode=function(callback,site,count,convention,size)
    assert(count==2 and convention==1 and size==5)
    hooks[#hooks+1]=callback
    return function() nativeCalls=nativeCalls+1;return 123 end
  end,
  detourCode=function(callback,site,size) assert(size==7);directory=callback end}
utils={unpack=function()return {} end}
CallingConvention={THISCALL=1}
package.loaded['mapextensions.readcontext']={resolve=function()
  return {},function() return {kind='save'} end
end}
game=require('mapextensions.game')
function install(callbacks)
  for _,name in ipairs({'beforeReadSav','afterReadSav','beforeWriteSav','afterWriteSav',
      'afterReadDirectoryOfSav'}) do callbacks[name]=callbacks[name] or function() end end
  game.registerReadWriteSavHooks(300000,1337,callbacks)
  sections=100100 -- the first scan: the game's own section table
end
-- RPS: a Lua error in a hook becomes a 0 return to the game.
function rps(callback,...)
  local ok,value=pcall(callback,...)
  return ok and value or 0
end
function levels()
  local result={}
  for _,m in ipairs(messages) do result[#result+1]=m.level end
  return table.concat(result,',')
end
'''


def lua_host(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute(HOST)
    return lua


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
@pytest.mark.parametrize('stage', ['beforeReadSav', 'afterReadSav', 'afterReadDirectoryOfSav', 'wrongSections'])
def test_a_failed_load_stops_the_game(runtime, stage):
    lua = lua_host(runtime)
    lua.globals().stage = stage
    lua.execute('''
      local callbacks={}
      if stage~='wrongSections' then callbacks[stage]=function() error('injected '..stage) end end
      install(callbacks)
      if stage=='afterReadDirectoryOfSav' then rps(directory,{})
      else rps(hooks[1],200000,stage=='wrongSections' and 1 or sections) end
      assert(levels()=='-1,-3','expected the details, then FATAL: '..levels())
      local dialog=messages[2].text
      assert(dialog:find('could not be loaded',1,true))
      assert(dialog:find(stage=='wrongSections' and 'argument' or 'injected',1,true))
      assert(not dialog:find('stack traceback',1,true) and not dialog:find('[string',1,true))
      assert(messages[1].text:find('stack traceback',1,true),'full details go to the log')
      assert(nativeCalls==(stage=='afterReadSav' and 1 or 0))
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
@pytest.mark.parametrize('stage', ['beforeWriteSav', 'wrongSections'])
def test_a_failed_save_is_not_written_and_the_match_continues(runtime, stage):
    lua = lua_host(runtime)
    lua.globals().stage = stage
    lua.execute('''
      local callbacks={}
      if stage=='beforeWriteSav' then callbacks.beforeWriteSav=function() error('injected save') end end
      install(callbacks)
      local result=hooks[2](200000,stage=='wrongSections' and 1 or sections)
      assert(result==0 and nativeCalls==0,'the game must not write the file')
      assert(levels()=='-1,-2','expected the details, then an error message: '..levels())
      local dialog=messages[2].text
      assert(dialog:find('was not saved',1,true) and dialog:find('match continues',1,true))
      assert(dialog:find(stage=='wrongSections' and 'argument' or 'injected save',1,true))
      -- The next save works again.
      callbacks.beforeWriteSav=function() end
      assert(hooks[2](200000,sections)==123 and nativeCalls==1)
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_a_problem_after_writing_keeps_the_saved_file(runtime):
    lua = lua_host(runtime)
    lua.execute('''
      install({afterWriteSav=function() error('injected after') end})
      assert(hooks[2](200000,sections)==123 and nativeCalls==1)
      assert(levels()=='-1')
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_successful_load_and_save_pass_the_file_kind(runtime):
    lua = lua_host(runtime)
    lua.execute('''
      local seen={}
      install({beforeReadSav=function(context) seen[#seen+1]=context.kind end,
        afterReadSav=function(context) seen[#seen+1]=context.kind end})
      assert(not pcall(game.registerReadWriteSavHooks,300000,1337,{}),'hooks are installed once')
      assert(hooks[1](200000,sections)==123 and hooks[2](200000,sections)==123)
      assert(table.concat(seen,',')=='save,save' and nativeCalls==2 and #messages==0)
      local features=game.getNativeSaveInterface()
      assert(features.version==1 and features.failureHandling==1 and features.readContext==1)
      -- Recorder gets the same addresses the hooks use: no scans of its own.
      assert(features.sections==sections and features.readWorld==100200 and features.writeWorld==100300)
      assert(features.packager==200000 and features.sectionCount==122 and features.descriptorSize==16)
      features.sections=1; assert(game.getNativeSaveInterface().sections==sections,'a copy each time')
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_dialog_reason_omits_framework_file_positions(runtime):
    lua = lua_host(runtime)
    lua.execute('''
      -- The framework loads module files as '@<path>' chunks. A module's assert is
      -- rethrown by Map Extensions' own assert, so both add a 'file.lua:line:' prefix.
      local module=load("assert(false, 'Module: short reason')", '@ucp/modules/module-1.0.0/state.lua')
      local owner=load([[local module=...
        return {afterReadSav=function()
          local ok,reason=xpcall(module,debug.traceback);assert(ok,reason)
        end}]], '@ucp/modules/map-extensions-1.2.0/mapextensions/callbacks.lua')(module)
      install(owner)
      rps(hooks[1],200000,sections)
      local lines={}
      for line in messages[2].text:gmatch('[^%c]+') do lines[#lines+1]=line end
      assert(lines[2]=='Module: short reason','dialog line: '..tostring(lines[2]))
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_buffer_sizes_are_found_inside_the_save_functions(runtime):
    lua = lua_host(runtime)
    lua.execute('''
      -- readWorld and writeWorld are the second and third scans (100200, 100300).
      local code={}
      local function put(at,hex) for b in hex:gmatch('%x%x') do code[at]=tonumber(b,16);at=at+1 end end
      put(100200+0x0C,'68 00 00 00 00 89 44 24 14')
      put(100300+0x13,'68 00 00 00 00 89 44 24 1C')
      local written={}
      core.readByte=function(a) return code[a] or 0 end
      core.writeCodeInteger=function(a,v) written[#written+1]=a..'='..v end
      game.enlargeMemoryAllocation(128000000)
      assert(table.concat(written,' ')=='100213=128000000 100320=128000000')
      code[100300+0x13+8]=0x20 -- another game version: refuse instead of patching
      assert(not pcall(game.enlargeMemoryAllocation,128000000))
    ''')
