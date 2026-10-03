local helpers = require('mapextensions.helpers')

local originalMapSectionInfoArray = core.AOBScan("? ? ? ? 00 00 00 00 20 74 02 00 01 00 e9 03 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 09 04 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 ea 03 ? ? ? ? 00 00 00 00 40 e8 04 00 01 00 eb 03")

-- The game's functions that read and write a whole .map/.sav file.
local readWorld = core.AOBScan("83 EC 0C 53 56 8B F1 8B 46 20")
local writeWorld = core.AOBScan("83 EC 10 53 55 56 8B F1 8B 46 20")

local nativeSaveInterface

local function expect(address, pattern, what)
  local offset = 0
  for token in pattern:gmatch('%S+') do
    if token ~= '?' and core.readByte(address + offset) ~= tonumber(token, 16) then
      error(string.format('Map Extensions does not recognise this game version (%s)', what))
    end
    offset = offset + 1
  end
end

local function enlargeMemoryAllocation(memorySize)
  -- Both functions start by allocating their file buffer: push <size>; ...
  local ptr_codeReadSavMallocSize = readWorld + 0x0C
  local ptr_codeWriteSavMallocSize = writeWorld + 0x13
  expect(ptr_codeReadSavMallocSize, "68 ? ? ? ? 89 44 24 14", "read buffer size")
  expect(ptr_codeWriteSavMallocSize, "68 ? ? ? ? 89 44 24 1C", "write buffer size")

  core.writeCodeInteger(ptr_codeReadSavMallocSize + 1, memorySize)
  core.writeCodeInteger(ptr_codeWriteSavMallocSize + 1, memorySize)
end

local function createCustomSectionInfoArray(customSectionInfoObject)
  local mapSectionAddressArraySize = 1968
  local entriesCount = 1968 / 123 -- of which the last is all 0s


  local ptr_copyOfMapSectionAddressArray = core.allocate(mapSectionAddressArraySize + helpers.MapSectionAddress.sizeof, true)

  -- Install the special thing such that our information is put in a .sav file
  core.writeBytes(ptr_copyOfMapSectionAddressArray, core.readBytes(originalMapSectionInfoArray, mapSectionAddressArraySize))
  core.writeBytes(ptr_copyOfMapSectionAddressArray + (122 * helpers.MapSectionAddress.sizeof), customSectionInfoObject:serialize())

  return ptr_copyOfMapSectionAddressArray
end

local function updateCustomSectionInfoObject(ptr_copyOfMapSectionAddressArray, customSectionInfoObject)
  core.writeBytes(ptr_copyOfMapSectionAddressArray + (122 * helpers.MapSectionAddress.sizeof), customSectionInfoObject:serialize())
end

-- Only the first line of an error goes into the message box. The framework names module
-- files '@<path>', so every assert on the way adds 'file.lua:line:'; remove those.
local function shortReason(result)
  local line = tostring(result):match('^[^\r\n]*')
  line = line:gsub('%[string "[^"]*"%]:%d+:%s*', '')
  repeat
    local before = line
    line = line:gsub('^[^%s]-%.lua:%d+:%s*', '')
  until line == before
  return line
end

-- A load that fails halfway has already replaced part of the running game with the
-- file's contents, so the game cannot continue. The framework's FATAL log shows the
-- message and closes the game. (Without this, the error is only logged and the player
-- carries on in a mix of the old and the new game.)
local function stopLoading(result)
  log(WARNING, 'Map Extensions: loading failed.\n' .. tostring(result))
  log(FATAL, 'Map Extensions: the game could not be loaded.\n' .. shortReason(result)
    .. '\nRestart the game. Details: ucp3-error-log.log.')
  error(result, 0)
end

-- A save that fails before the game writes the file is simply not written: an existing
-- file stays as it was, and the match continues. The game ignores the return value.
local function refuseSaving(result)
  log(WARNING, 'Map Extensions: saving failed.\n' .. tostring(result))
  log(ERROR, 'Map Extensions: the game was not saved.\n' .. shortReason(result)
    .. '\nThe match continues. Details: ucp3-error-log.log.')
  return 0
end

