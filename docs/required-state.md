# Game state a save cannot do without

Most sections a module saves are optional: a save still loads if the module is
missing. Some modules, however, keep part of the running game in their section. AIC
Tactics keeps an army's target and its next wave; Improved Tunnelers keeps tunnels
that are still collapsing. Loading such a save without that data, or with data from
a different module version, gives a different game than the one that was saved.

A module can mark its section as required:

```lua
modules['map-extensions']:registerSection('my-module', callbacks, {
  required = true,
  format = 'my-module-state-1',   -- changes when the saved data changes shape
  fingerprint = moduleSha256,     -- SHA256 of the module's code
  initializeOnMap = true,         -- optional, see "Maps" below
})
```

Without the third argument nothing changes: `registerSection(name, callbacks)` works
as before.

A required section needs `initialize`, `serialize`, `deserialize` and
`validate(handle)`. It may also have `isRequired()`, which returns false while the
module has nothing to keep (for example when its features are switched off). The
section is then still saved, but the save does not require the module.

## Saving

Each save gets a short list, `framework/required-state.yml`, naming the modules whose
sections were required and their `format` and `fingerprint`.

If anything fails before the game writes the file, the save is not written. An
existing file with that name stays as it was, the player sees a message, and the
match continues.

## Loading

1. Map Extensions checks the list: every module named in it must be installed, with
   the same `format` and `fingerprint`.
2. Every module's `validate(handle)` runs. It should check its data and raise an error
   if the data is missing or cannot be used. `handle.loadKind` is `'map'` or `'save'`;
   `handle.required` tells whether the saved list named this module.
3. Only when all checks pass are the sections restored, in alphabetical order.

When a check fails, part of the game has already been replaced by the file's
contents; the game cannot continue in that state. Map Extensions shows the first line
of the error (keep it short and readable) and the game closes. The full error goes to
`ucp3-error-log.log`.

Callbacks receive `{kind='map'}` or `{kind='save'}`: `initialize(context)`, and
`loadKind` on the handles. A file is a map when its name ends in `.map`. Do not use
the game tick to guess: maps saved in the editor can have a tick, too.

## Maps

A save renamed to `.map` becomes a new scenario. Sections registered with
`initializeOnMap = true` are not checked or restored for a map; `initialize` runs
instead, so the new scenario starts without the old battle's state. The saved list
records this, so the map also opens when that module is not installed. Other
sections keep their rules.

## Feature checks

`requiredStateVersion()` and `requiredStateMapPolicyVersion()` return 1.
`getNativeSaveInterface()` returns `{version=1, failureHandling=1, readContext=1}`
after Map Extensions is enabled.

## Not covered

The game itself and Map Extensions 1.0.x cannot read the list, so they load such
saves without these checks. This does not check what other players in a multiplayer
lobby have installed.
