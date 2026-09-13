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
---@field loadKind 'map'|'save'|nil Native file context; absent for direct preflight validation
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
---@param context table|nil Native read context with kind='map' or kind='save'
function SerializationCallbacks:initialize(context) end

---When called, the extension should use the handle to serialize all information
---@param handle WriteHandle the handle to serialize data
---@return void
function SerializationCallbacks:serialize(handle) end

---When called, the extension should use the handle to deserialize all information
---@param handle ReadHandle the handle to deserialize data
---@return void
function SerializationCallbacks:deserialize(handle) end
