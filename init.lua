
local constants = require("mapextensions.constants")

local memory = require("mapextensions.memory")

local game = require('mapextensions.game')

local registry = require("mapextensions.registry").registry

local callbacks = require("mapextensions.callbacks")
local required = require("mapextensions.required")

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
---@param options table|nil {required=true, format=..., fingerprint=..., initializeOnMap=...}
--- marks game state the save cannot do without; see docs/required-state.md
---@return void
function api:registerSection(extensionName, serializationCallbacks, options)
  if registry[extensionName] ~= nil then 
    error(debug.traceback(string.format("callbacks already registered for: %s", extensionName))) 
  end

  required.register(extensionName, serializationCallbacks, options)
  registry[extensionName] = serializationCallbacks
end

--- Feature checks for modules that need them.
function api:requiredStateVersion() return 1 end
function api:requiredStateMapPolicyVersion() return 1 end

---Which save features this version has: {version=1, failureHandling=1, readContext=1}.
---Available after enable(). Native addresses for other modules are not part of it yet.
function api:getNativeSaveInterface() return game.getNativeSaveInterface() end

-- The framework's module proxy needs an 'ignored' list as soon as a method returns a
-- table; without one, getNativeSaveInterface() fails when called through modules[...].
return api, {proxy = {ignored = {}}}