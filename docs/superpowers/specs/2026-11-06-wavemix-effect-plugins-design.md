# Wavemix Effect Plugins — Design

- **Date:** 2026-11-06
- **Status:** Draft for review
- **Target release:** Wavemix 1.1.0
- **Scope:** microphone effects chain

## Intent

Replace the hardcoded single RNNoise mic filter with a plugin-based effect
chain. Effects are native PipeWire filter-chain nodes (LADSPA, LV2, or
builtin), described by versioned manifests. Users can add, remove, reorder,
bypass, and combine effects, and tune each effect's controls live.

The output mix can also be duplicated to any number of selected hardware
outputs. Each channel's output send creates one loopback per selected output;
one channel fader controls every copy, so speakers and headphones receive the
same mix.

This also gives GPU noise suppression a path: NVIDIA Maxine and DeepFilterNet
already ship LADSPA plugins, so they are normal effect manifests. Wavemix does
not bundle proprietary GPU runtimes or implement DSP itself.

## Goals

- Run an ordered chain of microphone effects in one PipeWire filter-chain.
- Add, remove, reorder, and bypass effects from the Effects popup and CLI.
- Change effect controls live without restarting PipeWire.
- Discover bundled and user-installed effect manifests.
- Support LADSPA, LV2, and builtin nodes, including GPU-backed LADSPA plugins.
- Track core, manifest, plugin, and state versions.
- Play the same output mix to any number of selected hardware outputs.
- Keep one per-channel output fader controlling every output copy.
- Preserve the existing mic bus, virtual mic, per-channel meters, and routing.
- Keep the current RNNoise controls working through migration.

## Non-goals

- External process or daemon plugins (EasyEffects, `maxine-pipewire` daemon).
- Effects on channels or sends other than the microphone.
- Independent volume or mute per output; multi-output uses one shared send
  level.
- Per-channel output-device routing.
- Bundling proprietary GPU runtimes or models.
- Stereo or multi-channel microphone effect chains; the mic chain is mono.
- Presets, update checking, or a plugin marketplace.
- Hot structural chain changes without a PipeWire restart.
- Custom DSP/GPU code inside Wavemix.

## Current state

- `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf` is a hand-written
  filter-chain with one RNNoise LADSPA node.
- `~/.config/wavemix/state.json` stores `micFx.enabled` and
  `micFx.controls`.
- `wavemix micfx controls|set` reads and writes the live RNNoise controls.
- The Effects popup is currently a Noise Suppression popup.
- `up()` links the hardware mic to `wavemix_micfx.capture` and the chain output
  to `wavemix_micbus`; `mic_source()` uses `wavemix_micbus.monitor` when mic FX
  is enabled.
- A single physical output (`devices.output`) receives every channel's output
  send.

## Architecture

```text
hardware mic
   │
   ▼
wavemix_micfx.capture          filter-chain input stream
   │
 fx0 ──► fx1 ──► fx2 ...      enabled effect nodes, in chain order
   │
   ▼
wavemix_micfx                  filter-chain output stream
   │
   ▼
wavemix_micbus → Wavemix-Mic
```

- The chain is compiled into **one** `libpipewire-module-filter-chain` module.
- Internal nodes are named `fx0`, `fx1`, … to keep config quoting simple and
  to decouple node names from user-editable instance ids.
- The external capture/playback names stay `wavemix_micfx.capture` and
  `wavemix_micfx`, so `up()`, the mic bus, and the meters do not change.
- The chain is mono: `audio.position = [ MONO ]`. The mono playback is linked
  to every `wavemix_micbus` playback channel by the existing
  `set_mic_fx_playback_link()`.
- Only enabled, available instances are compiled. Disabled or unavailable
  instances are skipped.
- Structural changes (add, remove, reorder, bypass, manifest availability)
  regenerate the config and restart PipeWire briefly.
- Control changes use `pw-cli set-param` on the live node and rewrite the
  config for the next restart, without interrupting audio.

### Multi-device output

```text
channel capture ──loopback──> output A
                └─loopback──> output B
                └─loopback──> output C
```

