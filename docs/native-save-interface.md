# Native save interface

`map-extensions:getNativeSaveInterface()` returns a detached version-1 descriptor
after Map Extensions has installed its native read/write hooks. It gives native
consumers the owner's discovered `packager`, `sections`, `sectionCount`,
`descriptorSize`, `readWorld` and `writeWorld` addresses/layout.

`readWorld` and `writeWorld` are the wrapped native entries, not the unwrapped
original functions. Call with the native thiscall ABI `(packager, sections)` so
Map Extensions retains validation, required providers and custom-section handling.
Never bypass those entries using an original trampoline or substitute the custom
section array yourself. The descriptor does not authorize concurrent or arbitrary
world reads/writes; Recorder retains its validated capture/restore lifecycle.

The function fails before installation and returns a fresh descriptor each time.
It performs no scans, hooks, allocation of game memory or save operation itself.
The addresses are captured from the same framework scans used to install the
existing Map Extensions hooks. Other extensions must not scan for the overwritten
entry prologues or maintain their own fixed address table.

Reuse investigation: `mapextensions/game.lua`, `memory.lua`, `helpers.lua` and
`init.lua` at 04449b7 already own the section table, packager and both hooks.
Recorder's `code/engine.lua` calls those wrapped entries, while `world-codec.lua`
and `world-layout.lua` consume the original section descriptors. Its current
private address profiles duplicate this owner state. This API exposes that
existing state without adding another save hook, parser or persistence service.

Validation: ten portable tests pass, including both Lua 5.4 and LuaJIT through
the actual framework proxy. They verify lifecycle errors, retained before/after
callbacks, original-to-custom section routing, detached metadata and zero extra
hooks/scans. `tests/check_native_save_interface.py` also verifies the five owner
signatures, native pointers and 122 descriptors on private Crusader 1.41 and
Extreme 1.41 images, with hook installation simulated. Run it with `--reference`,
`--variant SHC` or `--variant Extreme`, and `--output`; requirements are `pefile`
and `lupa`. Installed-game save/load and Recorder consumption are separate checks.
