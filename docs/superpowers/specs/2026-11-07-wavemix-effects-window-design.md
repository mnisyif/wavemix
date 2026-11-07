# Wavemix Effects Window — Design

- **Date:** 2026-11-07
- **Status:** Draft for review
- **Target release:** Wavemix 1.2.0
- **Scope:** Phase 1 — a floating effects window and atomic chain editing.
  Phase 2 — the Carla + OSC host backend for VST3/CLAP — is recorded here as
  the chosen architecture but is not implemented in 1.2.0.

## Intent

Give Wavemix a real desktop window for viewing and editing the microphone
effect chain: see the chain in processing order, add/remove effects, drag to
reorder, bypass, tune controls, and apply the result to
`~/.config/wavemix/state.json`.

The window must treat every effect the same way. GPU support is not a
separate implementation: a GPU plugin is an ordinary plugin with `gpu: true`
metadata. The chain model and UI must be format- and host-aware so that
VST3/CLAP can join native LADSPA/LV2/builtin effects later without another
window rewrite.

## Decisions

1. **The window is a real floating window.** A new panel plugin,
   `mnisyif.wavemix-fx`, contains a Quickshell `FloatingWindow`. The existing
   bar widget opens and toggles it through the shell. The old Effects popup is
   removed so there is one editor.
2. **The chain is linear.** Effects run top to bottom. Reordering is
   drag-and-drop; branching/parallel graphs are out of scope.
3. **Apply is hybrid.** Knob changes are live. Add, remove, reorder, and bypass
   are staged in a draft and committed together with one Apply, because bypass
   recompiles the chain.
4. **GPU is metadata, not a backend.** `gpu: true` renders a badge and does
   not change compilation. DeepFilterNet, Maxine, and future GPU plugins are
   ordinary manifests.
5. **Phase 2 uses Carla + OSC for VST3/CLAP.** PipeWire's filter-chain cannot
   host VST3 or CLAP. Carla is the chosen external host because it runs
   headless, supports VST3, and exposes parameter control over OSC. This is a
   separate phase with its own spec and plan.
6. **Phase 1 ships first.** It delivers the window, the host-aware chain model,
   staged Apply, and the atomic commit command for all current native effects.
   Phase 2 adds the Carla backend and discovery.

## Goals

Phase 1 must:

- Provide a floating Effects window opened from the Wavemix bar icons and the
  Noise suppression gear.
- Show the chain in processing order with effect name, instance id, bypass,
  availability, version, and GPU metadata.
- Let the user drag rows to reorder, add available effects, remove effects,
  and stage bypass changes.
- Keep per-effect control editing live through `wavemix fx set`.
- Apply the entire staged structure atomically through one
  `wavemix fx commit` call: validate, write `state.json`, render the
  filter-chain config, restart audio once.
- Preserve all existing `micfx`, `fx`, routing, and virtual-mic behavior.
- Keep the chain model ready for a future `host`/`format` backend without
  changing the window.
- Cover the new behavior with unit tests and keep the existing suite green.

## Non-goals

Phase 1 does not:

- Host, discover, or control VST3/CLAP plugins.
- Add a graphical patchbay or parallel routing.
- Change the mono microphone chain into a stereo/multichannel chain.
- Replace PipeWire's filter-chain for native effects.
- Persist an unapplied draft across shell restarts.
- Add plugin-marketplace, preset, or update features.
- Auto-scan arbitrary installed plugins beyond the existing manifest system.

## Current state

- `state.json` version 2 stores `micFx.enabled` and `micFx.chain`.
- `wavemix fx` supports `plugins`, `state`, `add`, `remove`, `move`, `toggle`,
  `set`, `enable`, `disable`, `render`, and `apply`.
- `wavemix_fx.py` discovers LADSPA/LV2/builtin manifests, validates versions,
  compiles the filter graph, and renders
  `~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf`.
- The bar plugin `mnisyif.wavemix` has an Effects `PopupCard` with add,
  reorder (up/down), bypass, remove, and live controls.
- Structural CLI changes each render and restart PipeWire. Live `fx set`
  changes use `pw-cli` and do not restart.