- `devices.outputs` is the ordered list of selected hardware outputs.
  `devices.output` remains the first/primary output for backward
  compatibility and default-sink handling.
- Each channel's `output` send creates one loopback per selected output. The
  input send remains a single loopback to the stream bus.
- The per-channel output fader and mute apply to every output copy through the
  shared `wavemix=<channel>:output` stream tag.
- The mix is identical on every selected output; there is no per-output
  volume in v1.
- Adding or removing an output rebuilds the graph with `up()`; existing
  channels gain or lose the corresponding loopback.
- At least one output must stay selected. Removing the last output is
  rejected. A vanished or virtual output is removed during sanitization and
  replaced by the default hardware sink if the list would become empty.
- The speaker mute toggles every selected output: `output` is considered
  muted only when all selected outputs are muted; toggling mutes all when any
  is live, or unmutes all when all are muted.
- `status` reports the selected output targets and whether every target has a
  live loopback.

## Versioning and compatibility

### Core version

- `VERSION` at the repo root contains the release version, starting at
  `1.1.0`.
- `bin/wavemix` carries `WAVEMIX_VERSION = "1.1.0"`; a unit test asserts it
  matches `VERSION`.
- `wavemix --version` prints `wavemix 1.1.0`.
- `wavemix fx plugins --json` and `wavemix fx state --json` include
  `wavemixVersion`.
- The Omarchy plugin manifest version is bumped to `1.1.0` in the same release.
- `CHANGELOG.md` records the release, and the release commit is tagged
  `v1.1.0`.

### Manifest versions

Every effect manifest declares:

- `schemaVersion`: manifest schema, currently `1`.
- `version`: the plugin definition's semantic version, e.g. `"1.0.0"`.
- `minWavemix`: the oldest core version that can load it; defaults to
  `"1.1.0"` when omitted.

Rules:

- A manifest with an unsupported `schemaVersion` is listed as unavailable with
  an error and never compiled.
- A manifest whose `minWavemix` is newer than `WAVEMIX_VERSION` is listed as
  unavailable with an error.
- Versions are simple numeric `MAJOR.MINOR.PATCH` strings. Pre-release suffixes
  are not part of v1 compatibility checks.
- `fx add` records the manifest's `version` on the instance as
  `pluginVersion`.
- If the manifest version later differs from `pluginVersion`, `fx state`
  reports `versionChanged: true`; the UI warns that the definition changed.
  Existing control values are kept by key, new controls use manifest defaults,
  and removed controls are ignored.

### State version

`state.json` moves from `"version": 1` to `"version": 2`. A missing version is
treated as `1`.

- Reading a v1 state migrates it in memory:
  - `micFx.controls` becomes the controls of a `rnnoise-1` instance.
  - If no controls exist, the default chain is built from manifests with
    `default: true`.
  - The migrated state is written as version 2 on the next mutation.
- A state version newer than the binary supports is not overwritten; the CLI
  exits with an error asking the user to update Wavemix.
- Unknown fields are preserved when saving.

## Plugin manifests

### Locations and precedence

- Bundled: `~/.local/share/wavemix/plugins/*.json`
- User: `~/.config/wavemix/plugins/*.json`

The CLI scans bundled manifests first, then user manifests. A user manifest
with the same `id` replaces the bundled one. Both directories are local; no
network access or automatic downloads.

### Manifest schema

```json
{
  "schemaVersion": 1,
  "id": "rnnoise",
  "version": "1.0.0",
  "minWavemix": "1.1.0",
  "name": "RNNoise",
  "description": "RNN noise suppression with a VAD gate",
  "type": "ladspa",
  "plugin": "/usr/lib/ladspa/librnnoise_ladspa.so",
  "label": "noise_suppressor_mono",
  "input": "Input",
  "output": "Output",
  "config": {},
  "gpu": false,
  "requires": "",
  "default": true,
  "allowMultiple": true,
  "controls": [
    {
      "key": "vadThreshold",
      "param": "VAD Threshold (%)",
      "label": "VAD threshold",
      "min": 0,
      "max": 99,
      "step": 1,
      "unit": "%",
      "default": 50,
      "integer": true,
      "raw_float": false,
      "scale": 1
    }
  ]
}
```

