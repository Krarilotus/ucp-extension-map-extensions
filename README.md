# UCP Extension: map-extensions
UCP Extension that enables storing extra information in .map and .sav files

Version 1.1.3 stops native save/load operations when a callback fails. It uses
UCP's existing fatal logger so a rejected required-state restore cannot leave a
running world with missing extension state. This covers section sizing,
initialization, validation, restoration and serialization at the existing hooks;
successful calls, scans and section formats are unchanged. The required-state API
still raises catchable errors when called directly for Recorder preflight.
The dialog gives the reason and restart instruction; the error log retains the
full stack trace. This replaces the verbose dialog in the 1.1.2 test build.

## Idea
A .map file has sections. How to read these sections and where to store the data is stored in the .exe file.
Currently that array is 123 entries long (.msv files use all of those). It cannot be expanded.
The read map or sav file function takes the array of section information as an argument. Could be easier to just highjack that argument to our location!

writeSav = "83 EC 10 53 55 56 8B F1 8B 46 20" -- size 5
readSav = "83 EC 0C 53 56 8B F1 8B 46 20" -- size 5

Technically, we only need a 124th section since section sizes can be of max size of a signed integer 2,147,483,647 bytes, which is 2.14 Gb.
We set the flag to compressed so we can zero initialize a large space (which will be compressed to almost nothing if it stays as 0's).

Maybe it is easiest to also hook into the save and load functions for the purpose to prepare this section for serialization.
I think it is easiest to organize it as a .zip file itself (without compression).

Furthermore it is necessary upon readMap/readSav to check if the section even exists

##### Note
The game currently allocates 6,000,000 bytes (6 MB) for the entire .map file to be read into memory. 
We need to increase this, luckily it is of type int32.

### Structure
```yml
#contains meta information such as the framework version it can run on
meta.yml:
  version: 1.0.0
  framework: ^3.0.0
  extensions: # which extensions have an entry in the section, including which version of an extension created it.
    maploader: 0.0.1
  config: {} # The full config of the user that was used to create the .map file
framework: # folder used by the framework itself, not sure what the use is if we have meta.yml
extensions:
  maploader: # folder used by the extension named maploader
  whatever: # plugin folder data
```

### Interface
```lua
local registry = {}

api = {
  -- Returns a handle to the section, which is a zip in memory!
  function registerSection(self, extensionName, serializationCallbacks)
    registry[extensionName] = serializationCallbacks
  end,
}

-- If the game saves the map state
function onSerialize()
  for extensionName, callbacks in pairs(registry) do
    callbacks:serialize(some_handle)
  end

  -- Now the zip is complete, so we need to write the address and size, or a byte stream,
  -- to the memory location the game will process the bytes from to store it in the file
end

-- An object of this type is supplied by the extension
SerializationCallbacks = {

  -- When called, the extension should use the handle to serialize all information
  serialize = function(self, handle) end,

  -- When called, the extension should use the handle to deserialize all information
  -- The handle can be stored somewhere? Or is the data really handed over?
  deserialize = function(self, handle) end,

}

Buffer = {
  readInteger = function(self) end,
  writeInteger = function(self) end,
  readBytes = function(self) end,
  writeBytes = function(self) end,
}

-- This is backed by the library https://github.com/kuba--/zip
Handle = {
  putContents = function(self, relativePath, data) end,
  getContents = function(self, relativePath) end,
}
```

### Usage
```lua

local databytes = {}

return {

  enable = function(self, config)
    modules['map-extensions']:registerSection("plugin name", {
      check = function(s, handle)
        -- Check version compatibility with a .map or .sav file
      end,
      serialize = function(s, handle)
        databytes = handle:getContents('data.txt') -- will be 'extensions/plugin name/mydata.txt' in the zip file
      end,
      deserialize = function(s, handle)
        handle:putContents('mydata.txt', databytes)
      end,
    })
  end,

}

```

### POC 
```lua

local ptr_codeReadSavMallocSize = core.AOBScan("68 ? ? ? ? 89 44 24 14") + 1
local ptr_codeWriteSavMallocSize = core.AOBScan("68 ? ? ? ? 89 44 24 1C") + 1

core.writeCodeInteger(ptr_codeReadSavMallocSize, 100 * 1000 * 1000)
core.writeCodeInteger(ptr_codeWriteSavMallocSize, 100 * 1000 * 1000)

local function boolToNumber(b)
  if type(b) == "number" then
    if b == 0 or b == 1 then
      return b
    else
      error(debug.traceback(string.format("Not a bool: %s", b)))
    end
  end

  if b == false then 
    return 0 
  elseif b == true then
    return 1 
  else 
    error(debug.traceback(string.format("Not a bool: %s", b)))
  end
end

local MapSectionAddress = {

  sizeof = 16,

  new = function(self, address, size, compressed, id)
    local o = {
      address = address,
      size = size,
      compressed = compressed,
      id = id,
    }
    
    self.__index = self
    
    return setmetatable(o, self)
  end,

  serialize = function(self) 
    local bytes = {}

    for _, data in ipairs({
      core.itob(self.address),
      core.itob(0),
      core.itob(self.size),
      core.stob(boolToNumber(self.compressed)),
      core.stob(self.id),
    }) do
      for k, v in ipairs(data) do
        table.insert(bytes, v)
      end
    end

    return bytes
  end,

}

local DAT_mapSectionAddressArray = core.AOBScan("? ? ? ? 00 00 00 00 20 74 02 00 01 00 e9 03 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 09 04 ? ? ? ? 00 00 00 00 20 74 02 00 01 00 ea 03 ? ? ? ? 00 00 00 00 40 e8 04 00 01 00 eb 03")
local mapSectionAddressArraySize = 1968
local entriesCount = 1968 / 123 -- of which the last is all 0s


local ptr_copyOfMapSectionAddressArray = core.allocate(mapSectionAddressArraySize + MapSectionAddress.sizeof, true)
local DAT_MapName = core.readInteger(core.AOBScan("8D 54 24 08 52 68 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 83 3C 24 00") + 6)

-- Install the special thing such that our information is put in a .sav file
core.writeBytes(ptr_copyOfMapSectionAddressArray, core.readBytes(DAT_mapSectionAddressArray, mapSectionAddressArraySize))
core.writeBytes(ptr_copyOfMapSectionAddressArray + (122 * MapSectionAddress.sizeof), MapSectionAddress:new(DAT_MapName, 1000, false, 1337):serialize())

-- Hooks
core.detourCode(function(registers)
  if DAT_mapSectionAddressArray ~= core.readInteger(registers.ESP + 4) then error("argument is not what we expected") end
  
  print("readSav", string.format("%X", ptr_copyOfMapSectionAddressArray))
  core.writeInteger(registers.ESP + 4, ptr_copyOfMapSectionAddressArray)
  
  return registers
end, core.AOBScan("83 EC 0C 53 56 8B F1 8B 46 20"), 5)

core.detourCode(function(registers)
  if DAT_mapSectionAddressArray ~= core.readInteger(registers.ESP + 4) then error("argument is not what we expected") end
  
  print("writeSav", string.format("%X", ptr_copyOfMapSectionAddressArray))
  core.writeInteger(registers.ESP + 4, ptr_copyOfMapSectionAddressArray)
  
  print("writeSav", string.format("%X", core.readInteger(registers.ESP + 4)))
  
  return registers
end, core.AOBScan("83 EC 10 53 55 56 8B F1 8B 46 20"), 5)

```
