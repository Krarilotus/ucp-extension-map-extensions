local helpers = require('mapextensions.helpers')

-- Game sites that saving and loading extension data need, set by resolve().
local originalMapSectionInfoArray
-- The game's functions that read and write a whole .map/.sav file.
local readWorld, writeWorld
local ptr_codeReadSavMallocSize, ptr_codeWriteSavMallocSize
local ptr_FilePackagerObj
local filenameBinding, readContext
local ptr_afterReadDirectory

local nativeSaveInterface
local lastLoadRefusal

local function expect(address, pattern, what)
  if not core.matchesAOB(pattern, address) then
    error(string.format('Map Extensions does not recognise this game version (%s)', what))
  end
end

local function unique(pattern, name)
  local ok, address = pcall(core.AOBScan, pattern)
  if not ok then error(name .. ': not found', 0) end
  return address
end

-- Raises if a site is missing; nothing has been written to the game at that point.
local function resolve()
  originalMapSectionInfoArray = core.AOBScan("? ? ? ? 00 00 00 00 20 74 02 00 01 00 e9 03 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 09 04 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 ea 03 ? ? ? ? 00 00 00 00 40 e8 04 00 01 00 eb 03")
  readWorld = unique("83 EC 0C 53 56 8B F1 8B 46 20", "native world reader")
  writeWorld = unique("83 EC 10 53 55 56 8B F1 8B 46 20", "native world writer")

  -- Both functions start by allocating their file buffer: push <size>; ...
  ptr_codeReadSavMallocSize = readWorld + 0x0C
  ptr_codeWriteSavMallocSize = writeWorld + 0x13
  expect(ptr_codeReadSavMallocSize, "68 ? ? ? ? 89 44 24 14", "read buffer size")
  expect(ptr_codeWriteSavMallocSize, "68 ? ? ? ? 89 44 24 1C", "write buffer size")

  ptr_FilePackagerObj = core.readInteger(unique("B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 8B 44 24 14", "native file packager") + 1)
  ptr_afterReadDirectory = unique("89 5E 24 89 54 24 20", "native post-directory hook")
  -- Which file is being read: modules start fresh on a .map and restore on a .sav.
  filenameBinding, readContext = require('mapextensions.readcontext').resolve(readWorld)
end

local function enlargeMemoryAllocation(memorySize)
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
  return 0
end

-- A save that fails before the game writes the file is simply not written: an existing
-- file stays as it was, and the match continues. The game ignores the return value.
local function refuseSaving(result)
  log(WARNING, 'Map Extensions: saving failed.\n' .. tostring(result))
  log(ERROR, 'Map Extensions: the game was not saved.\n' .. shortReason(result)
    .. '\nThe match continues. Details: ucp3-error-log.log.')
  return 0
end

