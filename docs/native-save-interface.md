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

Since 1.1.4, `readContext=1` declares explicit native load context. `initialize`
receives `{kind='map'}` for `.map` paths (case-insensitive), otherwise
`{kind='save'}`. Validation/deserialization handles receive the same value as
`loadKind`. Direct required-state preflight has no file context. A provider must
not infer fresh-map admission from a zero game tick: maps can retain editor ticks.
This classification does not bypass saved provider manifests or payload validation.

The descriptor also exposes `resources`, `resourceFileName` and the original
20-byte `resourceFileNameBytes`. Map derives the resource manager and thiscall
filename getter from verified instructions inside its already discovered reader;
there is no extra scan or hook. The getter takes only the resource-manager `this`
argument and returns the current native filename pointer. Context capture calls
the shared entry so Recorder's scoped snapshot-path override remains effective.
Recorder verifies the owner's original bytes before installing that existing
override; it no longer resolves the same filename binding independently.

Reuse decision: Map `game.lua` at 2cd6312 owns the reader but lacks file context;
Files at 37894ee exports file enumeration/overrides, not the active read request.
Recorder `code/load-sites.lua` at fafaf7a already verifies the reader's `+0x44`
filename call and leaf getter. Moving that binding into Map closes the owner API
gap and removes the duplicate consumer resolution. The original native getter is
a read-only leaf; this runs only during file reads, never on simulation ticks.

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
