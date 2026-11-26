-- Sections a module marks as required: the save records which modules wrote them,
-- and loading checks all of them before any module restores its data.
local handles = require('mapextensions.handles')
local registry = require('mapextensions.registry').registry
local M = {providers = {}, path = 'required-state.yml'}
local MAX_PROVIDERS, MAX_MANIFEST = 256, 131072
local MAX_CAPTURE_BYTES = require('mapextensions.constants').CUSTOM_SECTION_SIZE
local missingOwner = {}

function M.missingOwner(reason)
  if type(reason) == 'table' and reason.kind == missingOwner then return reason.name, reason.version end
end

local function validSchema(schema)
  return type(schema) == 'number' and schema >= 1 and schema <= 65535 and schema == math.floor(schema)
end

local function validVersion(value)
  return type(value) == 'string' and #value <= 64 and value:match('^[%w.+-]+$')
end

local function savedVersion(handle, provider)
  if provider.moduleVersion then return provider.moduleVersion end
  -- Earlier manifests did not include a package version. Normal saves already
  -- carried it in the framework load order.
  if handle:exists('extensions.yml') then
    local ok, version = pcall(function()
      local raw = handle:get('extensions.yml')
      if #raw > MAX_MANIFEST then return end
      local loadOrder = yaml.parse(raw)
      for _, extension in ipairs(loadOrder) do
        if extension.extension == provider.name and validVersion(extension.version) then
          return extension.version
        end
      end
    end)
    if ok and version then return version end
  end
  return provider.format
end

