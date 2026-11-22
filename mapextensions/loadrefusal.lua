-- The usual Load action calls FilePackager and then prepares and enters the
-- match. Reject through that caller's own epilogue before match preparation.
local M = {}

function M.resolve(readWorld, sections, packager)
  local site = core.AOBScan('6A 02 B9 ? ? ? ? E8 ? ? ? ? 68 ? ? ? ? B9 ? ? ? ? C7 05 ? ? ? ? ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? 89 2D ? ? ? ? 89 1D')
  local call = site + 32
  assert(core.readInteger(site + 13) == sections and core.readInteger(site + 18) == packager
    and core.readInteger(site + 24) == packager + 0x20
    and call + 5 + core.readInteger(call + 1) == readWorld,
    'Map Extensions: unexpected native Load call')
  local cleanup = core.AOBScan('5F 5E B9 ? ? ? ? E8 ? ? ? ? 5D 8B 8C 24 F4 03 00 00 5B 33 CC E8 ? ? ? ? 81 C4 F4 03 00 00 C3',
    call + 5, call + 0x300)
  return call, cleanup
end

function M.install(call, cleanup, readWorld)
  local status = core.allocate(4, true)
  core.writeInteger(status, 0)
  core.insertCode(call, 5, {
    0xC7, 0x05, utils.itob(status), 1, 0, 0, 0, -- native Load is in progress
    core.callTo(readWorld),
    0x83, 0x3D, utils.itob(status), 2, -- cmp [status], 2
    0xC7, 0x05, utils.itob(status), 0, 0, 0, 0, -- clear without modifying flags
    0x75, 0x05, -- accepted: skip the jump to the native epilogue
    core.jmpTo(cleanup),
  })
  return status
end

return M