Required fields: `schemaVersion`, `id`, `version`, `name`, `type`, `input`,
`output`, `controls`.

Field rules:

| Field | Meaning |
| --- | --- |
| `id` | Lowercase slug: `[a-z0-9_]+`. Unique across bundled + user manifests. |
| `version` | Plugin definition version, numeric `MAJOR.MINOR.PATCH`. |
| `minWavemix` | Minimum core version; defaults to `1.1.0`. |
| `type` | `ladspa`, `lv2`, or `builtin`. |
| `plugin` | LADSPA `.so` path or LV2 URI. Ignored for builtin. `~` and `$HOME` in LADSPA paths are expanded by Wavemix. |
| `label` | LADSPA label or builtin label. Required for LADSPA and builtin; optional for LV2. |
| `input` / `output` | Mono audio port names, without the node prefix. |
| `config` | Optional static filter config passed through to the node. |
| `gpu` | UI/CLI badge and metadata; does not change compilation. |
| `requires` | Human-readable install hint shown when the plugin is unavailable. |
| `default` | Include in the default chain when no state chain exists. |
| `allowMultiple` | Whether more than one instance of the plugin is allowed. Defaults to `true`. |
| `controls` | Array of control metadata; may be empty. |

Control fields:

| Field | Meaning |
| --- | --- |
| `key` | Stable state key, lowercase slug. |
| `param` | LADSPA/LV2/builtin control port name. `pw-cli` sees it as `<node>:<param>`. |
| `label` | Display label. |
| `min`, `max`, `step` | Slider range and step in display units. |
| `unit` | Suffix such as `%`, ` ms`, ` dB`, or `""`. |
| `default` | Display-unit default. |
| `integer` | Whether the display value is an integer. |
| `raw_float` | Whether the raw plugin value is a float even when the display is integer. |
| `scale` | `raw = display / scale`; defaults to `1`. Dry Mix uses `scale: 100`. |

Validation failures mark only that manifest unavailable; they do not prevent
the rest of the chain from loading. Validation checks:

- required fields present and of the right type
- ids and control keys are slugs
- `type` is known
- `version` and `minWavemix` parse as numeric versions
- control ranges are finite and `min <= max`, `step > 0`, `scale > 0`
- input/output are non-empty
- duplicate ids within a directory are rejected deterministically (first by
  filename, with an error on the duplicate)

### Bundled manifests

- `rnnoise.json` — existing RNNoise LADSPA plugin, `default: true`, same four
  controls as today.
- `highpass.json` — builtin `bq_highpass`, input `In`, output `Out`, controls
  `Freq` (20–500 Hz, default 80, step 5) and `Q` (0.1–5, default 0.707,
  step 0.1, non-integer).
- `noisegate.json` — builtin `noisegate`, input `In`, output `Out`, controls:
  `Open Threshold` (0–1, default 0.04, step 0.01),
  `Close Threshold` (0–1, default 0.03, step 0.01),
  `Attack (s)` (0–1, default 0.005, step 0.001),
  `Hold (s)` (0–1, default 0.05, step 0.001),
  `Release (s)` (0–1, default 0.01, step 0.001).
- `deepfilternet.json` — `/usr/lib/ladspa/libdeep_filter_ladspa.so`, label
  `deep_filter_mono`, ports `Audio In` / `Audio Out`, control
  `Attenuation Limit (dB)` (0–100, default 100). Marked `gpu: false`;
  `requires` tells the user to install `deepfilternet-ladspa`.
- `maxine-denoise.json` — LADSPA manifest for the NVIDIA Maxine wrapper,
  `~/.local/lib/ladspa/libmaxine_ladspa.so`, label `maxine_denoiser_mono`,
  ports `Input L` / `Output L`, control `Intensity` (0.0–1.0, default 1.0),
  `gpu: true`, and a `requires` hint for the Maxine runtime. It is bundled so
  the install hint is discoverable; users with a different package path or
  label can override it with a user manifest.

