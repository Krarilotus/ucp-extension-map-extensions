

--- This is backed by the library https://github.com/gynt/luamemzip
---@param memoryZip MemoryZip
---@param prefix string
---@return WriteHandle
local function createWriteHandle(memoryZip, prefix)

  if prefix == nil then prefix = "" else prefix = prefix .. "/" end

  return {
    
    put = function(self, path, data) 
      log(2, string.format("putting %s bytes => %s%s", data:len(), prefix, path))
      local status, code, message = memoryZip:open_entry(prefix .. path)
      if not status then error(debug.traceback(string.format("error in put('%s') open_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end
      status, code, message = memoryZip:write_entry(data)
      if not status then error(debug.traceback(string.format("error in get('%s') write_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end
      status, code, message = memoryZip:close_entry()
      if not status then error(debug.traceback(string.format("error in get('%s') close_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end
    end,

  }

end




--- This is backed by the library https://github.com/gynt/luamemzip
---@param memoryZip MemoryZip
---@param prefix string
---@return ReadHandle
local function createReadHandle(memoryZip, prefix)

  if prefix == nil then prefix = "" else prefix = prefix .. "/" end
  
  return {

    exists = function(self, path)
      log(2, string.format("exists? => %s%s", prefix, path))
      local status, code, message = memoryZip:open_entry(prefix .. path)
      if not status then return false end
      local closed, closeCode, closeMessage = memoryZip:close_entry()
      if not closed then error(string.format('Cannot close entry: %s %s', tostring(closeCode), tostring(closeMessage))) end
      return true
    end,
    
    get = function(self, path) 
      local result, length_or_code

      log(2, string.format("getting => %s%s", prefix, path))
      local status, code, message = memoryZip:open_entry(prefix .. path)
      if not status then error(debug.traceback(string.format("error in get('%s') open_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end
      result, length_or_code, message = memoryZip:read_entry()
      if not result then error(debug.traceback(string.format("error in get('%s') read_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end
      status, code, message = memoryZip:close_entry()
      if not status then error(debug.traceback(string.format("error in get('%s') close_entry(): %s %s", tostring(prefix .. path), tostring(code), tostring(message)))) end

      return result
    end,

  }

end

return {
  createReadHandle = createReadHandle,
  createWriteHandle = createWriteHandle,
}
