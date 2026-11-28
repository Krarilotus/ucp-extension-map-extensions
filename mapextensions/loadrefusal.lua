-- The usual Load action calls FilePackager and then prepares and enters the
-- match. Reject through that caller's own epilogue before match preparation.
local M = {}

local function unique(pattern, name)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok then error(name .. ': not found', 0) end
  return address
end

function M.resolve(readWorld, sections, packager)
  -- Custom Skirmish Trails can replace the instruction after the call.
  local site = unique('6A 02 B9 ? ? ? ? E8 ? ? ? ? 68 ? ? ? ? B9 ? ? ? ? C7 05 ? ? ? ? ? ? ? ? E8 ? ? ? ? ? ? ? ? ? 89 2D ? ? ? ? 89 1D',
    'native Load call')
  local call = site + 32
  assert(core.readInteger(site + 13) == sections and core.readInteger(site + 18) == packager
    and core.readInteger(site + 24) == packager + 0x20
    and call + 5 + core.readInteger(call + 1) == readWorld,
    'unexpected native Load call')
  local cleanup = unique('5F 5E B9 ? ? ? ? E8 ? ? ? ? 5D 8B 8C 24 F4 03 00 00 5B 33 CC E8 ? ? ? ? 81 C4 F4 03 00 00 C3',
    'native Load epilogue')
  assert(cleanup >= call + 5 and cleanup <= call + 0x300, 'unexpected native Load epilogue')
  -- Multiplayer loads run inside a synchrony command and must not be refused.
  local mode = unique('A1 ? ? ? ? 3B C3 0F 84 ? ? ? ? 83 F8 63 0F 84 ? ? ? ? 33 C0 39 1D ? ? ? ? 8D 68 01 74 37', 'native Load game mode')
  assert(mode >= call - 0x300 and mode < call
    and mode + 13 + core.readInteger(mode + 9) == mode + 22 + core.readInteger(mode + 18),
    'unexpected native Load game mode branch')
  return call, cleanup, core.readInteger(mode + 1)
end

-- The same 0/99 test the native Load case uses for its single-player path. Its
-- Custom Scenarios (.map) and siege views reach the patched call without testing
-- the mode; they take the refusal under the same rule and are in the same state.
function M.singlePlayer(gameMode)
  local mode = core.readInteger(gameMode)
  return mode == 0 or mode == 99
end

function M.prepare(call, cleanup, readWorld)
  local status = core.allocate(4, true)
  local load = core.allocateAssembly([[
    mov dword [status], 1
    call readWorld
    cmp dword [status], 2
    mov dword [status], 0
    je near cleanup
    jmp resume
  ]], {status = status, readWorld = readWorld, cleanup = cleanup, resume = call + 5})
  core.writeInteger(status, 0)
  return load, status
end

return M