DeepFilterNet and Maxine are optional: when their plugin files or runtime are
missing, the manifests remain visible in the plugin list with an install hint
and cannot be added until available.

Operational notes:

- PipeWire only loads LADSPA plugins that are under its `LADSPA_PATH`. If the
  Maxine package installs to `~/.local/lib/ladspa`, that directory must be
  added to the PipeWire user environment; the manifest's `requires` text says
  so.
- DeepFilterNet and Maxine may need a larger PipeWire quantum for glitch-free
  real-time processing. That tuning stays in a separate PipeWire drop-in and
  is not managed by Wavemix in v1.

## State model

The state gains `version: 2` and a chain:

```json
{
  "version": 2,
  "devices": {
    "output": "alsa_output.usb-speakers",
    "outputs": [
      "alsa_output.usb-speakers",
      "alsa_output.pci-headphones"
    ],
    "input": "alsa_input.usb-mic"
  },
  "micFx": {
    "enabled": true,
    "chain": [
      {
        "id": "rnnoise-1",
        "plugin": "rnnoise",
        "pluginVersion": "1.0.0",
        "enabled": true,
        "controls": {
          "vadThreshold": 50,
          "vadGrace": 200,
          "retroactiveGrace": 0,
          "dryMix": 0
        }
      },
      {
        "id": "noisegate-1",
        "plugin": "noisegate",
        "pluginVersion": "1.0.0",
        "enabled": false,
        "controls": {}
      }
    ]
  }
}
```

- `micFx.enabled` remains the master switch.
- `devices.outputs` is the ordered selected-output list; `devices.output` is
  its first entry. A missing or empty list migrates to `[devices.output]`.
- Chain array order is processing order.
- `enabled: false` is a bypass: the instance is kept but excluded from the
  compiled chain.
- `id` is unique and stable. New instances use `<plugin-id>-<n>`, where `n` is
  the lowest positive integer not already used.
- `pluginVersion` records the manifest version at add time.
- Controls are display-unit values keyed by the manifest's control `key`.
  Missing controls use the manifest default; unknown keys are ignored.
- If the chain is missing, the default chain is built from manifests with
  `default: true`. If none exist, the chain is empty.
- An empty chain or a disabled master means the mic bypasses effects and uses
  the raw-mic feed.

## Chain compilation

For the enabled, available instances in order:

1. Assign node names `fx0`, `fx1`, ….
2. Emit one graph node per instance with the manifest's `type`, `plugin`,
   `label`, `config`, and control values converted from display to raw:
   - `raw = display / scale`
   - integer raw values are rounded to integers
   - non-integer display values and `raw_float` controls are written as floats
3. Emit `links` between adjacent nodes:
   `{ output = "fxN:<output>", input = "fx(N+1):<input>" }`
4. Emit `inputs = [ "fx0:<input>" ]` and
   `outputs = [ "fxN:<output>" ]`.

Generated config shape:

```conf
# Generated by Wavemix. Do not edit by hand; use `wavemix fx`.
context.modules = [
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "Wavemix FX"
      media.name = "Wavemix FX"
      filter.graph = {
        nodes = [
          { type = ladspa name = fx0 plugin = "/usr/lib/ladspa/librnnoise_ladspa.so"
            label = noise_suppressor_mono
            control = { "VAD Threshold (%)" = 50 } }
          { type = builtin name = fx1 label = bq_highpass
            control = { "Freq" = 80 "Q" = 0.707 } }
        ]
        links = [
          { output = "fx0:Output" input = "fx1:In" }
        ]
        inputs = [ "fx0:Input" ]
        outputs = [ "fx1:Out" ]
      }
      audio.rate = 48000
      audio.position = [ MONO ]
      capture.props = {
        node.name = "wavemix_micfx.capture"
        node.autoconnect = false
        node.passive = true
      }
      playback.props = {
        node.name = "wavemix_micfx"
        node.autoconnect = false
        node.passive = true
      }
    }
  }
]
```

