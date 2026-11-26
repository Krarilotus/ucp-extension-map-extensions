---@class MemoryZip
---@field open_entry fun(self: MemoryZip, entryname: string):boolean, nil|number, nil|string returns true or false, error code, error message
---@field read_entry fun(self: MemoryZip):data|nil, number, nil|err returns data, length, nil or nil, error code, error message
---@field write_entry fun(self: MemoryZip, contents: string):boolean, nil|number, nil|string returns true or false, error code, error message
---@field close_entry fun(self: MemoryZip):boolean, nil|number, nil|string returns true or false, error code, error message
---@field close fun(self: MemoryZip):void
---@field serialize fun(self: MemoryZip):data|nil, number, nil|err returns data, length, nil or nil, error code, error message

---@class luamemzip
---@field MemoryZip fun(lib: luamemzip, data: string, compression: number|nil, mode:string):MemoryZip



---Handle to serialize data
---@class WriteHandle
local WriteHandle = {}

---Put data into the .sav file
---@param self WriteHandle this
---@param path string path in the zip file to write to. Will be relative to the extension name
---@param data string the data to write
---@return void
function WriteHandle.put(self, path , data ) end

---Handle to serialize data
---@class ReadHandle
---@field loadKind 'map'|'save'|nil Which kind of file is being loaded
---@field required boolean|nil For validate(): whether the save's list of required modules names this one
---@field schema number|nil For validate() and deserialize(): the saved schema of a required section
local ReadHandle = {}

---Get data from the .sav file
---@param self ReadHandle this
---@param path string path in the zip file to read from. Will be relative to the extension name
---@return void
function ReadHandle.get(self, path ) end

---Get whether path exists in .sav file
---@param self ReadHandle this
---@param path string path in the zip file to check for existence
---@return boolean existence
function ReadHandle.exists(self, path ) return false end


--- An object of this type should be supplied by the extension
---@class SerializationCallbacks
local SerializationCallbacks = {}

---When called, the extension should set (or reset) the data to a default state
---@return void
---@param context table|nil {kind='map'} or {kind='save'}: the file being loaded
function SerializationCallbacks:initialize(context) end

---When called, the extension should use the handle to serialize all information
---@param handle WriteHandle the handle to serialize data
---@return void
function SerializationCallbacks:serialize(handle) end

---When called, the extension should use the handle to deserialize all information
---@param handle ReadHandle the handle to deserialize data
---@return void
function SerializationCallbacks:deserialize(handle) end

---Required sections need it, others may have it: check the saved data before anything is
---restored, also for a file without any data of this module. Raise an error with a short,
---readable first line if the data is missing or cannot be used.
---@param handle ReadHandle the handle to the saved data
---@return void
function SerializationCallbacks:validate(handle) end

---Put the same data as serialize without changing anything; Recorder uses it. Required
---sections need it. Without it, Recorder's captures call serialize, so a provider
---relying on that must keep serialize read-only.
---@param handle WriteHandle the handle to serialize data
---@return void
function SerializationCallbacks:capture(handle) end

---Optional, required sections only: return false while there is nothing to keep, so the
---save does not require this module.
---@return boolean
function SerializationCallbacks:isRequired() end