-- Find only the custom section. The native whole-world reader clears world
-- fields before reaching the directory. The native single-section reader
-- also trusts disk-controlled lengths, so it cannot be used as a safe probe.
local constants = require('mapextensions.constants')
local M = {}
local DIRECTORY_SIZE, LEGACY_DIRECTORY_SIZE = 3036, 2036
local seekOrigins = {set = 0, cur = 1, ['end'] = 2}
local fileOperations

function M.openGameSave(path)
  if not fileOperations then
    fileOperations = {
      read = core.exposeCode(io.ucrt._read, 3, 0),
      seek = core.exposeCode(io.ucrt._lseek, 3, 0),
      close = core.exposeCode(io.ucrt._close, 1, 0),
    }
  end
  -- Use the framework's game-file opener. Native saves can live in Documents
  -- or under the selected game data path, outside the ordinary Lua file root.
  local fd = io.openFileDescriptor(path, 0x8000, 0) -- read only, binary
  assert(type(fd) == 'number' and fd >= 0 and fd < 0x7fffffff, 'Could not open the selected save')
  return {
    read = function(_, size)
      local ffi = modules.cffi:cffi()
      local buffer = ffi.new('char[?]', size)
      local address = ffi.tonumber(ffi.cast('unsigned long', buffer))
      local count = fileOperations.read(fd, address, size)
      if count == size then return core.readString(address, size) end
    end,
    seek = function(_, origin, offset)
      local position = fileOperations.seek(fd, offset or 0, seekOrigins[origin or 'cur'])
      if position >= 0 and position < 0x7fffffff then return position end
    end,
    close = function() return fileOperations.close(fd) == 0 end,
  }
end

function M.read(file, decompress)
  local function take(size)
    local bytes = file:read(size)
    assert(bytes and #bytes == size, 'Short save while reading extension state')
    return bytes
  end
  local size = assert(file:seek('end'))
  assert(file:seek('set', 0))
  local directorySize = string.unpack('<I4', take(4))
  if directorySize == 0xffffffff then
    local blocks = 0
    while true do
      local length = string.unpack('<I4', take(4))
      if length == 0 then break end
      blocks = blocks + 1
      assert(blocks <= 6, 'Unexpected save header blocks')
      local at = assert(file:seek())
      assert(length <= size - at, 'Invalid save header block')
      assert(file:seek('cur', length))
    end
    directorySize = string.unpack('<I4', take(4))
  end
  if directorySize == LEGACY_DIRECTORY_SIZE then return end
  assert(directorySize == DIRECTORY_SIZE, 'Unrecognized save directory')
  local directory = take(DIRECTORY_SIZE - 4)
  local payload = assert(file:seek())
  local payloadSize, count = string.unpack('<I4I4', directory)
  assert(count <= 150 and payloadSize <= size - payload and payloadSize <= constants.MAP_MEMORY_SIZE,
    'Invalid save directory bounds')
  local found
  for i = 0, count - 1 do
    if string.unpack('<I4', directory, 1229 + 4*i) == constants.CUSTOM_SECTION_ID then
      assert(not found, 'Duplicate Map Extensions section')
      found = i
    end
  end
  if not found then return end
  local row = found * 4
  local rawSize = string.unpack('<I4', directory, 29 + row)
  local storedSize = string.unpack('<I4', directory, 629 + row)
  local compressed = string.unpack('<I4', directory, 1829 + row)
  local offset = string.unpack('<I4', directory, 2429 + row)
  assert(rawSize <= constants.CUSTOM_SECTION_SIZE and offset <= payloadSize
    and storedSize <= payloadSize - offset, 'Invalid Map Extensions section bounds')
  if rawSize == 0 and storedSize == 0 then return end
  assert(rawSize > 0 and storedSize > 0, 'Empty Map Extensions section')
  assert(file:seek('set', payload + offset))
  local bytes = take(storedSize)
  if compressed == 1 then return decompress(bytes, rawSize) end
  assert(compressed == 0 and rawSize == storedSize, 'Invalid uncompressed Map Extensions section')
  return bytes
end

function M.resolveDecoder()
  local pattern = '83 EC 34 53 56 68 D8 8D 00 00 6A 42 BB 01 00 00 00 FF 15 ? ? ? ? 8B F0 85 F6 75 08 5E 5B 83 C4 34 C2 14 00 57 56 FF 15 ? ? ? ? 8B F8 85 FF 75 12'
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok then error("save decompressor: not found", 0) end
  local explode = core.exposeCode(address, 6, CallingConvention.THISCALL)
  return function(data, size)
    assert(#data >= 12, 'Short compressed Map Extensions section')
    local raw, packed, checksum = string.unpack('<I4I4i4', data)
    assert(raw == size and packed == #data - 12 and packed > 0, 'Invalid compressed section header')
    local ffi = modules.cffi:cffi()
    local state = ffi.new('int32_t[5]')
    state[1] = 4096
    local input, output = ffi.new('char[?]', packed), ffi.new('char[?]', raw)
    ffi.copy(input, data:sub(13), packed)
    local function pointer(value) return ffi.tonumber(ffi.cast('unsigned long', value)) end
    local stateAddress = pointer(state)
    assert(explode(stateAddress, stateAddress + 8, pointer(input), packed, pointer(output), raw) == 1
      and tonumber(state[2]) == checksum, 'Cannot decompress Map Extensions section')
    return core.readString(pointer(output), raw)
  end
end

return M
