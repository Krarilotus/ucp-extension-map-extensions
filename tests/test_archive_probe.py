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