- The source of truth is the git repository at
  `/home/mnisyif/projects/wavemix`; the installed copies are under
  `~/.local/bin` and `~/.config/omarchy/plugins`.

## Architecture

### Plugin layout

Keep the bar widget plugin unchanged in kind:

- `plugin/manifest.json` / `plugin/Panel.qml` — `mnisyif.wavemix`, kind
  `bar-widget`.

Add a separate panel plugin:

- `fx-plugin/manifest.json` — id `mnisyif.wavemix-fx`, name
  `Wavemix Effects`, kind `panel`, `keepLoaded: true`, entry point
  `FxWindow.qml`.
- `fx-plugin/FxWindow.qml` — the floating window.

The separate plugin matters: a manifest that declares both `bar-widget` and
`panel` is owned by the panel loader, so the bar would stop loading its widget.
`keepLoaded: true` keeps the window instance and its draft alive when the shell
hides the panel.

### Bar integration

`Panel.qml` keeps the Noise suppression master row and the gear. It removes the
Effects popup and all popup-specific `fx*` state/processes.

- Middle-click either Wavemix bar icon calls the window.
- The gear on the Noise suppression row calls the window.
- The call is
  `root.bar.shell.toggle("mnisyif.wavemix-fx")` when `bar.shell` exists, with a
  `root.bar.run("omarchy-shell shell toggle mnisyif.wavemix-fx")` fallback.
- The master switch stays in the mixer and continues to call
  `wavemix micfx toggle`.

### Window lifecycle

`FxWindow.qml` exposes the panel contract used by the shell:

- `property var shell`
- `property var manifest`
- `property bool opened: window.visible`
- `function open(payloadJson)` — show the window, refresh state.
- `function close()` — hide it, but intercept unsaved structural changes.

The `FloatingWindow` title is `Wavemix — Effects`. It uses
`Commons.Color`/`Style` for theme colors, spacing, and fonts.

### Data model

`state.json` remains the only committed source of truth. `micFx.chain` keeps its
current shape. The model reserves optional `host` and `format` fields on chain
entries for Phase 2; Phase 1 treats a missing host as `pipewire`, and does not
write the fields.

The window keeps a draft:

- `draft` is an ordered array of entries:
  `{ key, instance, plugin, enabled, isNew }`.
- Existing entries use their `instance` as `key`; new entries use a temporary
  `new:<n>` key.
- `dirty` compares the draft's structural signature
  `[plugin, instance, enabled]` against the loaded server signature. Control
  values are not part of the structural signature.
- Control values for new entries live in the draft until commit.
- Control values for existing entries are read from the server state and
  updated live.

### Command contract

Add `wavemix fx commit --stdin [--json]`.

- Input: one line of JSON on stdin:
  ```json
  {
    "chain": [
      { "instance": "rnnoise-1", "plugin": "rnnoise", "enabled": true },
      { "instance": "", "plugin": "highpass", "enabled": true,
        "controls": { "freq": 120 } }
    ]
  }
  ```
- Existing `instance` ids keep their stored controls and unknown fields.
- Empty `instance` means a new instance. The engine generates a unique
  `<plugin>-<n>` id and uses `controls` when provided; otherwise manifest
  defaults.
- Missing `enabled` defaults to `true`.
- Removed instances are simply absent from the list.
- The command validates everything before touching state or audio.
- On success it writes `state.json`, renders the config once, and restarts
  audio once.
- With `--json`, it prints a JSON result:
  `{"ok": true, "restarted": true, "chain": [...]}`. On a handled error it
  prints `{"ok": false, "error": "..."}` and exits non-zero.
- On render failure it leaves `state.json` and the live graph untouched.
- On restart failure it leaves the new state/config on disk, reports
  `restarted: false`, and the window offers a retry.

Add `type`, `gpu`, and `controls` (including default values) to
`wavemix fx plugins --json`, and to the plugin entries embedded in
`wavemix fx state --json`. The window needs defaults to edit a new effect
before Apply.

### Atomic replacement

Add `replace_chain(state, manifests, entries)` to `wavemix_fx.py`:

- Validate plugin ids, instance ids, manifest availability for new entries,
  duplicate instances, and plugin/instance consistency.
