# Changelog

## [1.3.0] - 2026-11-07

### Added

- Mixer, Effects, and Devices tabs in the bar popup, each with independent
  scrolling and a persistent Wavemix hero.
- A five-channel Mixer viewport: five channel cards fit before the list starts
  scrolling.
- An FX state badge beside the mute switches, with inverted colors for on and
  off states.
- An LSP Expander LV2 manifest for gentle downward expansion, with conservative
  defaults and live controls.
- LV2 port-symbol guidance for manifest authors.

### Changed

- Channel and device sections are rebuilt as quiet cards with clearer type,
  spacing, and neutral borders.
- Send labels are now `Output` and `Stream` instead of `out` and `stream`.
- The MIC FX row is labelled `Effects chain`, since the chain is not limited to
  noise suppression.
- The hover tooltip separates state, device, and click actions into four short
  lines.

### Fixed

- Send sliders hold the released value until the status poll confirms it,
  preventing the quick-change bounce between the old and new levels.

## [1.2.0] - 2026-11-07

### Added

- A floating **Effects** window (`mnisyif.wavemix-fx`) opened by middle-clicking
  either bar icon or the gear on the Noise suppression row. It shows the chain
  in processing order with a two-column editor, drag-to-reorder rows, add,
  remove, bypass, and per-effect live controls.
- Staged structural editing: add, remove, reorder, and bypass are held in the
  window until **Apply changes**. The window shows unsaved/conflict states and
  asks before discarding on close.
- `wavemix fx commit --stdin [--json]`: validates and replaces the whole chain,
  writes `state.json`, renders once, and restarts audio once. The window uses it
  for Apply.
- `fx plugins --json` and `fx state --json` now expose plugin type and control
  defaults so new effects can be edited before they are applied.
- The chain model reserves `host`/`format` metadata for the planned external
  host backend.

### Changed

- The old Effects popup is removed; the bar's mixer panel keeps the master
  Noise suppression toggle and gear.
- The bar command queue is simplified now that effect editing lives in the
  window.
- The floating window is a separate panel plugin, so a plugin reload cannot
  take the mixer with it.

### Compatibility

- `state.json` stays version 2 and existing `micFx.chain` values are unchanged.
- GPU plugins remain ordinary manifests with `gpu: true`; no GPU-specific code
  path was added.
- VST3/CLAP hosting via the planned Carla + OSC backend is not part of 1.2.0.

## [1.1.0] - 2026-11-07

### Added

- A manifest-driven microphone effect chain. Add, remove, reorder, bypass, and
  combine LADSPA, LV2, and builtin effects from the Effects popup or the
  `wavemix fx` commands.
- Live effect controls: sliders and `wavemix fx set` update the running
  filter-chain node through `pw-cli` without restarting PipeWire.
- Bundled effect manifests at `~/.local/share/wavemix/plugins/`: RNNoise
  (default when its LADSPA plugin is available), high-pass, noise gate,
  DeepFilterNet, and NVIDIA Maxine. The neural denoisers stay visible with an
  install hint when their LADSPA file is missing; Wavemix does not verify the
  provider runtime or models.
- User manifests in `~/.config/wavemix/plugins/`, with bundled-id override
  precedence.
- Multiple hardware outputs. The mixer's **Also play to** list duplicates the
  mix to every selected output, with one shared per-channel fader and mute.
  `device output-add` and `device output-remove` mirror the picker in the CLI.
- Core and manifest version tracking: `wavemix --version`, `wavemixVersion` in
  `fx` JSON, `schemaVersion`/`version`/`minWavemix` checks, and
  `versionChanged` warnings.
- Atomic generation of
  `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`, with a one-time
  backup of an older hand-written config.
- `wavemix fx plugins`, `fx state`, `fx add`, `fx remove`, `fx move`,
  `fx toggle`, `fx set`, `fx enable`, `fx disable`, `fx render`, and
  `fx apply`.
- The Effects popup replaces the single Noise Suppression settings popup.

### Changed

- `state.json` is now version 2 and carries `micFx.chain` and
  `devices.outputs`. Version 1 `micFx.controls` migrate into an `rnnoise-1`
  instance.
- The speaker mute controls every selected output and reads as muted only when
  all of them are muted.
- The effect chain is compiled whenever it has enabled, available effects, even
  while the microphone effects master switch is off. Enabling the switch links
  the already-loaded chain without a PipeWire restart. A master switch with no
  usable chain (empty, all bypassed, all unavailable, or no live capture node)
  keeps the raw microphone path instead of silencing the mic bus.
- Invalid static `config` values now mark only that manifest unavailable, and a
  single unrenderable instance is skipped instead of aborting the whole chain.
  Rendering also happens before the old graph is unloaded, so a render failure
  leaves the existing graph intact.
- `install.sh` installs `wavemix_fx.py`, replaces the bundled manifest set,
  renders the generated config, and restarts PipeWire only when the config
  changed.
- The bar-widget manifest version is `1.1.0`.

### Removed

- The hand-written `extras/90-wavemix-micfx.conf` example. The config is now
  generated from the effect chain.

### Compatibility

- `micfx on|off|toggle` and `micfx controls|set` remain as aliases for the
  master switch and the first RNNoise instance.
- Existing RNNoise control values survive migration.
- A state file with a newer version than the binary supports is rejected
  without being overwritten.