local function names()
  local result = {}
  for name in pairs(registry) do result[#result + 1] = name end
  table.sort(result)
  return result
end

-- A module may say it has nothing to keep right now (isRequired returns false).
-- Its section is then still saved, but the save does not require the module.
local function active(name)
  local callbacks = registry[name]
  if not callbacks or not M.providers[name] then return false end
  if not callbacks.isRequired then return true end
  local value = callbacks:isRequired()
  assert(type(value) == 'boolean', 'isRequired must return true or false')
  return value
end

function M.serializer(name, capture)
  local callbacks = registry[name]
  if capture and callbacks.capture then
    return callbacks.capture
  end
  return callbacks.serialize
end

function M.register(name, callbacks, options)
  if options == nil then return end
  if type(options) == 'table' and options.required == false and options.fallback == 'vanilla' then
    return
  end
  assert(type(options) == 'table' and options.required == true,
    'Section options need required=true')
  assert(type(name) == 'string' and #name <= 128 and name ~= 'framework'
    and name:match('^[%w_-]+$'), 'Invalid required section name')
  local count = 0
  for _ in pairs(M.providers) do count = count + 1 end
  assert(count < MAX_PROVIDERS, 'Too many required sections')
  assert(type(options.format) == 'string' and #options.format > 0 and #options.format <= 128
    and options.format:match('^[%w_.-]+$'), 'Required sections need a format name')
  -- capture and integrity serve Recorder: a copy of the data and a digest of it.
  for _, method in ipairs({'initialize', 'serialize', 'deserialize', 'validate', 'capture', 'integrity'}) do
    assert(type(callbacks[method]) == 'function', 'Required section needs ' .. method)
  end
  assert(callbacks.isRequired == nil or type(callbacks.isRequired) == 'function', 'Invalid isRequired')
  assert((callbacks.observeBoundary == nil and callbacks.boundaryIntegrity == nil)
    or (type(callbacks.observeBoundary) == 'function' and type(callbacks.boundaryIntegrity) == 'function'),
    'observeBoundary and boundaryIntegrity go together')
  assert(options.initializeOnMap == nil or type(options.initializeOnMap) == 'boolean',
    'Invalid initializeOnMap')
  local schema = options.schema or 1
  assert(validSchema(schema), 'Invalid section schema')
  assert(options.version == nil or validVersion(options.version), 'Invalid module version')
  local version = options.version
  for _, extension in ipairs(allActiveExtensions or {}) do
    if not version and extension.name == name and validVersion(extension.version) then version = extension.version end
  end
  local accepted = {[schema] = true}
  for _, oldSchema in ipairs(options.acceptedSchemas or {}) do
    assert(validSchema(oldSchema) and oldSchema < schema, 'Invalid older section schema')
    accepted[oldSchema] = true
  end
  M.providers[name] = {format = options.format, schema = schema, accepted = accepted, version = version,
    initializeOnMap = options.initializeOnMap == true}
end

function M.initializesOnMap(name, context)
  return context and context.kind == 'map' and M.providers[name]
    and M.providers[name].initializeOnMap == true
end

-- framework/required-state.yml: which modules a save needs, and in which version.
function M.manifest()
  local lines = {}
  for _, name in ipairs(names()) do
    local provider = M.providers[name]
    if provider and active(name) then
      lines[#lines + 1] = '  - name: "' .. name .. '"\n    format: "' .. provider.format
        .. '"\n    schema: ' .. provider.schema .. '\n'
        .. (provider.version and '    moduleVersion: "' .. provider.version .. '"\n' or '')
        .. (provider.initializeOnMap and '    initializeOnMap: true\n' or '')
    end
  end
  if #lines == 0 then return 'version: 1\nproviders: []\n' end
  return 'version: 1\nproviders:\n' .. table.concat(lines)
end

function M.admit(zip, context)
  local handle = handles.createReadHandle(zip, 'framework')
  local seen = {}
  if handle:exists(M.path) then
    local data = handle:get(M.path)
    assert(type(data) == 'string' and #data <= MAX_MANIFEST, 'Required state list is too large')
    local saved = yaml.parse(data)
    assert(type(saved) == 'table' and saved.version == 1 and type(saved.providers) == 'table',
      'Unsupported required state list')
    local count = 0
    for index in pairs(saved.providers) do
      assert(type(index) == 'number' and index >= 1 and index == math.floor(index), 'Invalid required state list')
      count = count + 1
    end
    assert(count == #saved.providers and count <= MAX_PROVIDERS, 'Invalid required state list')
    for _, provider in ipairs(saved.providers) do
      assert(type(provider) == 'table' and type(provider.name) == 'string' and #provider.name <= 128
        and provider.name:match('^[%w_-]+$') and not seen[provider.name],
        'Invalid or duplicate entry in the required state list')
      local schema = provider.schema or 1
      assert(validSchema(schema) and type(provider.format) == 'string' and #provider.format <= 128
        and provider.format:match('^[%w_.-]+$')
        and (provider.moduleVersion == nil or validVersion(provider.moduleVersion)),
        'Invalid saved provider version')
      seen[provider.name] = schema
      local current = M.providers[provider.name]
      assert(provider.initializeOnMap == nil or type(provider.initializeOnMap) == 'boolean',
        'Invalid saved initializeOnMap')
      -- A save renamed to .map is a new scenario: sections that asked for it start fresh.
      if not (context and context.kind == 'map' and provider.initializeOnMap == true) then
        if not (current and registry[provider.name] and current.format == provider.format
          and current.accepted[schema]) then
          error({kind = missingOwner, name = provider.name,
            version = savedVersion(handle, provider)}, 0)
        end
      end
    end
  end
  return seen
end

function M.validate(zip, context)
  local seen = M.admit(zip, context)
  -- Every module checks its data before the first one restores anything.
  for _, name in ipairs(names()) do
    local callbacks = registry[name]
    if callbacks.validate and not M.initializesOnMap(name, context) then
      local section = handles.createReadHandle(zip, name)
      section.required = seen[name] ~= nil
      section.schema = seen[name]
      section.loadKind = context and context.kind
      callbacks:validate(section)
    end
  end
  return seen
end

-- For Recorder: copies of the required sections, without saving the game.
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

-- A file without any custom section: modules can still refuse it, e.g. a save
-- made before the module kept its state.
function M.validateEmpty(context)
  local empty = {loadKind = context and context.kind,
    exists = function() return false end, get = function() error('No custom data in this file') end}
  for _, name in ipairs(names()) do
    if registry[name].validate and not M.initializesOnMap(name, context) then
      registry[name]:validate(empty)
    end
  end
end

-- For Recorder: digests to compare a replay with its recording.
function M.integrity()
  local result = {}
  for _, name in ipairs(names()) do
    local provider = M.providers[name]
    if provider and active(name) then
      local value = registry[name]:integrity()
      assert(type(value) == 'string' and #value > 0 and #value <= 256 and value:match('^[%w_.-]+$'),
        'Invalid state integrity digest: ' .. name)
      result[name] = {format=provider.format, digest=value}
    end
  end
  return result
end

function M.contracts()
  local result = {}
  for name, provider in pairs(M.providers) do
    if active(name) then result[name] = {format=provider.format} end
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
      local value={format=provider.format}
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
    result[name]={format=value.format,digest=digest}
  end
  return result
end

M.names = names
return M