- The generated file is written atomically to
  `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`.
- If the existing file lacks the generated marker, back it up once to
  `90-wavemix-micfx.conf.bak-<timestamp>` before the first replacement.
- If the chain is empty, the generated file contains only the marker and a
  comment, and no module is loaded. The mic uses the raw feed.
- The config is generated from state on install, on structural changes, and
  on `up()`. `up()` renders but never restarts PipeWire.
- Structural changes restart `pipewire`, `pipewire-pulse`, and `wireplumber`
  with `systemctl --user restart` so the new graph loads.

## Live controls

- After compilation, instance `I` maps to node `fxN` at the same position
  among enabled instances.
- `wavemix fx set <instance> <control> <value>`:
  - clamps the value to the manifest range
  - stores the display value in state
  - finds the live `wavemix_micfx.capture` node
  - writes with
    `pw-cli set-param <id> Props '{ params = ["fxN:<param>" <raw>] }'`
  - rewrites the config without restarting
  - reports `applied: false` when the node is missing, but still stores the
    value for the next restart
- `up()` reapplies stored control values to the live nodes when they exist.
- Live controls for a bypassed instance are stored but not applied until it is
  enabled.

## CLI

```sh
wavemix --version
wavemix fx plugins [--json]
wavemix fx state [--json]
wavemix fx add <plugin-id> [--index N]
wavemix fx remove <instance-id>
wavemix fx move <instance-id> up|down
wavemix fx toggle <instance-id>
wavemix fx set <instance-id> <control> <value>
wavemix fx enable|disable
wavemix fx render
wavemix fx apply
```

Behavior:

- `fx render` writes the generated config without restarting PipeWire.
- `fx apply` renders and restarts PipeWire; it is the retry path after a
  failed restart.

- `fx plugins` lists every manifest with `id`, `name`, `description`,
  `version`, `schemaVersion`, `minWavemix`, `source` (`bundled` or `user`),
  `available`, `gpu`, `requires`, and `error`.
- `fx state` adds `wavemixVersion`, `micFx.enabled`, `running`, the chain, the
  plugin list, and per-instance control values. `running` means the
  `wavemix_micfx.capture` node exists.
- `fx add`:
  - rejects unknown or unavailable plugins
  - rejects a duplicate if `allowMultiple: false`
  - inserts at the end, or at `--index` before that position
  - records `pluginVersion` and manifest defaults for new controls
  - renders and restarts PipeWire
- `fx remove`, `fx move`, `fx toggle` mutate state, render, and restart.
- `fx enable|disable` change the master switch and rebuild the mic routes
  without a PipeWire restart, matching today's `micfx` behavior. They do not
  reload a generated config that PipeWire has not loaded yet; use `fx apply`
  after structural changes.
- `fx apply` renders and restarts PipeWire; it is the retry path after a
  failed restart.
- `micfx on|off|toggle` remains an alias for `fx enable|disable`; `micfx
  toggle` flips the master switch.
- `micfx controls` and `micfx set` map to the first `rnnoise` instance for
  backward compatibility; they are documented as legacy in the README.

Device commands:

```sh
wavemix device output <name>          # set the primary output; keeps other selected outputs
wavemix device output-add <name>      # add another hardware output
wavemix device output-remove <name>   # remove one; the last output cannot be removed
wavemix device input <name>
```

- `devices --json` adds `selected.outputs` (the ordered list) alongside the
  existing `selected.output` primary.
- `device output <name>` moves that device to the front of `outputs` and
  preserves the other selected devices.
- `output-add` refuses duplicates and virtual/bus nodes; `output-remove`
  refuses to remove the last selected output.
- `mutes` reports `output: true` only when every selected output is muted.
- `mute output on|off|toggle` applies to every selected output. `toggle` uses
  the all-muted definition above.

JSON shapes are stable enough for the popup and scripts; all commands exit
non-zero with a message on validation or runtime failure.

## Effects popup

The existing Noise Suppression popup becomes an Effects popup:

