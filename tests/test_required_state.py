from pathlib import Path
from lupa import LuaRuntime
import yaml

ROOT = Path(__file__).resolve().parents[1]


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.globals().parse_yaml = lambda text: lua.table_from(yaml.safe_load(text), recursive=True)
    lua.execute('''
      package.path=root..'/?.lua;'..package.path
      log=function()end
      yaml={parse=function(text)return parse_yaml(text) end}
      registry={}
      package.loaded['mapextensions.registry']={registry=registry}
      required=require('mapextensions.required')
      writes,validates,captures=0,0,0
      callbacks={initialize=function()writes=writes+1 end,
        serialize=function()writes=writes+1 end,deserialize=function()writes=writes+1 end,
        validate=function(_,handle)
          validates=validates+1
          assert(handle:exists('state.bin') and handle:get('state.bin')=='saved')
        end,
        capture=function(_,handle)captures=captures+1;handle:put('state.bin','saved') end,
        integrity=function()return 'state-digest-1' end}
      function register(name)
        required.register(name,callbacks,{required=true,format='state-1',fingerprint=string.rep('a',64)})
        registry[name]=callbacks
      end
      function zip(entries)
        local current
        return {open_entry=function(_,name)
          assert(current==nil,'previous entry left open')
          if entries[name]==nil then return false end
          current=name;return true
        end,read_entry=function()return entries[current] end,
        close_entry=function()current=nil;return true end}
      end
    ''')
    return lua


def test_read_only_capture_sorted_manifest_and_contract_copies():
    runtime().execute('''
      register('z');register('a')
      local entries=required.capture()
      assert(entries['a/state.bin']=='saved' and entries['z/state.bin']=='saved')
      assert(entries['framework/required-state.yml']:find('name: "a"') < entries['framework/required-state.yml']:find('name: "z"'))
      assert(captures==2 and writes==0)
      required.validate(zip(entries))
      assert(validates==2 and writes==0)
      local contracts=required.contracts();contracts.a.format='changed'
      assert(required.contracts().a.format=='state-1')
      assert(required.integrity().a.digest=='state-digest-1')
    ''')


def test_missing_changed_and_duplicate_providers_rejected_before_callbacks():
    runtime().execute('''
      register('a')
      local entries=required.capture()
      local path='framework/required-state.yml'
      local original=entries[path]
      for _,invalid in ipairs({original:gsub('name: "a"','name: "missing"'),
          original:gsub('state%-1','state-2'),original:gsub(string.rep('a',64),string.rep('b',64)),
          original..original:match('  %- name:.*'),string.rep(' ',131073)}) do
        entries[path]=invalid
        assert(not pcall(required.validate,zip(entries)))
        assert(validates==0 and writes==0)
      end
    ''')


def test_absent_state_still_validated_and_capture_limits_enforced():
    runtime().execute('''
      register('a')
      assert(not pcall(required.validateEmpty) and writes==0)
      assert(not pcall(required.validate,zip({})) and writes==0)
      for _,name in ipairs({'../escape','framework',string.rep('a',129)}) do
        assert(not pcall(register,name))
      end
      registry.a.capture=function(_,handle)handle:put('../escape','x') end
      assert(not pcall(required.capture))
      registry.a.capture=function(_,handle)handle:put('same','x');handle:put('same','x') end
      assert(not pcall(required.capture))
      registry.a.integrity=function()return string.rep('x',257) end
      assert(not pcall(required.integrity))
    ''')


def test_inactive_policy_does_not_require_module_for_native_saves():
    runtime().execute('''
      register('a')
      local saved=required.capture()
      registry.a.isRequired=function()return false end
      assert(next(required.contracts())==nil and next(required.integrity())==nil)
      assert(required.capture()['a/state.bin']==nil)
      assert(required.manifest()=='version: 1\\nproviders: []\\n')
      required.validate(zip(saved)) -- A previously required save still validates.
      required.providers.a.fingerprint=string.rep('b',64)
      assert(not pcall(required.validate,zip(saved)))
    ''')
