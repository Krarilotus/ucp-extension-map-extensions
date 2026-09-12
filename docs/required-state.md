# Required simulation state

Map Extensions 1.1.0 adds an opt-in contract to the existing save section owner.
Two-argument `registerSection(name, callbacks)` registrations keep their API.
Simulation providers register a third argument:

```lua
modules['map-extensions']:registerSection('my-module', callbacks, {
  required = true,
  format = 'my-state-1',
  fingerprint = packageSha256,
})
```

The provider supplies `initialize`, `serialize`, `deserialize`, `validate`,
`capture` and `integrity` methods. `validate(readHandle)` must reject missing or
incompatible state before making any state change. All validators run before
the first deserialize callback. `capture(writeHandle)` must only read state;
it must not call native save, change simulation state, advance RNG or write files.
`integrity()` returns a bounded deterministic digest of simulation state. It is
an observation hook, not a substitute for validation or package authentication.

An optional read-only `isRequired()` predicate may return false when the provider
has no active simulation policy. Its state remains an ordinary save section, but
does not impose a module requirement on Native-only saves or recording checkpoints.
Validators still run and must reject an unsafe missing-state restore. A manifest
that lists a provider always requires that provider and its original identity,
regardless of its current predicate result.
During validation `readHandle.required` identifies sections required by the saved
manifest; required payloads must be present even when the current policy is off.

`framework/required-state.yml` records the format and SHA256 package identity of
each required provider. Missing providers and mismatched identities stop restore.
An older save without this manifest still invokes current validators; the provider
decides whether native initialization is safe. Registered callbacks run by sorted
section name. Names and format IDs are restricted ASCII identifiers, providers
are limited to 256 and the manifest to 128 KiB. Read-only captures allow at most
4,096 flat entries and the existing custom-section byte capacity.

Recorders use API version 1: `requiredStateVersion()`,
`captureRequiredSections()`, `requiredStateContracts()` and
`requiredStateIntegrity()`. Capture returns the manifest and provider entries
for the recorder's existing extension ZIP. Contracts and integrity results are
copies; callers must not alter provider state. No additional native save format,
ZIP implementation or simulation scan is introduced.

`observeRequiredStateBoundary()` retains the last complete recorder boundary;
`requiredStateBoundaryIntegrity()` returns its digests even after live state has
changed. A provider may supply paired `observeBoundary()` and
`boundaryIntegrity()` callbacks to defer hashing: the first copies into bounded
observation storage, the second hashes that copy. Providers without the pair
have their ordinary digest retained eagerly. Observation errors invalidate the
whole boundary. This storage never drives the simulation or replaces saved state.

Native game loaders and Map Extensions 1.0.0 cannot enforce this new manifest.
Loading required-state saves through those readers is unsupported. This API
also does not perform a multiplayer lobby handshake; peer content admission is
a separate responsibility. Source integration and acceptance status must be
reported separately before a release.
