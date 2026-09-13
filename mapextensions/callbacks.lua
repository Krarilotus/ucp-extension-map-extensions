

---@type luamemzip
local luamemzip = require("luamemzip.dll")

local constants = require("mapextensions.constants")
local memory = require("mapextensions.memory")
local game = require("mapextensions.game")
local registry = require("mapextensions.registry").registry
local handles = require("mapextensions.handles")
local required = require('mapextensions.required')

--- The interface from the low level game logic to the higher level
local callbacks = {

  beforeReadSav = function()
    log(VERBOSE, "before read sav")

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
  
  afterReadSav = function(context)
    log(VERBOSE, "after read sav")

    if memory.customSectionInfoObject.size <= 0 then
      log(DEBUG, "afterReadSav(): no custom section present")
      log(DEBUG, "running initialization callbacks:")
      required.validateEmpty(context)
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

    local f, err = io.open("ucp/.cache/sav-custom-section-on-read.zip", 'wb')
    if f == nil then error(err) end
    f:write(data)
    f:close()

    local zipHandle = luamemzip:MemoryZip(data, constants.CUSTOM_SECTION_ZIP_COMPRESSION, 'r')

    local ok, reason = xpcall(function()
      required.validate(zipHandle, context)
      for _, extensionName in ipairs(required.names()) do
        local handle = handles.createReadHandle(zipHandle, extensionName)
        handle.loadKind = context and context.kind
        registry[extensionName]:deserialize(handle)
      end
    end, debug.traceback)
    zipHandle:close()
    assert(ok, reason)
    
  end,
  
  beforeWriteSav = function()
    log(VERBOSE, "before write sav")
    
    local zipHandle = luamemzip:MemoryZip(nil, constants.CUSTOM_SECTION_ZIP_COMPRESSION, 'w')

    local data, length
    local ok, reason = xpcall(function()
      for _, extensionName in ipairs(required.names()) do
        registry[extensionName]:serialize(handles.createWriteHandle(zipHandle, extensionName))
      end
      handles.createWriteHandle(zipHandle, 'framework'):put(required.path, required.manifest())
      data, length = zipHandle:serialize()
    end, debug.traceback)
    zipHandle:close()
    assert(ok, reason)

    if data == nil or data == false then
      error("could not serialize zip")
    end

    if length > constants.CUSTOM_SECTION_SIZE then
      error(string.format("data too long to store in file: %s", length))
    end

    memory.customSectionInfoObject.size = length
    -- The size of the custom section is updated in memory to make the process quicker (not process 100MB)
    game.updateCustomSectionInfoObject(memory.customMapSectionInfoArray, memory.customSectionInfoObject)

    core.writeBytes(memory.customSectionAddress, table.pack(string.byte(data, 1, length)))    

    local f, err = io.open("ucp/.cache/sav-custom-section-on-write.zip", 'wb')
    if f == nil then error(err) end
    f:write(data)
    f:close()

  end,
  
  afterWriteSav = function()
    log(VERBOSE, "after write sav")
  end,

}





return callbacks
