-- Resolve the native filename caller within Map's already discovered reader.
local M = {}
local caller = '55 57 B9 ? ? ? ? E8 ? ? ? ? 53 68 00 80 00 00 50 E8 ? ? ? ? 8B F8 83 CD FF 83 C4 0C 3B FD'
local filename = '8B 81 C4 0B 00 00 69 C0 E9 03 00 00 8D 84 08 E0 AE 07 00 C3'

local function verify(address, pattern)
  local offset = 0
  for token in pattern:gmatch('%S+') do
    assert(token == '?' or core.readByte(address + offset) == tonumber(token, 16),
      'Map Extensions: unsupported native read filename context')
    offset = offset + 1
  end
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
    -- Retain Recorder's existing scoped override by calling the shared entry.
    local path = core.readString(getter(resources))
    return {kind = path:lower():match('%.map$') and 'map' or 'save'}
  end
  return binding, capture
end
return M