- Preserve stored controls and unknown fields for existing instances.
- Generate unique ids for new instances.
- Validate and store provided controls for new instances.
- Return a candidate chain without mutating the loaded state.

The CLI copies the loaded state, calls `replace_chain` on the copy, renders the
candidate, and only then saves the candidate. The existing `graph_lock()`
serializes the commit against the watcher.

## UI

The window is two columns:

- **Left: chain.** Ordered rows with a drag handle, order number, effect name,
  instance id, status badges, bypass (eye), and remove (`×`). A connector line
  between rows shows signal flow.
- **Right: settings.** The selected effect's name, version, status,
  description, install/error hint, and controls as sliders/number controls.

Footer:

- Shows the dirty state (`N unsaved changes` or `All changes applied`).
- `Discard` resets the draft.
- `Apply changes` is enabled only when dirty and not applying.
- While applying, show `Applying… audio restarts briefly` and disable
  structural controls.
- On failure, show the engine error and keep the draft.
- On a successful commit whose restart failed, show `Saved, but audio did not
  restart` with `Retry`.

Add effect:

- `+ Add effect` switches the left column to a plugin list with a Back row.
- Available plugins can be added; unavailable plugins show their `requires` or
  error hint and cannot be added.
- Adding appends a new draft entry that can then be dragged.
- The list includes all manifest types and shows type/GPU metadata uniformly.

Drag reorder:

- Dragging a row shows a ghost and an insertion line.
- Dropping updates only the draft. It does not call the CLI.
- Rows can be dragged across the whole chain; the chain stays linear.

Controls:

- Existing live effect: releasing a control calls `wavemix fx set` and does
  not dirty the structure.
- New, unapplied effect: controls edit the draft and are sent with the commit.
- Draft-bypassed effect: controls are disabled with
  `Bypassed — apply to change`.
- Unavailable effect: controls are disabled and the error/install hint is
  shown.

Close behavior:

- Closing with a dirty draft shows an in-window confirmation:
  `Discard unsaved changes?` with `Keep editing` and `Discard`.
- The bar toggle and the window close button both go through this guard.
- `keepLoaded: true` keeps the instance alive while the shell hides it; if the
  shell hides the window during the confirmation, the window re-summons and
  shows the confirmation instead of losing the draft.

Keyboard:

- `Esc` closes with the dirty guard.
- `j`/`k` moves the selection.
- `Enter` toggles the selected effect's staged bypass.
- `Delete` stages removal of the selected effect.
- `Ctrl+Enter` applies.
- Drag remains the primary reorder interaction.

Master switch:

- `Microphone effects` calls `wavemix fx enable` / `disable`.
- It updates the JSON and links/unlinks the already-loaded chain; it is not
  staged and does not dirty the structural draft.

## Data flow

1. `open()` shows the window and runs `wavemix fx state --json`.
2. The response supplies the committed chain, plugin metadata, and live
   controls. The draft is copied from the chain.
3. Drag/add/remove/bypass mutate the draft and recompute `dirty`.
4. A control release on an existing effect calls `wavemix fx set`. The window
   updates optimistically and reconciles from the next state refresh.
5. Apply writes the draft JSON to the commit process's stdin and calls
   `wavemix fx commit --stdin --json`.
6. On success, the window refreshes state and clears the draft.
7. On a render/validation error, nothing is committed. On a restart error, the
   window keeps the committed JSON but shows the retry notice.
8. While the draft is dirty, a server signature change raises a conflict
   banner. The user can reload from disk or overwrite with Apply.

## Error handling

| Case | Behavior |
| --- | --- |
| Unknown plugin id | Commit rejected; message in the window; live graph untouched. |
| Unknown or duplicate instance id | Commit rejected with the offending id. |
| New effect unavailable | Rejected before render; install hint shown. |
| Invalid control value | Rejected with the control label; stored value unchanged. |
| Render failure | No `state.json` write; old config and audio stay live. |
| Audio restart failure | State/config saved; `restarted: false`; window offers Retry. |
| Shell/window hidden while dirty | Close guard; draft is not silently lost. |
| External chain change while dirty | Conflict banner; reload or overwrite. |
| `wavemix` missing or command failure | Window shows the error and a Retry action. |
| Empty/all-bypassed chain | Allowed; engine keeps the raw mic path. |
| Master off | Chain remains editable and commit still compiles it. |

