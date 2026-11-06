# Wavemix

A PipeWire channel mixer for the [Omarchy](https://omarchy.org) bar.

Wavemix gives each app group its own channel with two independent sends:

- **out** — to your speakers (and to every additional selected output)
- **stream** — to the shared virtual microphone

Each channel also has a **live level meter** that shows its raw incoming audio,
before the send faders. The bar keeps moving even when a channel's sends are
muted or turned down, so you can always see which channel is producing sound.

The microphone has an ordered **effect chain** built from native PipeWire
filter-chain nodes. Add, reorder, bypass, and remove effects, and tune their
controls live without restarting PipeWire.

The bar shows a microphone and a speaker icon: left-click either to mute it,
right-click either to open the mixer, middle-click either to open the Effects
popup.

## Features

- Per-channel buses over PipeWire null sinks
- Independent output and virtual-mic sends with their own faders and checks
- Live pre-fader level meters for every channel, with peak hold
- Route apps to channels by name, with rules that survive restarts
- One or more physical outputs, all playing the same mix
- A manifest-driven microphone effect chain with live controls
- Bundled RNNoise, high-pass, noise-gate, DeepFilterNet, and Maxine manifests
- Everything is user-level; state lives in `~/.config/wavemix/state.json`

## Requirements

- Arch Linux with Omarchy (the bar runs inside Quickshell)
- PipeWire with `pipewire-pulse` and WirePlumber
- Python 3.10+
- `pactl`, `pw-cli`, and `pw-link` on `PATH`

The bundled RNNoise manifest expects an RNNoise LADSPA plugin such as
`noise-suppression-for-voice` at `/usr/lib/ladspa/librnnoise_ladspa.so`. The
builtin high-pass and noise-gate effects need no extra package. DeepFilterNet
and NVIDIA Maxine are optional; see [GPU and neural effects](#gpu-and-neural-effects).

## Install

```sh
git clone https://github.com/mnisyif/wavemix.git
cd wavemix
./install.sh
```

The install script copies:

| Source | Destination |
| --- | --- |
| `bin/wavemix` | `~/.local/bin/wavemix` |
| `bin/wavemix_fx.py` | `~/.local/bin/wavemix_fx.py` |
| `plugin/manifest.json` | `~/.config/omarchy/plugins/mnisyif.wavemix/manifest.json` |
| `plugin/Panel.qml` | `~/.config/omarchy/plugins/mnisyif.wavemix/Panel.qml` |
| `plugins/*.json` | `~/.local/share/wavemix/plugins/` |
| `systemd/wavemix.service` | `~/.config/systemd/user/wavemix.service` |

Bundled manifests are replaced as a set, so a plugin removed from the
repository also disappears from the installed set. Your own manifests in
`~/.config/wavemix/plugins/` are never touched.

The installer also:

- writes the generated filter-chain config to
  `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`;
- backs up an older hand-written config once, to
  `90-wavemix-micfx.conf.bak-<timestamp>`, before replacing it;
- enables and restarts the `wavemix` user service;
- runs `wavemix fx apply` only when the rendered config changed, which restarts
  PipeWire briefly so the new chain loads;
- asks the shell to rescan plugins.

If the widget still does not appear, restart the shell:

```sh
omarchy restart shell
```

## Usage

Open the mixer by right-clicking either Wavemix icon in the bar. Inside the
panel:

- `j` / `k` move between controls
- `h` / `l` adjust a fader or cycle a device
- `Enter` toggle a send, mute, or dropdown
- `Esc` close

The thin bar under each channel name is its live level meter. It reads the
channel's audio before the send faders, so it reacts to the channel itself, not
to the send level.

### Multiple outputs

The **Devices** section has a primary **Output** dropdown and an **Also play
to** list. Check any additional hardware outputs there. Wavemix creates one
loopback per selected output for each channel's `out` send; every copy is fed
by the same channel fader and mute. There is no per-output volume in this
release.

When more than one output is selected, the channel's send row shows `out ×N`.
Unchecking the last selected output is refused with a notice. A vanished or
virtual device is dropped automatically; if the list would become empty,
Wavemix falls back to the default hardware sink.

The speaker toggle (in the mixer, and the speaker icon in the bar) treats the
output as muted only when **every** selected output is muted. Toggling from a
mixed state mutes all selected outputs; toggling from all-muted unmutes them.

### Effects

Middle-click either bar icon, or click the gear beside the mixer's **Noise
suppression** row, to open the **Effects** popup. It shows the Wavemix version
and contains:

- a **Microphone effects** master switch;
- the chain in processing order, with each instance's name, id, bypass,
  move-up/move-down, and remove buttons;
- a GPU badge and plugin version for effects that declare them;
- settings sliders for the selected effect, written live as you release them;
- **+ Add effect**, which lists every discovered manifest with its name,
  description, version, source, GPU badge, and install hint. Unavailable
  plugins stay visible but cannot be added.

Structural changes (add, remove, move, bypass, or a manifest becoming
unavailable) regenerate the config and restart PipeWire briefly; the popup
shows `Applying… audio restarts briefly`. Control changes and the master switch
do not restart PipeWire. A bypassed effect keeps its stored controls but is
excluded from the compiled chain.

Unavailable effects and effects whose manifest version changed show an error
row and an install hint; the rest of the chain keeps working.

## Effect manifests

Wavemix discovers manifests from two local directories:

- **Bundled:** `~/.local/share/wavemix/plugins/*.json` (installed by
  `install.sh`)
- **User:** `~/.config/wavemix/plugins/*.json`

Bundled manifests are scanned first. A user manifest with the same `id`
replaces the bundled one. Wavemix never downloads manifests or runs commands
from them.

### Schema

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

Required fields are `schemaVersion`, `id`, `version`, `name`, `type`,
`input`, `output`, and `controls`. Important fields:

| Field | Meaning |
| --- | --- |
| `id` | Lowercase slug (`[a-z0-9_-]`), unique across bundled and user manifests |
| `version` | Plugin definition version, `MAJOR.MINOR.PATCH` |
| `minWavemix` | Oldest core version that can load the manifest; defaults to `1.1.0` |
| `type` | `ladspa`, `lv2`, or `builtin` |
| `plugin` | LADSPA `.so` path or LV2 URI; ignored for builtin. `~` and `$HOME` are expanded |
| `label` | LADSPA or builtin label; optional for LV2 |
| `input` / `output` | Mono audio port names, without the node prefix |
| `config` | Optional static filter config passed to the node |
| `gpu` | UI/CLI GPU badge; does not change compilation |
| `requires` | Install hint shown when the plugin is unavailable |
| `default` | Include in the default chain when no chain exists |
| `allowMultiple` | Whether more than one instance may be added (default `true`) |

Each control needs a stable `key` and the plugin's `param` name, plus its
display range (`min`, `max`, `step`, `unit`, `default`). `integer` controls are
rounded, `raw_float` controls are written as floats, and `scale` converts a
display value to the raw plugin value (`raw = display / scale`; the RNNoise dry
mix uses `scale: 100`).

Validation is per manifest: an invalid, incompatible, or missing plugin is
listed as unavailable with an error and never compiled. The rest of the chain
still loads.

### Bundled effects

All bundled manifests are definition version `1.0.0` and require Wavemix
`1.1.0` or newer.

| Id | Effect | Type | Default | Notes |
| --- | --- | --- | --- | --- |
| `rnnoise` | RNNoise | LADSPA | yes | VAD threshold, VAD grace, retroactive grace, dry mix |
| `highpass` | High-pass | builtin `bq_highpass` | no | Frequency 20–500 Hz, Q 0.1–5 |
| `noisegate` | Noise Gate | builtin `noisegate` | no | Open/close thresholds and attack/hold/release |
| `deepfilternet` | DeepFilterNet | LADSPA | no | Optional; `requires: Install deepfilternet-ladspa` |
| `maxine-denoise` | NVIDIA Maxine Denoiser | LADSPA (GPU) | no | Optional; `gpu: true`, with an install/runtime hint |

A new state starts with RNNoise in the chain. High-pass, noise gate,
DeepFilterNet, and Maxine are added from the popup or `wavemix fx add`.

### GPU and neural effects

DeepFilterNet and Maxine are ordinary LADSPA manifests. Wavemix does not bundle
their runtimes, models, or DSP code.

- **DeepFilterNet** expects `/usr/lib/ladspa/libdeep_filter_ladspa.so` with
  label `deep_filter_mono`. Install `deepfilternet-ladspa`, or put a user
  manifest in `~/.config/wavemix/plugins/` if your package uses another path.
- **NVIDIA Maxine** expects `~/.local/lib/ladspa/libmaxine_ladspa.so` with
  label `maxine_denoiser_mono`, and the NVIDIA Maxine runtime. Install the
  Maxine LADSPA wrapper and runtime, or override the path with a user manifest.
- PipeWire only loads LADSPA plugins under its `LADSPA_PATH`. If Maxine is
  installed in `~/.local/lib/ladspa`, add that directory to the PipeWire user
  environment.
- DeepFilterNet and Maxine may need a larger PipeWire quantum to avoid
  real-time glitches. That tuning belongs in a separate PipeWire drop-in and is
  not managed by Wavemix.

When the plugin or runtime is missing, the manifest stays in the Add-effect
list with its `requires` hint and cannot be added. Re-run `wavemix fx plugins`
to re-check availability after installing a plugin.

## Versioning and compatibility

- The core version is stored in `VERSION` and reported by `wavemix --version`
  (`wavemix 1.1.0`).
- `wavemix fx plugins --json` and `wavemix fx state --json` include
  `wavemixVersion`.
- Every manifest declares `schemaVersion` (currently `1`) and its own `version`.
  `minWavemix` gates the manifest against the running core and defaults to
  `1.1.0`.
- An unsupported `schemaVersion` or a `minWavemix` newer than the core marks
  only that manifest unavailable.
- `fx add` records the manifest's `version` as the instance's `pluginVersion`.
  If the manifest version later differs, `fx state` sets `versionChanged` and
  the popup warns that the definition changed. Existing control values are kept
  by key; new controls use manifest defaults and removed controls are ignored.
- `state.json` is version 2. A state file newer than the binary supports is
  rejected without being overwritten.

## Migration from 1.0

- The old hand-written `90-wavemix-micfx.conf` is backed up once and replaced
  by the generated config.
- A version 1 state's `micFx.controls` becomes the controls of a `rnnoise-1`
  instance, so existing RNNoise values survive unchanged.
- If the old state has no controls, the default chain is built from manifests
  with `default: true` (currently RNNoise).
- A missing `devices.outputs` migrates to `[devices.output]`.
- The legacy CLI commands still work: `micfx on|off|toggle` aliases
  `fx enable|disable`, and `micfx controls|set` operate on the first `rnnoise`
  instance.

## CLI

```sh
wavemix --version
wavemix status --json      # state, graph liveness, buses, mutes
wavemix devices --json     # available outputs/inputs and selected outputs
wavemix apps --json        # app streams and their channels

wavemix send browser output volume 40
wavemix send browser output on
wavemix channel add "Podcasts"
wavemix route firefox podcasts
wavemix device output <sink-name>
wavemix device output-add <sink-name>
wavemix device output-remove <sink-name>
wavemix mute output toggle
wavemix mutes
```

`device output` makes a device primary without dropping the other selected
outputs. `device output-add` appends an output; `device output-remove` refuses
to remove the last one. `mute output on|off|toggle` applies to every selected
output, and `toggle` uses the all-muted rule described above.

### Effect commands

```sh
wavemix fx plugins [--json]       # every manifest, availability, versions, hints
wavemix fx state [--json]         # core version, chain, live node, controls, plugins
wavemix fx add <plugin-id> [--index N]
wavemix fx remove <instance-id>
wavemix fx move <instance-id> up|down
wavemix fx toggle <instance-id>   # bypass or enable one instance
wavemix fx set <instance-id> <control> <value>
wavemix fx enable|disable         # master switch
wavemix fx render                 # write the config; no PipeWire restart
wavemix fx apply                  # render and restart PipeWire
```

Behavior details:

- `fx add` rejects unknown or unavailable plugins and duplicate instances when
  `allowMultiple` is false. It inserts at the end, or before `--index N`, records
  `pluginVersion` and manifest defaults, renders, and restarts PipeWire.
- `fx remove`, `fx move`, and `fx toggle` mutate the chain, render, and restart
  PipeWire briefly.
- `fx set` clamps to the manifest range, stores the display value, writes it to
  the live node with `pw-cli set-param`, and rewrites the config without
  restarting. If the node is not running it still stores the value and reports
  `applied: false`; the value is applied on the next `up()` or restart.
- `fx enable|disable` rebuild the mic routes without restarting, like the old
  `micfx` switch. Use `fx apply` after a structural change that failed to load.
- `fx render` is the non-disruptive path; `fx apply` is the retry path after a
  failed restart.

The legacy RNNoise aliases remain:

```sh
wavemix micfx on
wavemix micfx controls --json
wavemix micfx set vadThreshold 60
```

Run `wavemix --help`, `wavemix fx --help`, or `wavemix micfx --help` for the
full list.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/wavemix/state.json` | Devices, channels, routing rules, effect chain, controls |
| `~/.local/share/wavemix/plugins/` | Installed bundled manifests |
| `~/.config/wavemix/plugins/` | User manifests (override bundled ids) |
| `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf` | Generated filter-chain config |

## Repository layout

```
VERSION                         Release version
CHANGELOG.md                    Release notes
bin/wavemix                     PipeWire channel mixer CLI and watcher
bin/wavemix_fx.py               Manifest discovery, state, and chain compiler
plugin/manifest.json            Omarchy bar-widget manifest
plugin/Panel.qml                Bar widget, mixer panel, and Effects popup
plugins/*.json                  Bundled effect manifests
systemd/wavemix.service         User service that keeps the graph reconciled
tests/test_wavemix.py           Unit tests
install.sh                      Installer
```

## Tests

Run the suite with:

```sh
python3 -m unittest discover -s tests -v
```

Also check that the executables compile and the installer parses:

```sh
python3 -m py_compile bin/wavemix bin/wavemix_fx.py
bash -n install.sh
```

The QML popup has no automated harness and is verified manually.

## Uninstall

```sh
systemctl --user disable --now wavemix.service
rm -f ~/.local/bin/wavemix \
      ~/.local/bin/wavemix_fx.py \
      ~/.config/systemd/user/wavemix.service \
      ~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf
rm -rf ~/.local/share/wavemix \
       ~/.config/omarchy/plugins/mnisyif.wavemix
omarchy restart shell
```

State and user manifests are kept in `~/.config/wavemix/`; remove that
directory too if you want a clean slate.

## License

MIT. See [LICENSE](LICENSE).
