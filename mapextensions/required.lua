-- Sections a module marks as required: the save records which modules wrote them,
-- and loading checks all of them before any module restores its data.
local handles = require('mapextensions.handles')
local registry = require('mapextensions.registry').registry
local M = {providers = {}, path = 'required-state.yml'}
local MAX_PROVIDERS, MAX_MANIFEST = 256, 131072

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

function M.register(name, callbacks, options)
  if options == nil then return end
  assert(type(options) == 'table' and options.required == true,
    'Section options need required=true')
  assert(type(name) == 'string' and #name <= 128 and name ~= 'framework'
    and name:match('^[%w_-]+$'), 'Invalid required section name')
  local count = 0
  for _ in pairs(M.providers) do count = count + 1 end
  assert(count < MAX_PROVIDERS, 'Too many required sections')
  assert(type(options.format) == 'string' and #options.format > 0 and #options.format <= 128
    and options.format:match('^[%w_.-]+$'), 'Required sections need a format name')
  assert(type(options.fingerprint) == 'string' and #options.fingerprint == 64
    and options.fingerprint:match('^%x+$'), 'Required sections need a SHA256 fingerprint of the module')
  for _, method in ipairs({'initialize', 'serialize', 'deserialize', 'validate'}) do
    assert(type(callbacks[method]) == 'function', 'Required section needs ' .. method)
  end
  assert(callbacks.isRequired == nil or type(callbacks.isRequired) == 'function', 'Invalid isRequired')
  assert(options.initializeOnMap == nil or type(options.initializeOnMap) == 'boolean',
    'Invalid initializeOnMap')
  M.providers[name] = {format = options.format, fingerprint = options.fingerprint:lower(),
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
        .. '"\n    fingerprint: "' .. provider.fingerprint .. '"\n'
        .. (provider.initializeOnMap and '    initializeOnMap: true\n' or '')
    end
  end
  if #lines == 0 then return 'version: 1\nproviders: []\n' end
  return 'version: 1\nproviders:\n' .. table.concat(lines)
end

function M.validate(zip, context)
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
      assert(type(provider) == 'table' and type(provider.name) == 'string' and not seen[provider.name],
        'Invalid or duplicate entry in the required state list')
      seen[provider.name] = true
      local current = M.providers[provider.name]
      assert(provider.initializeOnMap == nil or type(provider.initializeOnMap) == 'boolean',
        'Invalid saved initializeOnMap')
      -- A save renamed to .map is a new scenario: sections that asked for it start fresh.
      if not (context and context.kind == 'map' and provider.initializeOnMap == true) then
        assert(current and registry[provider.name], 'This save needs the module ' .. provider.name)
        assert(current.format == provider.format and current.fingerprint == provider.fingerprint,
          'This save needs the version of ' .. provider.name .. ' it was made with')
      end
    end
  end
  -- Every module checks its data before the first one restores anything.
  for _, name in ipairs(names()) do
    local callbacks = registry[name]
    if callbacks.validate and not M.initializesOnMap(name, context) then
      local section = handles.createReadHandle(zip, name)
      section.required = seen[name] == true
      section.loadKind = context and context.kind
      callbacks:validate(section)
    end
  end
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

M.names = names
return M
