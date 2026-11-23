"""The public API through the framework's real extension proxy."""
import hashlib
import os
from pathlib import Path

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

from test_required_state import runtime


@pytest.mark.parametrize("runtime_type", [Lua54, LuaJIT], ids=["lua54", "luajit21"])
def test_api_through_framework_proxy(runtime_type):
    path = os.environ.get("UCP_FRAMEWORK_PROXIES")
    if not path:
        pytest.skip("Set UCP_FRAMEWORK_PROXIES to the pinned framework proxies.lua; CI requires it")
    source = Path(path).read_bytes().replace(b"\r\n", b"\n")
    assert hashlib.sha256(source).hexdigest() == (
        "461f2750b1ff5799096d51c456068e5a6010fa057187360d8bd1b67da787856a"
    )
    lua = runtime(runtime_type)
    lua.globals().framework_proxies = lua.execute(source.decode())
    lua.execute('''
      package.loaded['mapextensions.memory']={}
      package.loaded['mapextensions.callbacks']={}
      package.loaded['mapextensions.game']={getNativeSaveInterface=function()
        return {version=1,failureHandling=1,readContext=1} end}
      local api,metadata=dofile(root..'/init.lua')
      -- main.lua supplies this default when a module has no metadata.
      metadata=metadata or {public={},proxy={}}
      local owner=framework_proxies.ExtensionProxy(api,metadata.proxy)
      owner:registerSection('a',callbacks,
        {required=true,format='state-1',fingerprint=string.rep('a',64)})
      owner:registerSection('plain',callbacks)
      assert(required.providers.a and not required.providers.plain)
      assert(owner:requiredStateVersion()==1)
      assert(owner:requiredStateMapPolicyVersion()==1)
      local features=owner:getNativeSaveInterface()
      assert(features.failureHandling==1 and features.readContext==1)
      assert(not pcall(owner.registerSection,owner,'a',callbacks))
      -- For Recorder: plain copies through the proxy; editing them changes nothing.
      local integrity=owner:requiredStateIntegrity()
      assert(next(integrity)=='a' and integrity.a.digest=='state-digest-1')
      integrity.a.digest='edited'
      assert(owner:requiredStateIntegrity().a.digest=='state-digest-1')
      local contracts=owner:requiredStateContracts()
      contracts.a.format='edited'
      assert(owner:requiredStateContracts().a.format=='state-1')
      local captured=owner:captureRequiredSections()
      local count=0
      for name,data in pairs(captured) do
        assert(type(name)=='string' and type(data)=='string');count=count+1
      end
      assert(count==2 and captured['a/state.bin']=='saved')
      captured['a/state.bin']='edited'
      assert(owner:captureRequiredSections()['a/state.bin']=='saved')
      owner:observeRequiredStateBoundary()
      local boundary=owner:requiredStateBoundaryIntegrity()
      boundary.a.digest='edited'
      assert(owner:requiredStateBoundaryIntegrity().a.digest=='state-digest-1')
      assert(writes==0)
      registry.a.isRequired=function()return false end
      assert(next(owner:requiredStateIntegrity())==nil)
      assert(next(owner:requiredStateContracts())==nil)
    ''')
