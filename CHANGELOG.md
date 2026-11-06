# Changelog

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