## Testing

Python unit tests:

- `replace_chain`: order, add, remove, bypass, preserved controls and unknown
  fields, generated unique ids, duplicate/unknown rejection, unavailable-new
  rejection, invalid controls.
- `fx commit`: one restart call, correct `state.json`, rendered config content,
  render-failure rollback, restart-failure result.
- `fx plugins --json` and `fx state --json`: `type`, `gpu`, and control
  defaults are present.
- Existing suite stays green.

QML:

- `qmllint` and shell reload logs are clean.
- Manual checks: open from both entry points; drag reorder; add highpass;
  bypass; apply; verify `state.json` order, `fx state --json`, and exactly one
  audio restart; live knob changes do not dirty the structure; dirty close
  prompt; failed-apply path; no duplicate windows.
- Verify the old Effects popup is gone and the master switch still works.

## Rollout

- Add `fx-plugin/` to the repository.
- Update `install.sh`:
  - install `fx-plugin/manifest.json` and `fx-plugin/FxWindow.qml` to
    `~/.config/omarchy/plugins/mnisyif.wavemix-fx/`;
  - install the simplified `plugin/Panel.qml`;
  - rescan plugins with `omarchy-shell -q shell rescanPlugins` and enable the
    window with `omarchy plugin enable mnisyif.wavemix-fx`.
- Bump `VERSION`, both manifests, `README.md`, and `CHANGELOG.md` to 1.2.0.
- Keep `state.json` version 2; `micFx.chain` is unchanged.
- Record the Phase 2 architecture in this spec so it is not lost.

## Phase 2 (recorded, not implemented in 1.2.0)

**Chosen backend: Carla + OSC.** VST3/CLAP effects run in headless Carla stages.
Carla is the recommendation because it supports headless operation, VST3, and
OSC parameter control. CLAP requires Carla main/`carla-git` or a future stable
Carla with CLAP support; this is a documented dependency.

**Host-aware chain.**

- Each chain entry gains optional `host` (`pipewire` or `carla`) and `format`
  (`ladspa`, `lv2`, `builtin`, `vst3`, `clap`).
- A stage compiler groups consecutive effects by host. Each PipeWire stage is a
  `module-filter-chain`; each Carla stage is one headless Carla rack.
- Stages connect in series:
  `mic → native stage → Carla stage → native stage → … → mic bus`.
- Native-only chains keep the current render + PipeWire restart path.
- Mixed chains regenerate the affected stages and restart only those hosts.

**Carla adapter.**

- Generate a `.carxp` project per Carla stage with a stable client name such as
  `wavemix_fx_stage_N`.
- Start with `pw-jack carla -n <project>`.
- Discover the exact client/ports after startup and link stages with `pw-link`.
- Live controls use Carla's OSC parameter API; stored values also go to
  `state.json`.
- VST3/CLAP discovery uses Carla's scanner, cached in Wavemix and exposed as
  generated manifests to the same Add-effect list.
- No GPU-specific path: a GPU VST3/CLAP plugin is an ordinary entry.

**Phase 2 risks to resolve in its own spec.**

- Carla's OSC API is undocumented and tied to the Carla version.
- Parameter indices must be mapped reliably between discovery, project files,
  and OSC.
- Stable Carla 2.5.x does not expose CLAP; `carla-git` or a future release is
  required.
- Carla uses JACK/PipeWire-JACK, adding a process and latency to the mic path.
- Plugin crashes must not take down Wavemix; Carla or a supervisor must isolate
  them.
- Discovery and manifest generation for installed VST3/CLAP plugins need a
  cache and a stable id scheme.

## Resolved questions

- Window type: Quickshell floating window.
- Chain editing: linear list with drag reorder.
- Apply: live controls, staged structure.
- Launcher: bar icon + gear.
- Plugin scope: all manifest types; GPU is metadata.
- External host: Carla + OSC.
- Delivery: Phase 1 first, Phase 2 as a separate spec/plan.
