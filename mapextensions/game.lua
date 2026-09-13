local helpers = require('mapextensions.helpers')

local originalMapSectionInfoArray = core.AOBScan("? ? ? ? 00 00 00 00 20 74 02 00 01 00 e9 03 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 09 04 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 ea 03 ? ? ? ? 00 00 00 00 40 e8 04 00 01 00 eb 03")
local nativeSaveInterface

-- Stock RPS catches Lua hook errors and returns to the native caller. A failed
-- load may already have changed native sections, so it must not resume a world
-- whose required extension state was rejected or only partly restored.
local function nativeBoundary(operation, callback)
  return function(first, second)
    local ok, result = xpcall(function() return callback(first, second) end, debug.traceback)
    if ok then return result end
    log(WARNING, 'Map Extensions: native ' .. operation .. ' failed.\n' .. tostring(result))
    local reason = tostring(result):match('^[^\r\n]*'):gsub('%[string "[^"]*"%]:%d+:%s*', '')
    log(FATAL, 'Map Extensions: failed while ' .. operation .. '.\n' .. reason
      .. '\nRestart the game. Details: ucp3-error-log.log.')
    error(result, 0) -- Preserve failure if a test logger returns.
  end
end

local function enlargeMemoryAllocation(memorySize) 
    
  local ptr_codeReadSavMallocSize = core.AOBScan("68 ? ? ? ? 89 44 24 14") + 1
  local ptr_codeWriteSavMallocSize = core.AOBScan("68 ? ? ? ? 89 44 24 1C") + 1

  core.writeCodeInteger(ptr_codeReadSavMallocSize, memorySize)
  core.writeCodeInteger(ptr_codeWriteSavMallocSize, memorySize)
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

local function registerReadWriteSavHooks(customMapSectionInfoArray, customSectionID, callbacks)
  assert(nativeSaveInterface == nil, 'Map Extensions save hooks are already installed')
    
  -- Hooks
  -- read map or sav
  local ptr_FilePackagerObj = core.readInteger(core.AOBScan("B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 8B 44 24 14 ") + 1)
  -- Resolve both original entries before either prologue is wrapped. Native
  -- consumers receive these same entries and therefore retain our callbacks.
  local readWorld = core.AOBScan("83 EC 0C 53 56 8B F1 8B 46 20")
  local writeWorld = core.AOBScan("83 EC 10 53 55 56 8B F1 8B 46 20")
  local filenameBinding, readContext = require('mapextensions.readcontext').resolve(readWorld)

  local originalReadSav
  originalReadSav = core.hookCode(nativeBoundary('loading state', function(this, ptrMapSectionAddressArray)
    if originalMapSectionInfoArray ~= ptrMapSectionAddressArray then error("argument is not what we expected") end

    log(3, "readSavHook: beforeReadSav()")
    local context = readContext()
    callbacks.beforeReadSav(context)
    
    log(3, "readSavHook: originalReadSav()")
    local result = originalReadSav(this, customMapSectionInfoArray)

    log(3, "readSavHook: afterReadSav()")
    callbacks.afterReadSav(context)

    return result

  end), readWorld, 2, CallingConvention.THISCALL, 5)

  -- write map or sav
  local originalWriteSav
  originalWriteSav = core.hookCode(nativeBoundary('saving state', function(this, ptrMapSectionAddressArray)
    if originalMapSectionInfoArray ~= ptrMapSectionAddressArray then error("argument is not what we expected") end

    log(3, "writeSavHook: beforeWriteSav()")
    callbacks.beforeWriteSav()
    
    log(3, "writeSavHook: originalWriteSav()")
    local result = originalWriteSav(this, customMapSectionInfoArray)

    log(3, "writeSavHook: afterWriteSav()")
    callbacks.afterWriteSav()

    return result

  end), writeWorld, 2, CallingConvention.THISCALL, 5)

  -- -- on clear map sections before read map or sav
  -- core.detourCode(function(registers)
    
  --   return registers
  -- end, core.AOBScan("53 55 56 8B F1 57 33 FF 89 ? ? ? ? ? 89 ? ? ? ? ? 89 ? ? ? ? ? 89 ? ? ? ? ? E8 ? ? ? ?"), 5)


  core.detourCode(nativeBoundary('reading the save directory', function(registers)

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

      return registers
    end

    local customSectionSizeOfSav = core.readInteger(uncompressedSizesArray + (4 * i))

    log(3, "afterReadDirectoryOfSav({size = ...})")
    callbacks.afterReadDirectoryOfSav({
      size = customSectionSizeOfSav,
    })

    return registers 
  end), core.AOBScan("89 5E 24 89 54 24 20"), 7)

  nativeSaveInterface = {
    version = 1,
    failureHandling = 1, -- Native callback errors stop through the framework fatal logger.
    readContext = 1,
    resources = filenameBinding.resources,
    resourceFileName = filenameBinding.resourceFileName,
    resourceFileNameBytes = filenameBinding.resourceFileNameBytes,
    packager = ptr_FilePackagerObj,
    sections = originalMapSectionInfoArray,
    sectionCount = 122,
    descriptorSize = helpers.MapSectionAddress.sizeof,
    readWorld = readWorld,
    writeWorld = writeWorld,
  }
end

local function getNativeSaveInterface()
  assert(nativeSaveInterface, 'Enable Map Extensions before requesting its native save interface')
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