local function registerReadWriteSavHooks(customMapSectionInfoArray, customSectionID, callbacks)
  assert(nativeSaveInterface == nil, 'Map Extensions save hooks are already installed')

  -- Hooks
  -- read map or sav
  local ptr_FilePackagerObj = core.readInteger(core.AOBScan("B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 8B 44 24 14 ") + 1)
  -- Which file is being read: modules start fresh on a .map and restore on a .sav.
  local filenameBinding, readContext = require('mapextensions.readcontext').resolve(readWorld)

  local originalReadSav
  originalReadSav = core.hookCode(function(this, ptrMapSectionAddressArray)
    local result
    local ok, reason = xpcall(function()
      if originalMapSectionInfoArray ~= ptrMapSectionAddressArray then error("argument is not what we expected") end
      local context = readContext()

      log(3, "readSavHook: beforeReadSav()")
      callbacks.beforeReadSav(context)

      log(3, "readSavHook: originalReadSav()")
      result = originalReadSav(this, customMapSectionInfoArray)

      log(3, "readSavHook: afterReadSav()")
      callbacks.afterReadSav(context)
    end, debug.traceback)
    if not ok then stopLoading(reason) end
    return result

  end, readWorld, 2, CallingConvention.THISCALL, 5)

  -- write map or sav
  local originalWriteSav
  originalWriteSav = core.hookCode(function(this, ptrMapSectionAddressArray)
    local ok, reason = xpcall(function()
      if originalMapSectionInfoArray ~= ptrMapSectionAddressArray then error("argument is not what we expected") end

      log(3, "writeSavHook: beforeWriteSav()")
      callbacks.beforeWriteSav()
    end, debug.traceback)
    if not ok then return refuseSaving(reason) end

    log(3, "writeSavHook: originalWriteSav()")
    local result = originalWriteSav(this, customMapSectionInfoArray)

    log(3, "writeSavHook: afterWriteSav()")
    local written, problem = xpcall(callbacks.afterWriteSav, debug.traceback)
    if not written then log(WARNING, 'Map Extensions: after saving: ' .. tostring(problem)) end

    return result

  end, writeWorld, 2, CallingConvention.THISCALL, 5)

  -- -- on clear map sections before read map or sav
  -- core.detourCode(function(registers)

  --   return registers
  -- end, core.AOBScan("53 55 56 8B F1 57 33 FF 89 ? ? ? ? ? 89 ? ? ? ? ? 89 ? ? ? ? ? 89 ? ? ? ? ? E8 ? ? ? ?"), 5)


  core.detourCode(function(registers)
    local ok, reason = xpcall(function()

    local directoryDataAddress = ptr_FilePackagerObj + 36

    local uncompressedSizesArray = directoryDataAddress + 28

    local sectionIDArray = directoryDataAddress + 28 + (4*150) + (4*150)

    local sectionIDs = utils.unpack("<i", core.readString(sectionIDArray, 4*150))

    local i = -1
    for index, sid in ipairs(sectionIDs) do
      if sid == customSectionID then
        i = index - 1 -- lua is 1 based
        break
      end
    end

    if i == -1 then

      log(3, "afterReadDirectoryOfSav({size = 0})")
      callbacks.afterReadDirectoryOfSav({
        size = 0,
      })

      return
    end

    local customSectionSizeOfSav = core.readInteger(uncompressedSizesArray + (4 * i))

    log(3, "afterReadDirectoryOfSav({size = ...})")
    callbacks.afterReadDirectoryOfSav({
      size = customSectionSizeOfSav,
    })

    end, debug.traceback)
    if not ok then stopLoading(reason) end
    return registers
  end, core.AOBScan("89 5E 24 89 54 24 20"), 7)

  nativeSaveInterface = {
    version = 1,
    failureHandling = 1, -- a rejected load stops the game; a failed save is not written
    readContext = 1,     -- callbacks learn whether a .map or a .sav is being loaded
    -- For Recorder: the same addresses these hooks use, so it needs no scans of its own.
    resources = filenameBinding.resources,
    resourceFileName = filenameBinding.resourceFileName,
    resourceFileNameBytes = filenameBinding.resourceFileNameBytes,
    packager = ptr_FilePackagerObj,
    sections = originalMapSectionInfoArray,
    sectionCount = 122,
    descriptorSize = helpers.MapSectionAddress.sizeof,
    readWorld = readWorld,   -- wrapped: calling it runs Map Extensions' load callbacks
    writeWorld = writeWorld, -- wrapped: calling it runs Map Extensions' save callbacks
  }
end

-- A fresh copy each time, so callers cannot change Map Extensions' own table.
local function getNativeSaveInterface()
  assert(nativeSaveInterface, 'Enable Map Extensions before asking for its save interface')
  local result = {}
  for key, value in pairs(nativeSaveInterface) do result[key] = value end
  return result
end

return {
  enlargeMemoryAllocation = enlargeMemoryAllocation,
  createCustomSectionInfoArray = createCustomSectionInfoArray,
  updateCustomSectionInfoObject = updateCustomSectionInfoObject,
  registerReadWriteSavHooks = registerReadWriteSavHooks,
  getNativeSaveInterface = getNativeSaveInterface,
}