- Header: `EFFECTS`, close button, and a small footer or subtitle showing
  `Wavemix 1.1.0`.
- Master switch: `Microphone effects`.
- Chain list:
  - one row per instance, in processing order
  - name, plugin version, GPU badge when `gpu: true`
  - bypass control, remove button, and up/down buttons
  - selected row is highlighted
  - unavailable or version-changed rows show a warning and an install hint
- Add effect:
  - opens a list of available plugins
  - shows name, description, version, source, GPU badge, and install hint
  - unavailable plugins are visible but disabled
- Settings:
  - sliders for the selected instance, rendered from manifest controls
  - live updates on release through `fx set`
  - disabled when the selected instance is bypassed or unavailable
- Applying state:
  - structural commands show `Applying… audio restarts briefly`
  - after the command returns, refetch `fx state` and clear the notice
  - if a restart fails, show the error and keep the state editable
- Empty state: `No effects. Add one.`
- Opening: middle-click either bar icon, or the gear beside the mixer's
  Noise suppression row. Existing IPC methods remain:
  - `micfx` opens the popup
  - `micfxset` remains a compatibility hook for the first RNNoise instance
  - a new `fx` method opens the popup
- The popup fetches `fx state --json` on open and after every mutation.

## Mixer output picker

The mixer's Devices section keeps the existing primary **Output** dropdown and
adds an **Also play to** checkbox list beneath it:

- the primary output is always selected;
- each additional hardware output can be checked or unchecked;
- unchecking the last selected output is refused with a short notice;
- the per-channel `out` row shows `out ×N` when more than one output is
  selected;
- the hero speaker toggle and the bar speaker icon mute or unmute every
  selected output together;
- the existing Default out dropdown is unchanged.

The additional-output list is mouse-driven; the primary output dropdown keeps
its current keyboard control index.

## Installation and repository layout

New layout:

```text
VERSION
CHANGELOG.md
bin/wavemix
plugin/manifest.json
plugin/Panel.qml
plugins/rnnoise.json
plugins/highpass.json
plugins/noisegate.json
plugins/deepfilternet.json
plugins/maxine-denoise.json
systemd/wavemix.service
tests/test_wavemix.py
install.sh
```

- `install.sh` installs bundled manifests into
  `~/.local/share/wavemix/plugins/`. It replaces that directory's contents so
  removed bundled plugins do not linger; user manifests in
  `~/.config/wavemix/plugins/` are never touched.
- `install.sh` runs `wavemix fx render` before starting the service. If the
  generated config changed, it runs `wavemix fx apply` once so the default
  chain is loaded.
- The old `extras/90-wavemix-micfx.conf` is removed from the repository; the
  generated config replaces it.
- The service remains `wavemix watch`; it renders on `up()` and never restarts
  PipeWire.

## Error handling

- Invalid or incompatible manifests: listed as unavailable with an `error`;
  never compiled.
- Missing plugin file or LV2 URI: listed as unavailable with the `requires`
  hint; if it was in the chain, it is skipped.
- Broken instance reference: shown as an error row; `fx remove` can delete it.
- Empty or all-disabled chain: raw mic path; no filter-chain module.
- Config write failure: write a temp file first; leave the old config in place.
- PipeWire restart failure: report the error; state and config remain; retry
  with `fx apply`.
- Live control failure: store the value and report `applied: false`.
- Multi-output: removing the last selected output is rejected; a vanished or
  virtual output is dropped during sanitization; if the list becomes empty,
  the default hardware sink is selected.
- Mixed output mute states: `output` is muted only when every selected output
  is muted; toggling from a mixed state mutes all.
- Version mismatch: `minWavemix`/schema errors are advisory per manifest;
  a newer state version is fatal and does not overwrite anything.
- The generated config is validated by unit tests and inspected for balanced
  quoting; string fields are escaped when rendered.

## Security

- Manifests are trusted local configuration. They point at native plugins that
  run inside the PipeWire process; only user-owned directories are scanned.
