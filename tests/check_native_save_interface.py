"""Check Map Extensions' game bindings against licensed game executables.

For each .exe: every scan must match exactly once (core.AOBScan uses the first match),
the hooks must land on the functions those scans found, the buffer sizes must be found
inside them, and the file-name lookup must resolve. Hook installation is simulated; the
game is not started. Requires pefile and lupa.

python tests/check_native_save_interface.py "C:/Games/Stronghold Crusader.exe" ...
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

import pefile
from lupa.lua54 import LuaRuntime


def check(path):
    root = Path(__file__).resolve().parents[1]
    raw = path.read_bytes()
    pe = pefile.PE(data=raw)
    base = pe.OPTIONAL_HEADER.ImageBase
    image = bytearray(pe.get_memory_mapped_image())
    lua = LuaRuntime(unpack_returned_tuples=True, encoding='latin-1')
    scans, hooks, patched = {}, [], []

    def scan(pattern, start=None, stop=None):
        expression = b''.join(b'.' if t == '?' else re.escape(bytes([int(t, 16)])) for t in pattern.split())
        first = start - base if start is not None else 0
        last = stop - base if stop is not None else len(image)
        matches = list(re.compile(expression, re.DOTALL).finditer(image, first, last))
        assert len(matches) == 1, (pattern, len(matches))
        scans[pattern] = base + matches[0].start()
        return scans[pattern]

    def hook(address):
        hooks.append(address)

    g = lua.globals()
    g.root = root.as_posix(); g.scan = scan; g.mark_hook = hook
    g.mark_patch = lambda address, value: patched.append(address)
    g.read_int = lambda address: struct.unpack_from('<i', image, address - base)[0]
    g.read_byte = lambda address: image[address - base]
    g.read_string = lambda address, n: bytes(image[address - base:address - base + n])
    lua.execute('''
package.path=root..'/?.lua;'..package.path
log=function() end
core={AOBScan=scan,readInteger=read_int,readByte=read_byte,readString=read_string,
 writeCodeInteger=function(address,value) mark_patch(address,value) end,
 exposeCode=function(_,count,convention)
  assert((count==1 or count==6) and convention==1); return function() error('no native calls in this check') end
 end,
 hookCode=function(_,address,count,convention,size)
  assert(count==2 and convention==1 and size==5); mark_hook(address)
  return function() error('no native calls in this check') end
 end,
 detourCode=function(_,address,size) assert(size==7);mark_hook(address) end}
CallingConvention={THISCALL=1}
game=require('mapextensions.game')
game.enlargeMemoryAllocation(128000000)
game.registerReadWriteSavHooks(0x70000000,1337,{})
features=game.getNativeSaveInterface()
binding=require('mapextensions.readcontext').resolve(scan('83 EC 0C 53 56 8B F1 8B 46 20'))
call,cleanup=require('mapextensions.loadrefusal').resolve(features.readWorld,features.sections,features.packager)
require('mapextensions.archiveprobe').resolveDecoder()
''')
    read_world = scans['83 EC 0C 53 56 8B F1 8B 46 20']
    write_world = scans['83 EC 10 53 55 56 8B F1 8B 46 20']
    assert len(scans) == 8, sorted(scans)
    assert hooks[:2] == [read_world, write_world] and len(hooks) == 3
    assert patched == [read_world + 0x0D, write_world + 0x14]
    f = g.features
    assert (f.version, f.failureHandling, f.readContext) == (1, 1, 1)
    assert (f.readWorld, f.writeWorld, f.sectionCount, f.descriptorSize) == (read_world, write_world, 122, 16)
    packager = scans['B9 ? ? ? ? E8 ? ? ? ? B9 ? ? ? ? E8 ? ? ? ? 8B 44 24 14 ']
    assert f.packager == struct.unpack_from('<i', image, packager + 1 - base)[0]
    sections = scans[next(p for p in scans if p.startswith('? ? ? ? 00 00 00 00 20 74'))]
    descriptors = image[sections - base:sections - base + 123 * 16]
    assert descriptors[-16:] == bytes(16)
    entries = list(struct.iter_unpack('<IIIHH', descriptors[:-16]))
    assert all(address and size and skip == 0 for address, skip, size, _, _ in entries)
    assert f.sections == sections
    return {'file': str(path), 'sha256': hashlib.sha256(raw).hexdigest(),
            'uniqueScans': len(scans), 'hooks': len(hooks), 'nativeSections': len(entries),
            'readWorld': hex(read_world), 'writeWorld': hex(write_world),
            'fileNameGetter': hex(g.binding.resourceFileName),
            'loadCall': hex(g.call), 'loadCleanup': hex(g.cleanup)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('executables', type=Path, nargs='+')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    results = [check(path) for path in args.executables]
    text = json.dumps(results, indent=2)
    if args.output:
        args.output.write_text(text + '\n')
    print(text)
