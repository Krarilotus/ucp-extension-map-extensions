"""Save/load callbacks with large data, a failing debug copy and repeated entry checks.

Runs the real callbacks.lua and handles.lua; the zip library, game memory and native
hooks are replaced by small Lua stand-ins. No game is started.
"""
from pathlib import Path

import pytest
from lupa.lua54 import LuaRuntime as Lua54
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[1]

HOST = '''
package.path = root..'/?.lua;'..package.path
VERBOSE, DEBUG, WARNING = 2, 1, -1
warnings = {}
log = function(level, message) if level == WARNING then warnings[#warnings + 1] = message end end
memory = {customSectionAddress = 0x1000, customSectionInfoObject = {size = 0}}
package.loaded['mapextensions.memory'] = memory
package.loaded['mapextensions.game'] = {updateCustomSectionInfoObject = function() end}
written, writes = {}, 0
core = {
  writeBytes = function(address, bytes)
    writes = writes + 1
    for i = 1, bytes.n or #bytes do written[address + i - 1] = bytes[i] end
  end,
  readString = function(address, size) return archive end,
}
-- One archive in memory: entries by name, and at most one entry open at a time.
function memoryZip(entries)
  local current
  return {
    open_entry = function(_, name)
      assert(current == nil, 'an entry is still open')
      if entries[name] == nil and not entries.writable then return false end
      current = name; return true
    end,
    read_entry = function() return entries[current], #entries[current] end,
    write_entry = function(_, data) entries[current] = data; return true end,
    close_entry = function() current = nil; return true end,
    serialize = function() return archive, #archive end,
    close = function() end,
  }
end
package.loaded['luamemzip.dll'] = {MemoryZip = function(_, data) return memoryZip(saved) end}
registry = {}
package.loaded['mapextensions.registry'] = {registry = registry}
callbacks = require('mapextensions.callbacks')
'''


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_saving_more_than_a_megabyte(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute(HOST)
    lua.execute('''
      saved = {writable = true}
      -- 1.5 MB with every byte value; a single string.byte call fails at about 1 MB.
      local parts = {}
      for i = 0, 1500000 - 1, 256 do
        local chunk = {}
        for b = 0, 255 do chunk[#chunk + 1] = string.char(b) end
        parts[#parts + 1] = table.concat(chunk)
      end
      archive = table.concat(parts):sub(1, 1500000)
      io.open = function() return nil, 'no cache folder' end  -- the debug copy fails
      callbacks.beforeWriteSav()
      assert(memory.customSectionInfoObject.size == #archive)
      assert(writes == math.ceil(#archive / 4096), 'written in pieces')
      for i = 1, #archive, 4099 do
        assert(written[0x1000 + i - 1] == archive:byte(i), 'byte ' .. i)
      end
      assert(written[0x1000 + #archive - 1] == archive:byte(#archive))
      assert(#warnings == 1 and warnings[1]:find('debug copy', 1, true))
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_exists_leaves_the_archive_usable(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute(HOST)
    lua.execute('''
      local handles = require('mapextensions.handles')
      local zip = memoryZip({['mod/state.bin'] = 'saved', ['mod/other.bin'] = 'more'})
      local handle = handles.createReadHandle(zip, 'mod')
      assert(handle:exists('state.bin'))
      assert(handle:exists('state.bin'))
      assert(handle:get('state.bin') == 'saved')
      assert(handle:exists('other.bin') and handle:get('other.bin') == 'more')
      assert(not handle:exists('missing.bin'))
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_loading_continues_when_the_debug_copy_fails(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute(HOST)
    lua.execute('''
      saved = {['mod/state.bin'] = 'saved'}
      archive = 'zip bytes'
      memory.customSectionInfoObject.size = #archive
      io.open = function() return nil, 'disk full' end
      local restored
      registry.mod = {deserialize = function(_, handle) restored = handle:get('state.bin') end}
      callbacks.afterReadSav()
      assert(restored == 'saved')
      assert(#warnings == 1)
    ''')


@pytest.mark.parametrize('runtime', [Lua54, LuaJIT], ids=['lua54', 'luajit21'])
def test_capture_uses_every_provider_and_normal_load_restores_them(runtime):
    lua = runtime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.execute(HOST)
    lua.execute(r'''
      saved = {writable = true}
      archive = 'zip bytes'
      yaml = {parse = function()
        return {version = 1, providers = {{name = 'battle', format = 'battle-1',
          fingerprint = string.rep('a', 64)}}}
      end}
      local restored, started = {}, false
      local function get(_, handle) assert(handle:get('state.bin') == 'first\0second') end
      local function put(_, handle) handle:put('state.bin', 'first\0second') end
      registry.battle = {capture = put,
        serialize = function() error('capture must avoid ordinary save side effects') end,
        validate = get, integrity = function() return 'digest' end,
        initialize = function() end, deserialize = function(self, handle)
          get(self, handle); restored.battle = true
        end}
      require('mapextensions.required').register('battle', registry.battle,
        {required=true, format='battle-1', fingerprint=string.rep('a',64)})
      registry.optional = {serialize = put, deserialize = function(self, handle)
        get(self, handle); restored.optional = true
      end}
      local point = callbacks.captureSections()
      assert(writes == 0 and memory.customSectionInfoObject.size == 0)
      assert(saved['framework/required-state.yml'] and saved['battle/state.bin'] and saved['optional/state.bin'])
      io.open = function() return nil, 'no cache folder' end
      memory.customSectionInfoObject.size = #point
      callbacks.afterReadSav({kind='save'})
      assert(restored.battle and restored.optional)

      registry.battle = nil
      registry.optional.initialize = function() started = true end
      memory.customSectionInfoObject.size = 0
      callbacks.afterReadSav({kind='save'})
      assert(started, 'a save predating section 1337 initializes an optional provider')
    ''')
