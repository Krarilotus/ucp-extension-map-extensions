-- Which file is being loaded. readWorld asks the game for the file name at +0x44;
-- the called function is found there and checked byte by byte, so no extra scan is needed.
local M = {}
local caller = '55 57 B9 ? ? ? ? E8 ? ? ? ? 53 68 00 80 00 00 50 E8 ? ? ? ? 8B F8 83 CD FF 83 C4 0C 3B FD'
local filename = '8B 81 C4 0B 00 00 69 C0 E9 03 00 00 8D 84 08 E0 AE 07 00 C3'

local function verify(address, pattern)
  assert(core.matchesAOB(pattern, address), 'Map Extensions does not recognise this game version (file name lookup)')
end

function M.resolve(readWorld)
  local site = readWorld + 0x44
  verify(site, caller)
  local resources = core.readInteger(site + 3)
  local entry = site + 12 + core.readInteger(site + 8)
  assert(resources >= 0x10000 and resources <= 0x7fffffff - 0x7c000
    and entry >= 0x10000 and entry <= 0x7fffffff - 20,
    'Map Extensions: invalid native filename binding')
  verify(entry, filename)
  local getter = core.exposeCode(entry, 1, CallingConvention.THISCALL)
  local binding = {resources = resources, resourceFileName = entry,
    resourceFileNameBytes = core.readString(entry, 20)}
  local function capture()
    -- Call the game's own function, so a module that redirects it (such as Recorder) still works.
    local path = core.readString(getter(resources))
    return {kind = path:lower():match('%.map$') and 'map' or 'save'}, path
  end
  return binding, capture
end
return M
