
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

-- Framework 3.0.8 provides core.matchesAOB; 3.0.7 does not, so compare the bytes here.
local function matchesAOB(pattern, address)
  if core.matchesAOB then return core.matchesAOB(pattern, address) end
  local offset = 0
  for token in pattern:gmatch('%S+') do
    if token ~= '?' and core.readByte(address + offset) ~= tonumber(token, 16) then return false end
    offset = offset + 1
  end
  return true
end

return {
  MapSectionAddress = MapSectionAddress,
  boolToNumber = boolToNumber,
  matchesAOB = matchesAOB,
}