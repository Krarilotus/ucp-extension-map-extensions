local handles = require('mapextensions.handles')
local registry = require('mapextensions.registry').registry
local M = {providers = {}, path = 'required-state.yml'}
local MAX_PROVIDERS, MAX_MANIFEST = 256, 131072
local MAX_CAPTURE_BYTES = require('mapextensions.constants').CUSTOM_SECTION_SIZE

local function names()
  local result = {}
  for name in pairs(registry) do result[#result + 1] = name end
  table.sort(result)
  return result
end

local function active(name)
  local callbacks = registry[name]
  if not callbacks or not M.providers[name] then return false end
  if not callbacks.isRequired then return true end
  local value = callbacks:isRequired()
  assert(type(value) == 'boolean', 'Required state predicate must return a boolean')
  return value
end

function M.register(name, callbacks, options)
  if options == nil then return end
  assert(type(options) == 'table' and options.required == true,
    'State section options require required=true')
  assert(type(name) == 'string' and #name <= 128 and name ~= 'framework'
    and name:match('^[%w_-]+$'), 'Invalid required state section name')
  local count = 0
  for _ in pairs(M.providers) do count = count + 1 end
  assert(count < MAX_PROVIDERS, 'Too many required state providers')
  assert(type(options.format) == 'string' and #options.format > 0 and #options.format <= 128
    and options.format:match('^[%w_.-]+$'),
    'Required state sections need a format identifier')
  assert(type(options.fingerprint) == 'string' and #options.fingerprint == 64
    and options.fingerprint:match('^%x+$'), 'Required state sections need a SHA256 content fingerprint')
  for _, method in ipairs({'initialize','serialize','deserialize','validate','capture','integrity'}) do
    assert(type(callbacks[method]) == 'function', 'Required state section needs ' .. method)
  end
  assert(callbacks.isRequired == nil or type(callbacks.isRequired) == 'function', 'Invalid required state predicate')
  assert((callbacks.observeBoundary==nil and callbacks.boundaryIntegrity==nil)
    or (type(callbacks.observeBoundary)=='function' and type(callbacks.boundaryIntegrity)=='function'),
    'Boundary observation needs both callbacks')
  M.providers[name] = {format=options.format, fingerprint=options.fingerprint:lower()}
end

function M.manifest()
  local lines = {}
  for _, name in ipairs(names()) do
    local provider = M.providers[name]
    if provider and active(name) then
      lines[#lines + 1] = '  - name: "' .. name .. '"\n    format: "' .. provider.format
        .. '"\n    fingerprint: "' .. provider.fingerprint .. '"\n'
    end
  end
  if #lines == 0 then return 'version: 1\nproviders: []\n' end
  return 'version: 1\nproviders:\n' .. table.concat(lines)
end

function M.validate(zip)
  local handle = handles.createReadHandle(zip, 'framework')
  local seen = {}
  if handle:exists(M.path) then
    local data = handle:get(M.path)
    assert(type(data) == 'string' and #data <= MAX_MANIFEST, 'Required state manifest is too large')
    local saved = yaml.parse(data)
    assert(type(saved) == 'table' and saved.version == 1 and type(saved.providers) == 'table',
      'Unsupported required state manifest')
    local count = 0
    for index in pairs(saved.providers) do
      assert(type(index) == 'number' and index >= 1 and index == math.floor(index), 'Invalid state provider list')
      count = count + 1
    end
    assert(count == #saved.providers and count <= MAX_PROVIDERS, 'Invalid state provider list')
    for _, provider in ipairs(saved.providers) do
      assert(type(provider) == 'table' and type(provider.name) == 'string' and not seen[provider.name],
        'Invalid or duplicate required state provider')
      seen[provider.name] = true
      local current = M.providers[provider.name]
      assert(current and registry[provider.name], 'This save requires state provider: ' .. provider.name)
      assert(current.format == provider.format and current.fingerprint == provider.fingerprint,
        'This save requires the original state provider content: ' .. provider.name)
    end
  end
  -- Every validator runs before the first extension restore callback.
  for _, name in ipairs(names()) do
    local callbacks = registry[name]
    if callbacks.validate then
      local section = handles.createReadHandle(zip, name)
      section.required = seen[name] == true
      callbacks:validate(section)
    end
  end
end

function M.capture()
  local entries = {['framework/' .. M.path] = M.manifest()}
  local count, bytes = 1, #entries['framework/' .. M.path]
  for _, name in ipairs(names()) do
    if active(name) then
      registry[name]:capture({put=function(_, path, data)
        assert(type(path) == 'string' and #path <= 128 and path:match('^[%w_.-]+$') and not path:find('..', 1, true),
          'Invalid captured state entry')
        assert(type(data) == 'string', 'Invalid captured state data')
        local key = name .. '/' .. path
        assert(entries[key] == nil, 'Duplicate captured state entry')
        count, bytes = count + 1, bytes + #data
        assert(count <= 4096 and bytes <= MAX_CAPTURE_BYTES, 'Required state capture exceeds save capacity')
        entries[key] = data
      end})
    end
  end
  return entries
end

function M.validateEmpty()
  local empty = {exists=function() return false end, get=function() error('No custom state in this save') end}
  for _, name in ipairs(names()) do
    if registry[name].validate then registry[name]:validate(empty) end
  end
end

function M.integrity()
  local result = {}
  for _, name in ipairs(names()) do
    local provider = M.providers[name]
    if provider and active(name) then
      local value = registry[name]:integrity()
      assert(type(value) == 'string' and #value > 0 and #value <= 256 and value:match('^[%w_.-]+$'),
        'Invalid state integrity digest: ' .. name)
      result[name] = {format=provider.format, fingerprint=provider.fingerprint, digest=value}
    end
  end
  return result
end

function M.contracts()
  local result = {}
  for name, provider in pairs(M.providers) do
    if active(name) then result[name] = {format=provider.format, fingerprint=provider.fingerprint} end
  end
  return result
end

local boundary
function M.observeBoundary()
  -- Publish only a complete observation. Errors cannot expose a stale success.
  boundary=nil
  local observed={}
  for _,name in ipairs(names()) do
    if active(name) then
      local callbacks,provider=registry[name],M.providers[name]
      local value={format=provider.format,fingerprint=provider.fingerprint}
      if callbacks.observeBoundary then
        callbacks:observeBoundary()
        value.capture=function() return callbacks:boundaryIntegrity() end
      else value.digest=callbacks:integrity() end
      observed[name]=value
    end
  end
  boundary=observed
end

function M.boundaryIntegrity()
  assert(boundary,'No complete required state boundary has been observed')
  local result={}
  for name,value in pairs(boundary) do
    local digest=value.capture and value.capture() or value.digest
    assert(type(digest)=='string' and #digest>0 and #digest<=256 and digest:match('^[%w_.-]+$'),
      'Invalid observed state digest: '..name)
    result[name]={format=value.format,fingerprint=value.fingerprint,digest=digest}
  end
  return result
end

M.names = names
return M