local function registerReadWriteSavHooks(customMapSectionInfoArray, customSectionID, callbacks, memorySize)
  assert(nativeSaveInterface == nil, 'Map Extensions save hooks are already installed')

  -- Hooks
  -- read map or sav

  -- Refusing a save before the world is read is optional: without its game sites,
  -- loading keeps the fatal path.
  local status
  local probe, decompress, refusal, gameMode
  local call, load
  local resolved, unsupported = pcall(function()
    refusal = require('mapextensions.loadrefusal')
    local cleanup
    call, cleanup, gameMode = refusal.resolve(readWorld, originalMapSectionInfoArray, ptr_FilePackagerObj)
    probe = require('mapextensions.archiveprobe')
    decompress = probe.resolveDecoder()
    load, status = refusal.prepare(call, cleanup, readWorld)
  end)
  if not resolved then
    status = nil
    log(ERROR, 'Map Extensions: refusing saves before loading is off: ' .. shortReason(unsupported))
  end

  -- The site lies between the native "cmp [esi+0x28], ebx" and its "jle"; the callback runs
  -- between pushfd and popfd so that the jump reads the game's compare.
  local afterReadDirectory = utils.createLuaFunctionWrapper(function(registers)
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
  end)
  local directoryHook = core.allocateAssembly([[
    pushfd
    call afterReadDirectory
    popfd
    mov [esi + 0x24], ebx
    mov [esp + 0x20], edx
    jmp resume
  ]], {afterReadDirectory = afterReadDirectory, resume = ptr_afterReadDirectory + 7})

  local originalReadSav
  originalReadSav = core.hookCode(function(this, ptrMapSectionAddressArray)
    lastLoadRefusal = nil
    local result
    local started
    -- Only the single-player Load action can return to the menu before the world
    -- is read. Every other reader caller, multiplayer included, keeps the fatal path.
    local early
    local ok, reason = xpcall(function()
      early = status ~= nil and core.readInteger(status) == 1 and refusal.singlePlayer(gameMode)
      if originalMapSectionInfoArray ~= ptrMapSectionAddressArray then error("argument is not what we expected") end
      local context, path = readContext()
      if early then
        local file = probe.openGameSave(path)
        local readable, bytes = pcall(probe.read, file, decompress)
        local closed = file:close()
        assert(readable, bytes)
        assert(closed, 'Could not close the selected save')
        callbacks.admit(bytes, context)
      end

      log(3, "readSavHook: beforeReadSav()")
      callbacks.beforeReadSav(context)

      log(3, "readSavHook: originalReadSav()")
      started = true
      result = originalReadSav(this, customMapSectionInfoArray)

      log(3, "readSavHook: afterReadSav()")
      callbacks.afterReadSav(context)
    end, debug.traceback)
    if not ok then
      local name, version
      if callbacks.missingOwner then name, version = callbacks.missingOwner(reason) end
      -- Nothing of the world has been read yet: a missing module, or a file whose
      -- section cannot be read, is refused and the player returns to the menu.
      if early and not started then
        lastLoadRefusal = name or 'map-extensions'
        core.writeInteger(status, 2)
        -- The native reader clears the packager's progress callback first; it did
        -- not run, so clear it here as the later skirmish and map loads expect.
        core.writeInteger(this + 0x20, 0)
        -- The UI owner's main menu. The progress box runs this Load every frame until
        -- it closes; the native load closes it after the read, so close it here too.
        local switched, switchError = pcall(function()
          modules.ui:switchToMenu()
          modules.ui:activateModalMenu(-1, 1)
        end)
        if not switched then log(ERROR, 'Map Extensions: ' .. tostring(switchError)) end
        if name then
          log(WARNING, 'Map Extensions: refused save requiring ' .. name .. ' (' .. version .. ') before native read')
        else
          log(WARNING, 'Map Extensions: refused unreadable save before native read: ' .. tostring(reason))
        end
        local shown, messageError = pcall(require('mapextensions.loadmessage'), name, version)
        if not shown then log(ERROR, tostring(messageError)) end
        return 0
      end
      return stopLoading(name and ('This save needs the module ' .. name) or reason)
    end
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

  core.writeCode(ptr_afterReadDirectory, {core.jmpTo(directoryHook), 0x90, 0x90})
  enlargeMemoryAllocation(memorySize)

  if status then
    local installed, problem = pcall(core.writeCode, call, {core.jmpTo(load)})
    if not installed then
      status = nil
      log(ERROR, 'Map Extensions: refusing saves before loading is off: ' .. shortReason(problem))
    end
  end

  nativeSaveInterface = {
    version = 1,
    failureHandling = 1, -- keeps the existing error contract for unexpected failures
    earlyRequiredAdmission = status and 1 or nil,
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

local function takeLoadRefusal()
  local name = lastLoadRefusal
  lastLoadRefusal = nil
  return name
end

-- A fresh copy each time, so callers cannot change Map Extensions' own table.
local function getNativeSaveInterface()
  assert(nativeSaveInterface, 'Enable Map Extensions before asking for its save interface')
  local result = {}
  for key, value in pairs(nativeSaveInterface) do result[key] = value end
  return result
end

return {
  resolve = resolve,
  createCustomSectionInfoArray = createCustomSectionInfoArray,
  updateCustomSectionInfoObject = updateCustomSectionInfoObject,
  registerReadWriteSavHooks = registerReadWriteSavHooks,
  getNativeSaveInterface = getNativeSaveInterface,
  hasNativeSaveInterface = function() return nativeSaveInterface ~= nil end,
  takeLoadRefusal = takeLoadRefusal,
}
