"""Check the owner's existing AoB bindings on a private licensed native image.

Hook installation is simulated; no game is launched and no save is written.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

import pefile
from lupa.lua54 import LuaRuntime


def check(reference, variant):
    root=Path(__file__).resolve().parents[1]
    raw=reference.read_bytes()
    pe=pefile.PE(data=raw)
    base=pe.OPTIONAL_HEADER.ImageBase
    image=bytearray(pe.get_memory_mapped_image())
    lua=LuaRuntime(unpack_returned_tuples=True)
    scans,installed=[],[]

    def scan(pattern):
        expression=b''.join(b'.' if t=='?' else re.escape(bytes([int(t,16)])) for t in pattern.split())
        matches=list(re.finditer(expression,image,re.DOTALL))
        assert len(matches)==1,(pattern,len(matches))
        address=base+matches[0].start()
        scans.append(address)
        return address

    def hook(address):
        installed.append(address)
        image[address-base:address-base+5]=b'\xe8\x11\x22\x33\x44'

    g=lua.globals()
    g.root=root.as_posix();g.scan=scan;g.mark_hook=hook
    g.read_int=lambda address:struct.unpack_from('<I',image,address-base)[0]
    lua.execute('''
package.path=root..'/?.lua;'..package.path
core={AOBScan=scan,readInteger=read_int,
 hookCode=function(_,address,count,convention,size)
  assert(count==2 and convention==1 and size==5); mark_hook(address)
  return function() error('Native save is outside this image check') end
 end,
 detourCode=function(_,address,size) assert(size==7);mark_hook(address) end}
CallingConvention={THISCALL=1}
game=require('mapextensions.game')
assert(not pcall(game.getNativeSaveInterface))
game.registerReadWriteSavHooks(0x70000000,123,{})
native=game.getNativeSaveInterface()
''')
    n=g.native
    expected={'SHC':(0xf2b3d0,0xb92a58,0x474a20,0x474480),
              'Extreme':(0xf2b850,0xb92be8,0x474c50,0x4746b0)}[variant]
    assert (n.packager,n.sections,n.readWorld,n.writeWorld)==expected
    assert len(scans)==5 and len(installed)==3
    assert n.readWorld in installed and n.writeWorld in installed
    assert n.version==1 and n.sectionCount==122 and n.descriptorSize==16
    descriptors=image[n.sections-base:n.sections-base+(n.sectionCount+1)*n.descriptorSize]
    assert descriptors[-16:]==bytes(16)
    entries=list(struct.iter_unpack('<IIIHH',descriptors[:-16]))
    assert all(address and size and skip==0 for address,skip,size,_,_ in entries)
    for _ in range(100):
        result=g.game.getNativeSaveInterface()
        assert result.readWorld==n.readWorld and result.sections==n.sections
    assert len(scans)==5 and len(installed)==3
    return {'variant':variant,'referenceSha256':hashlib.sha256(raw).hexdigest(),
            'ownerScans':len(scans),'existingHooks':len(installed),
            'nativeSections':len(entries),'repeatAccessesWithoutScans':100,
            'scope':'Native image discovery with simulated hooks; no installed save/load.'}


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--reference',type=Path,required=True)
    p.add_argument('--variant',choices=['SHC','Extreme'],required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    result=check(a.reference,a.variant)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
