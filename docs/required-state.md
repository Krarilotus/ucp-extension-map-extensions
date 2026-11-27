# Required simulation state

Map Extensions 1.1.0 lets a module mark its part of a save as required.
Earlier AIC Tactics versions used this fingerprint-based contract to save active
AI recruitment rules and state. Current AIC Tactics uses the format-based
registration contract introduced in Map Extensions 1.2.1, which omits the
fingerprint. Improved Tunnelers saves active tunnel state. Recorder reads the
required sections when it records a game. Existing two-argument
`registerSection(name, callbacks)` calls, such as UCP2-Legacy's AI state section,
keep working. To mark a section as required, pass a third argument:

```lua
modules['map-extensions']:registerSection('my-module', callbacks, {
  required = true,
  format = 'my-state-1',
  fingerprint = packageSha256,
})
```

The module supplies `initialize`, `serialize`, `deserialize`, `validate`,
`capture` and `integrity` methods. `validate(readHandle)` must reject missing or
incompatible state before making any state change. All validators run before
the first deserialize callback. `capture(writeHandle)` must only read state;
it must not call native save, change simulation state, advance RNG or write files.
`integrity()` returns a bounded deterministic digest of simulation state. Recorder uses it
to compare state at checkpoints.

An optional read-only `isRequired()` predicate may return false when the module
has no active rules to restore. Its state remains an ordinary save section, but
does not require the module for saves or recording checkpoints that use only
the game's built-in rules.
Validators still run and must reject an unsafe missing-state restore. A manifest
that lists a module always requires that module and its original identity,
regardless of its current predicate result.
During validation `readHandle.required` identifies sections required by the saved
manifest; required payloads must be present even when the current policy is off.

`framework/required-state.yml` records the format and SHA256 package identity of
each required section. Missing modules and mismatched identities stop restore.
An older save without this manifest still invokes current validators; the module
decides whether native initialization is safe. Registered callbacks run by sorted
section name. Names and format IDs are restricted ASCII identifiers, sections
are limited to 256 and the manifest to 128 KiB. Read-only captures allow at most
4,096 flat entries and the existing custom-section byte capacity.

Recorders use API version 1: `requiredStateVersion()`,
`captureRequiredSections()`, `requiredStateContracts()` and
`requiredStateIntegrity()`. Capture returns the manifest and section entries
for the recorder's existing extension ZIP. Contracts and integrity results are
detached ordinary tables, declared in the module's proxy metadata so recorders
can iterate and serialize them in Lua and LuaJIT. Editing a returned table does
not change the module's state or later snapshots. No additional native save format,
ZIP implementation or simulation scan is introduced.

`observeRequiredStateBoundary()` retains the last complete recording checkpoint;
`requiredStateBoundaryIntegrity()` returns its digests even after live state has
changed. A module may supply paired `observeBoundary()` and
`boundaryIntegrity()` callbacks to defer hashing: the first copies into bounded
observation storage, the second hashes that copy. Modules without the pair
have their ordinary digest retained eagerly. Observation errors invalidate the
whole checkpoint. This storage never drives the simulation or replaces saved state.

Native game loaders and Map Extensions 1.0.0 cannot enforce this new manifest.
Loading required-state saves through those readers is unsupported. This API
also does not perform a multiplayer lobby handshake; peer content admission is
a separate responsibility. Source integration and acceptance status must be
reported separately before a release.
