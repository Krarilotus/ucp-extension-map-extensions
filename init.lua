
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
    local resolved, problem = pcall(function()
      game.resolve()
      memory.initialize()
      game.registerReadWriteSavHooks(memory.customMapSectionInfoArray, constants.CUSTOM_SECTION_ID, callbacks,
        constants.MAP_MEMORY_SIZE)
    end)
    if not resolved then
      log(ERROR, 'Map Extensions: saving and loading extension data is off: ' .. tostring(problem))
    end
  end,

  disable = function(self, config)
    
  end,
}

---Register custom section in .sav files
---@param extensionName string extension name of the extension registering the section
---@param serializationCallbacks SerializationCallbacks functions for (de)serialization of data
---@param options table|nil Section admission policy and schema. See docs/required-state.md.
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

---Save features and the game's save functions, after enable(): version, failureHandling,
---readContext, and for Recorder the section table, the file packager and the two wrapped
---save functions (call those, never the unwrapped originals).
function api:getNativeSaveInterface() return game.getNativeSaveInterface() end
function api:hasNativeSaveInterface() return game.hasNativeSaveInterface() end

---The ZIP for section 1337, without a native save or a write to game memory.
function api:captureSaveSection() return callbacks.captureSections() end

---A caller of the native Load action consumes the refused provider before seeking again.
function api:takeLoadRefusal() return game.takeLoadRefusal() end

-- For Recorder: copies and digests of the required sections, without saving the game.
-- They return detached tables; editing them changes nothing in the modules.
function api:captureRequiredSections() return required.capture() end
function api:requiredStateIntegrity() return required.integrity() end
function api:requiredStateContracts() return required.contracts() end
function api:observeRequiredStateBoundary() return required.observeBoundary() end
function api:requiredStateBoundaryIntegrity() return required.boundaryIntegrity() end

-- The framework's module proxy needs an 'ignored' list as soon as a method returns a
-- table. The listed methods return plain copies, which Recorder iterates directly.
return api, {
  proxy = {
    ignored = {
      'captureRequiredSections',
      'requiredStateIntegrity',
      'requiredStateContracts',
      'requiredStateBoundaryIntegrity',
    },
  },
}