- No network access, downloads, or execution of manifest-provided commands.
- Manifest ids, control keys, node names, and port names are validated.
- String values written into the SPA config and `pw-cli` payloads are escaped;
  no shell interpolation is used.
- `$HOME`/`~` expansion is limited to the LADSPA `plugin` path. Other fields
  are used as-is.

## Testing

Unit tests cover:

- `VERSION` and `WAVEMIX_VERSION` agree; version comparison and `minWavemix`.
- Manifest discovery, user override precedence, validation errors, duplicate
  ids, unsupported schema versions, and missing plugin files.
- Chain compilation for zero, one, and several effects; disabled instances;
  unavailable instances; ordering; node names; links; inputs/outputs.
- Control conversion for integer, float, scaled, and `raw_float` controls.
- State migration from v1, default chain construction, and `pluginVersion`
  change detection.
- Add/remove/move/toggle/set mutations with a temporary state file; instance
  id generation and `allowMultiple`.
- Atomic config rendering, generated marker, and backup behavior.
- CLI JSON shapes for `fx plugins` and `fx state`.
- Escaping of quoted config values.
- Multi-output: target-list construction, one loopback per selected output,
  shared-tag volume/mute application, all-output mute semantics, output
  add/remove, last-output rejection, and `devices`/`status` JSON.

Manual verification:

- Install bundled manifests; open the Effects popup; add RNNoise, high-pass,
  and noise gate; reorder, bypass, remove; confirm audible order and routing.
- Change each control live; confirm `pw-cli enum-params` changes and audio
  does not restart.
- Restart PipeWire; confirm controls and chain order persist.
- Install `deepfilternet-ladspa`; confirm it appears available and runs.
- Install the Maxine LADSPA runtime; confirm the GPU badge, intensity slider,
  and audio path. If the runtime is absent, confirm the install hint and
  disabled state.
- Break a manifest deliberately; confirm the error is visible and the rest of
  the chain still works.
- Select two hardware outputs; confirm both receive the same mix and the
  per-channel output fader/mute affects both.
- Remove one output and add it back; confirm the other keeps playing and the
  last output cannot be removed.
- Confirm the speaker toggle mutes every selected output.
- Confirm the mic bus, virtual mic, and per-channel meters are unaffected.

The QML popup is verified manually; there is no QML test harness.

## Migration and backward compatibility

- The first read of a v1 state creates `rnnoise-1` from `micFx.controls`.
- Existing RNNoise values survive unchanged.
- Existing `micfx on|off|toggle` and `micfx controls|set` commands continue to
  work; the latter operate on the first `rnnoise` instance.
- The old hand-written config is backed up once and replaced by the generated
  config.
- A missing `devices.outputs` list migrates to `[devices.output]`; `output`
  remains the first/primary entry.
- A fresh install uses the manifest defaults; the master switch defaults to
  off, matching the current `DEFAULT_STATE`.

## Acceptance criteria

- A fresh install ships RNNoise, high-pass, and noise-gate manifests, and the
  Effects popup can add all three.
- Two effects can run in sequence, be reordered, bypassed, and removed, with
  audio following the compiled order.
- RNNoise controls from the old state survive migration and remain live.
- A user manifest in `~/.config/wavemix/plugins/` appears in the popup and can
  be added.
- DeepFilterNet or Maxine manifests become usable when their LADSPA plugins
  are installed; otherwise they show an install hint.
- `wavemix --version`, `fx plugins`, and the popup show core/plugin versions.
- Incompatible manifests and newer state versions fail safely.
- Two selected hardware outputs receive the same mix; the per-channel output
  fader and speaker mute affect both; removing one output keeps the other
  playing; the last output cannot be removed.
- Unit tests pass, no Wavemix QML errors are logged, and the mic bus/meters
  continue to work.

## Future extensions

- External process/daemon plugins (e.g. `maxine-pipewire`, EasyEffects) with
  systemd lifecycle and D-Bus/CLI controls.
- Per-channel effect chains.
- Chain presets and A/B comparison.
- Plugin update checks against a local or remote catalog.
- Stereo/multi-channel microphone effects.
