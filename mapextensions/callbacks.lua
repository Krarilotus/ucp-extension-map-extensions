

---@type luamemzip
local luamemzip = require("luamemzip.dll")

local constants = require("mapextensions.constants")
local memory = require("mapextensions.memory")
local game = require("mapextensions.game")
local registry = require("mapextensions.registry").registry
local handles = require("mapextensions.handles")
local required = require("mapextensions.required")

local WRITE_CHUNK = 4096

local function readSections(data, read)
  local zip = luamemzip:MemoryZip(data, constants.CUSTOM_SECTION_ZIP_COMPRESSION, 'r')
  local ok, reason = xpcall(read, debug.traceback, zip)
  zip:close()
  if not ok then error(reason, 0) end
end

-- The normal writer and Recorder both use the same ZIP, names and manifest.
-- Capture callbacks let providers avoid the side effects of a manual save.
local function serializeSections(capture)
  local zipHandle = luamemzip:MemoryZip(nil, constants.CUSTOM_SECTION_ZIP_COMPRESSION, 'w')
  local ok, data, length = xpcall(function()
    for _, extensionName in ipairs(required.names()) do
      local section = registry[extensionName]
      local write = required.serializer(extensionName, capture)
      write(section, handles.createWriteHandle(zipHandle, extensionName))
    end
    handles.createWriteHandle(zipHandle, 'framework'):put(required.path, required.manifest())
    return zipHandle:serialize()
  end, debug.traceback)
  zipHandle:close()
  assert(ok, data)
  assert(type(data) == 'string' and #data == length and length > 0, 'could not serialize zip')
  assert(length <= constants.CUSTOM_SECTION_SIZE, 'data too long to store in file: ' .. length)
  return data
end

--- The interface from the low level game logic to the higher level
local callbacks = {

  missingOwner = required.missingOwner,

  admit = function(data, context)
    if data then readSections(data, function(zip) required.admit(zip, context) end) end
  end,

  captureSections = function()
    return serializeSections(true)
  end,

  beforeReadSav = function()
    log(VERBOSE, "before read sav")
    -- Only the directory read sets the size; a file the game cannot open has none.
    memory.customSectionInfoObject.size = 0

    -- wipe it! Maybe not necessary because zip procedure simply stops reading?
    -- core.setMemory(customSectionAddress, 0, CUSTOM_SECTION_SIZE)
  end,
  
  afterReadDirectoryOfSav = function(info)
    log(VERBOSE, "after read directory of sav file")

    -- At this point, the directory section of the sav file has been read, containing meta info about the file
    local length = info.size

    if length == 0 then
      log(DEBUG, "afterReadDirectoryOfSav(): no custom section present")
    end

    if length > constants.CUSTOM_SECTION_SIZE then
      error(debug.traceback(string.format("map/sav file contains more data than we have room for")))
    end

    memory.customSectionInfoObject.size = length
    -- The size of the custom section is updated in memory to make the process quicker (not process 100MB)
    game.updateCustomSectionInfoObject(memory.customMapSectionInfoArray, memory.customSectionInfoObject)
  end,
  
  ---@param context table {kind='map'} or {kind='save'}: the file being loaded
  afterReadSav = function(context)
    log(VERBOSE, "after read sav")

    if memory.customSectionInfoObject.size <= 0 then
      log(DEBUG, "afterReadSav(): no custom section present")
      -- Modules may still refuse a save that should have had their data.
      required.validateEmpty(context)
      log(DEBUG, "running initialization callbacks:")
      for _, extensionName in ipairs(required.names()) do
        local callbacks = registry[extensionName]
        if callbacks.initialize ~= nil then
          callbacks:initialize(context)
        end
      end
      return
    end

    -- At this point, readSav has processed (decompressed) all sections, including the custom section
    local data = core.readString(memory.customSectionAddress, memory.customSectionInfoObject.size)

    readSections(data, function(zipHandle)
      -- All modules check their data first; only then does any of them restore it.
      local schemas = required.validate(zipHandle, context)
      for _, extensionName in ipairs(required.names()) do
        local handle = handles.createReadHandle(zipHandle, extensionName)
        handle.loadKind = context and context.kind
        handle.required = schemas[extensionName] ~= nil
        handle.schema = schemas[extensionName]
        if required.initializesOnMap(extensionName, context) then
          registry[extensionName]:initialize(context)
        else
          registry[extensionName]:deserialize(handle)
        end
      end
    end)
    
  end,
  
  beforeWriteSav = function()
    log(VERBOSE, "before write sav")
    
    local data = serializeSections(false)
    local length = #data

    memory.customSectionInfoObject.size = length
    -- The size of the custom section is updated in memory to make the process quicker (not process 100MB)
    game.updateCustomSectionInfoObject(memory.customMapSectionInfoArray, memory.customSectionInfoObject)

    -- string.byte returns one value per byte, and Lua limits how many values one call
    -- may return (about a million), so one call fails for larger data. Write in pieces.
    for first = 1, length, WRITE_CHUNK do
      local last = math.min(first + WRITE_CHUNK - 1, length)
      core.writeBytes(memory.customSectionAddress + first - 1, {string.byte(data, first, last)})
    end

  end,
  
  afterWriteSav = function()
    log(VERBOSE, "after write sav")
  end,

}





return callbacks