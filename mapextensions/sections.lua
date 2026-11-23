---@diagnostic disable-next-line: undefined-global
local yaml = yaml

---Deproxifies a table
---@type fun(t: table):table
local Deproxy = extensions.proxies.Deproxy

---@type table<string, SerializationCallbacks>
local sections = {
  framework = {
    initialize = function()
      
    end,

    ---@param handle WriteHandle
    serialize = function(self, handle)
      handle:put("ucp-config.yml", yaml.dump(Deproxy(USER_CONFIG)))
      handle:put("extensions.yml", yaml.dump(Deproxy(USER_CONFIG['config-full']['load-order'])))

      local f = io.open("ucp/ucp-version.yml")
      local rawVersion = f:read("*all")
      f:close()
      local versionInfo = yaml.parse(rawVersion)
      handle:put("meta.yml", yaml.dump({
        version = '1.0.0',
        framework = versionInfo,
      }))
    end,

    ---@param handle ReadHandle
    deserialize = function(self, handle)
      if not handle:exists("meta.yml") then
        log(WARNING, "map file is missing meta information")  
        return
      end

      local meta = yaml.parse(handle:get("meta.yml"))

      if meta.version ~= "1.0.0" then
        log(WARNING, debug.traceback(string.format("map file was made using an unsupported version: %s", meta.version)))
      end

      local receivedConfig = handle:get("ucp-config.yml")
      local extensions = handle:get("extensions.yml")

      log(DEBUG, "map file was made using the following extensions:")
      log(DEBUG, '\n' .. extensions)

      log(DEBUG, "map file contained the following config:")
      log(DEBUG, '\n' .. receivedConfig)
    end,
  }
}

return sections