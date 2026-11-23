from pathlib import Path
import struct

import pytest
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


def container(payload, raw_size, compressed, *, offset=0, extra=False):
    directory = bytearray(3036)
    struct.pack_into('<4I', directory, 0, len(directory), len(payload), 1 + extra, 172)
    for field, value in ((32, raw_size), (632, len(payload)), (1232, 1337),
                         (1832, compressed), (2432, offset)):
        struct.pack_into('<I', directory, field, value)
    if extra:
        struct.pack_into('<I', directory, 1236, 1337)
    return struct.pack('<III', 0xffffffff, 4, 0) + bytes(4) + directory + payload


def probe(path):
    lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
    lua.globals().root = ROOT.as_posix().encode()
    lua.globals().path = path.as_posix().encode()
    return lua.execute(b'''
        package.path = root..'/?.lua;'..package.path
        local f = assert(io.open(path, 'rb'))
        local ok, data = pcall(require('mapextensions.archiveprobe').read, f, function(packed, size)
          assert(packed == 'compressed' and size == 30)
          return 'decoded'
        end)
        f:close()
        return ok, data
    ''')


@pytest.mark.parametrize(
    ('raw', 'expected'),
    [
        (container(b'binary\x00zip', 10, 0), b'binary\x00zip'),
        (container(b'compressed', 30, 1), b'decoded'),
        (struct.pack('<4I', 3036, 0, 0, 172) + bytes(3020), None),
        (struct.pack('<I', 2036) + bytes(2032), None),
    ],
)
def test_probe_locates_only_custom_data(tmp_path, raw, expected):
    path = tmp_path / 'world.sav'
    path.write_bytes(raw)
    assert probe(path) == (True, expected)


@pytest.mark.parametrize('raw', [
    container(b'compressed', 30, 1, offset=1),
    container(b'compressed', 30, 1, extra=True),
    container(b'compressed', 30, 1)[:-1],
])
def test_probe_refuses_invalid_directory_bounds(tmp_path, raw):
    path = tmp_path / 'world.sav'
    path.write_bytes(raw)
    assert not probe(path)[0]


def test_native_selected_save_uses_framework_read_only_file_operations():
    lua = LuaRuntime()
    lua.globals().root = ROOT.as_posix()
    lua.execute(r'''
      package.path = root..'/?.lua;'..package.path
      local path = 'C:\\User Documents\\Stronghold Crusader\\Saves\\test.sav'
      local position, closed = 0, false
      io.open = function() error('regular Lua files do not accept this game path') end
      io.openFileDescriptor = function(selected, flags, permissions)
        assert(selected==path and flags==0x8000 and permissions==0)
        return 5
      end
      io.ucrt = {
        _read = function(fd, address, size)
          assert(not closed and fd==5 and address==1200 and size==4)
          position=position+size
          return size
        end,
        _lseek = function(fd, offset, origin)
          assert(not closed and fd==5)
          position = (origin==2 and 20 or origin==0 and 0 or position) + offset
          return position
        end,
        _close = function(fd) assert(fd==5 and not closed); closed=true; return 0 end,
      }
      core={exposeCode=function(fn,_,abi) assert(abi==0); return fn end,
        readString=function(address,size) assert(address==1200 and size==4); return 'data' end}
      modules={cffi={cffi=function()
        return {new=function() return 1200 end, cast=function(_,value) return value end, tonumber=tonumber}
      end}}
      local file=require('mapextensions.archiveprobe').openGameSave(path)
      assert(file:seek('end')==20 and file:seek('set',0)==0)
      assert(file:read(4)=='data' and file:seek()==4)
      assert(file:close() and closed)
    ''')
