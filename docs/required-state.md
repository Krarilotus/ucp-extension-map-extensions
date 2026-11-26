# Game state a save cannot do without

Most sections a module saves are optional: a save still loads if the module is
missing. Some modules, however, keep part of the running game in their section. AIC
Tactics keeps an army's target and its next wave; Improved Tunnelers keeps tunnels
that are still collapsing. Loading such a save without the required data can leave
the match in a state that the stock game cannot continue.

A module can mark its section as required:

```lua
modules['map-extensions']:registerSection('my-module', callbacks, {
  required = true,
  format = 'my-module-state',    -- stable format identifier
  schema = 2,                    -- schema written by this version
  acceptedSchemas = {1},         -- schemas the callbacks know how to migrate
  initializeOnMap = true,         -- optional, see "Maps" below
})
```

Without the third argument nothing changes: `registerSection(name, callbacks)` works
as before. A `fingerprint` field from older registrations is ignored.

A module can declare the optional policy explicitly with
`{required = false, fallback = 'vanilla'}`. Use it only when the native world
can continue without the module and its effects. The absent module's entries
are skipped, and a later save written without it does not carry those entries
forward. Existing required saves still require their registered provider.
A module that writes a section also declares it for the launcher; see
"Launcher declaration" below.

A required section needs `initialize`, `serialize`, `deserialize` and
`validate(handle)`. It may also have `isRequired()`, which returns false while the
module has nothing to keep (for example when its features are switched off). The
section is then still saved, but the save does not require the module.

## Launcher declaration: `save-state`

A module that registers a section says so in its `definition.yml`. The launcher
uses it to warn before the module is turned off, uninstalled or replaced by a
family switch. Map Extensions does not read the key: whether a save loads is
always decided by the save itself (provider, format and schema).

```yaml
save-state: required   # saves can need this module
```

| `save-state` | Registration | Loading a save without the module | Launcher warning |
| --- | --- | --- | --- |
| `required` | `registerSection(name, callbacks, {required = true, ...})`, also when `isRequired()` can return false | Refused at the Load action before the world is read; the dialog names the module and version and the game returns to the main menu | "Saves made with this module need it" |
| `optional` | `registerSection(name, callbacks)` or `{required = false, fallback = 'vanilla'}` | Loads; the module's entries are skipped and that part plays like the unmodded game. A later save drops them | "Saves made with this module lose its data without it" |
| no key | none | Unaffected | None |

- Declare one value. A module that can ever write a required section declares
  `required`, even if some settings make a particular save optional.
- The value describes the module's contract, not one save. It never refuses a
  load and never replaces the save's own list.
- Launchers and UCP versions that don't know the key ignore it, as they do with
  `tags`.
- Loading a multiplayer save made with a different set of modules, versions or
  settings is not advised, whatever the declarations say.

## Saving

Each save gets a list, `framework/required-state.yml`, with the required
providers, formats and schemas. The module version comes from
the active load order when the section and module names match. A differently
named provider can pass its package version in the registration's `version`.
Old entries that lack a schema are read as schema 1.

If anything fails before the game writes the file, the save is not written. An
existing file with that name stays as it was, the player sees a message, and the
match continues.

## Loading

1. On the single-player Load action (solitary and skirmish games, including a
   `.map` opened from Custom Scenarios, which uses the same call) Map Extensions
   checks the list before calling the native world reader. Each required
   provider must accept the format and saved schema. The dialog names the
   missing or incompatible module and saved version (the format identifier for
   older saves) and returns to the main menu. A file whose section cannot be
   read is refused the same way with a general message.
2. Every module's `validate(handle)` runs. It should check its data and raise an error
   if the data is missing or cannot be used. `handle.loadKind` is `'map'` or `'save'`;
   `handle.required` tells whether the saved list named this module.
   `handle.schema` is available to both callbacks so owners can validate and
   migrate older accepted data before applying it.
3. Only when all checks pass are the sections restored, in alphabetical order.

Everything else keeps the existing fatal path: multiplayer loads (they run inside
a synchrony command, so one player returning to the menu would leave the others
loading), the editor, campaign and skirmish map starts, which use other reader
callers, and any failure after the world reader has started, including a module's own
`validate(handle)` rejecting its data. On a game whose Load action Map Extensions does
not recognise, step 1 is off (a warning in the log) and every load takes this path.

Callbacks receive `{kind='map'}` or `{kind='save'}`: `initialize(context)`, and
`loadKind` on the handles. A file is a map when its name ends in `.map`. Do not use
the game tick to guess: maps saved in the editor can have a tick, too.

## Maps

A save renamed to `.map` becomes a new scenario. Sections registered with
`initializeOnMap = true` are not checked or restored for a map; `initialize` runs
instead, so the new scenario starts without the old battle's state. The saved list
records this, so the map also opens when that module is not installed. Other
sections keep their rules.

A required section also needs `capture(handle)` and `integrity()` for Recorder
(below). `capture` puts the same data as `serialize` but must not change anything;
`integrity` returns a short digest of the module's state.

## Feature checks

`requiredStateVersion()` and `requiredStateMapPolicyVersion()` return 1.
`getNativeSaveInterface()` returns `version=1`, `failureHandling=1` and
`readContext=1` after Map Extensions is enabled, plus the addresses below.

## For Recorder

Recorder takes snapshots and compares a replay with its recording without saving
the game. It uses:

- `captureSaveSection()`: the complete normal save ZIP for section 1337. This
  runs every registered writer. Optional providers can supply a read-only
  `capture(handle)` when ordinary `serialize(handle)` has side effects. A
  provider returning state from either callback must produce compatible bytes.
- `takeLoadRefusal()`: consumes the refused provider name after the native
  Load action, or `map-extensions` when the file could not be read. A caller
  must check this before attempting a second world read.

- `captureRequiredSections()`: copies of the list and of every required section;
- `requiredStateIntegrity()` and `requiredStateContracts()`: each module's digest
  and `format`;
- `observeRequiredStateBoundary()` and `requiredStateBoundaryIntegrity()`: the
  digests at one moment, kept until asked for. A module may supply
  `observeBoundary()` and `boundaryIntegrity()` to copy first and hash later;
- from `getNativeSaveInterface()`: the section table, the file packager and the two
  save functions. These are the functions with Map Extensions' hooks; calling them
  runs its callbacks. Never call the unhooked originals.

All of these return copies: changing them changes nothing in the modules.

## Not covered

The game itself and Map Extensions 1.0.x cannot read the list, so they load such
saves without these checks. This does not check what other players in a multiplayer
lobby have installed.
