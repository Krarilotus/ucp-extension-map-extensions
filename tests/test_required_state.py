"""Required sections: the saved list of modules and the checks made before restoring."""
from pathlib import Path
from lupa import LuaRuntime
import yaml

ROOT = Path(__file__).resolve().parents[1]


def runtime(runtime_type=LuaRuntime):
    lua = runtime_type(unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix()
    lua.globals().parse_yaml = lambda text: lua.table_from(yaml.safe_load(text), recursive=True)
    lua.execute('''
      package.path=root..'/?.lua;'..package.path
      log=function()end
      yaml={parse=function(text)return parse_yaml(text) end}
      registry={}
      package.loaded['mapextensions.registry']={registry=registry}
      required=require('mapextensions.required')
      writes,validates=0,0
      callbacks={initialize=function()writes=writes+1 end,
        serialize=function(_,handle)handle:put('state.bin','saved') end,
        deserialize=function()writes=writes+1 end,
        validate=function(_,handle)
          validates=validates+1
          assert(handle:exists('state.bin') and handle:get('state.bin')=='saved')
        end}
      function register(name)
        required.register(name,callbacks,{required=true,format='state-1',fingerprint=string.rep('a',64)})
        registry[name]=callbacks
      end
      -- What beforeWriteSav puts into a save: every section plus the list of modules.
      function archive()
        local entries={['framework/'..required.path]=required.manifest()}
        for _,name in ipairs(required.names()) do
          registry[name]:serialize({put=function(_,path,data) entries[name..'/'..path]=data end})
        end
        return entries
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


def test_sorted_list_and_every_check_before_any_restore():
    runtime().execute('''
      register('z');register('a')
      local entries=archive()
      local list=entries['framework/required-state.yml']
      assert(list:find('name: "a"') < list:find('name: "z"'))
      required.validate(zip(entries))
      assert(validates==2 and writes==0)
    ''')


def test_missing_changed_and_duplicate_modules_rejected_before_callbacks():
    runtime().execute('''
      register('a')
      local entries=archive()
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


def test_missing_data_is_still_checked_and_names_are_limited():
    runtime().execute('''
      register('a')
      assert(not pcall(required.validateEmpty) and writes==0)
      assert(not pcall(required.validate,zip({})) and writes==0)
      for _,name in ipairs({'../escape','framework',string.rep('a',129)}) do
        assert(not pcall(register,name))
      end
      assert(not pcall(required.register,'b',{serialize=callbacks.serialize},
        {required=true,format='x',fingerprint=string.rep('a',64)}))
    ''')


def test_a_module_with_nothing_to_keep_is_not_required():
    runtime().execute('''
      register('a')
      local saved=archive()
      registry.a.isRequired=function()return false end
      assert(required.manifest()=='version: 1\\nproviders: []\\n')
      required.validate(zip(saved)) -- A save that did require it still validates.
      required.providers.a.fingerprint=string.rep('b',64)
      assert(not pcall(required.validate,zip(saved)))
    ''')


def test_plain_sections_keep_working():
    runtime().execute('''
      required.register('plain',callbacks,nil)
      registry.plain=callbacks
      assert(required.manifest()=='version: 1\\nproviders: []\\n')
      assert(required.providers.plain==nil)
    ''')
