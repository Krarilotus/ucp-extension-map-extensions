"""The exported interface retains the owner's existing wrapped save entries."""
import os
from pathlib import Path

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[1]


@pytest.mark.parametrize('runtime',[Lua54,LuaJIT],ids=['lua54','luajit21'])
def test_save_interface_uses_installed_wrappers_without_new_hooks_or_scans(runtime):
    proxy_path=os.environ.get('UCP_FRAMEWORK_PROXIES')
    if not proxy_path:
        pytest.skip('Set UCP_FRAMEWORK_PROXIES to the framework implementation; required by CI')
    lua=runtime(unpack_returned_tuples=True)
    lua.globals().root=ROOT.as_posix()
    lua.globals().proxies=lua.execute(Path(proxy_path).read_text(encoding='utf-8'))
    lua.execute('''
package.path=root..'/?.lua;'..package.path
local scans,hookCount=0,0
local resolved,wrapped={},{}
local nextAddress=0x30000000
core={AOBScan=function(pattern)
 scans=scans+1; assert(not resolved[pattern],'duplicate owner resolution')
 nextAddress=nextAddress+0x1000; resolved[pattern]=nextAddress;return nextAddress
end,readInteger=function() return 0x40000000 end,
hookCode=function(callback,address,count,convention,size)
 assert(count==2 and convention==1 and size==5)
 hookCount=hookCount+1;wrapped[address]=callback
 return function(this,sections)
  assert(this==0x40000000 and sections==0x50000000)
  return 123
 end
end,detourCode=function(_,_,size) assert(size==7);hookCount=hookCount+1 end}
CallingConvention={THISCALL=1}; log=function() end
local game=require('mapextensions.game')
assert(not pcall(game.getNativeSaveInterface))
local calls={}
local callbacks={}
for _,name in ipairs({'beforeReadSav','afterReadSav','beforeWriteSav','afterWriteSav'}) do
 local label=name;callbacks[label]=function() calls[#calls+1]=label end
end
game.registerReadWriteSavHooks(0x50000000,123,callbacks)
assert(hookCount==3)
local installedScans=scans
local native=game.getNativeSaveInterface()
assert(native.version==1 and native.packager==0x40000000)
assert(native.sectionCount==122 and native.descriptorSize==16)
assert(native.readWorld==resolved['83 EC 0C 53 56 8B F1 8B 46 20'])
assert(native.writeWorld==resolved['83 EC 10 53 55 56 8B F1 8B 46 20'])
assert(wrapped[native.readWorld](native.packager,native.sections)==123)
assert(table.concat(calls,',')=='beforeReadSav,afterReadSav')
assert(wrapped[native.writeWorld](native.packager,native.sections)==123)
assert(table.concat(calls,',')=='beforeReadSav,afterReadSav,beforeWriteSav,afterWriteSav')
assert(not pcall(wrapped[native.readWorld],native.packager,123) and #calls==4)
native.sections=123
assert(game.getNativeSaveInterface().sections~=123)
-- Exercise the real module API and framework proxy; the memory/callback modules
-- are unrelated startup dependencies and do not perform I/O in this fixture.
package.loaded['mapextensions.memory']={}
package.loaded['mapextensions.callbacks']={}
package.loaded['mapextensions.registry']={registry={}}
local api,metadata=dofile(root..'/init.lua')
local owner=proxies.ExtensionProxy(api,metadata.proxy)
local exported=owner:getNativeSaveInterface()
assert(exported.version==1 and exported.readWorld==native.readWorld)
assert(exported.sections==game.getNativeSaveInterface().sections)
assert(scans==installedScans and hookCount==3)
assert(not pcall(game.registerReadWriteSavHooks,0x50000000,123,callbacks))
assert(scans==installedScans and hookCount==3)
''')
