
local constants = require("mapextensions.constants")

local memory = require("mapextensions.memory")

local game = require('mapextensions.game')

local registry = require("mapextensions.registry").registry

local callbacks = require("mapextensions.callbacks")
local required = require('mapextensions.required')

--- The api we return from this extension
---@class mapextensions
local api = {}

api = {

  enable = function(self, config)
    game.enlargeMemoryAllocation(constants.MAP_MEMORY_SIZE)

    memory.initialize()

    game.registerReadWriteSavHooks(memory.customMapSectionInfoArray, constants.CUSTOM_SECTION_ID, callbacks)

  end,

  disable = function(self, config)
    
  end,
}

---Register custom section in .sav files
---@param extensionName string extension name of the extension registering the section
---@param serializationCallbacks SerializationCallbacks functions for (de)serialization of data
---@return void
function api:registerSection(extensionName, serializationCallbacks, options)
  if registry[extensionName] ~= nil then 
    error(debug.traceback(string.format("callbacks already registered for: %s", extensionName))) 
  end

  required.register(extensionName, serializationCallbacks, options)
  registry[extensionName] = serializationCallbacks
end

-- Capture only explicitly registered read-only providers; no native save call,
-- cache files or custom-section memory writes occur here.
function api:captureRequiredSections() return required.capture() end
function api:requiredStateIntegrity() return required.integrity() end
function api:requiredStateContracts() return required.contracts() end

function api:requiredStateVersion() return 1 end

return api
