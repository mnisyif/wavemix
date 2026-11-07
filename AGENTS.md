# AGENTS.md

Instructions for any agent working on Wavemix. Read this before changing code.
When a user instruction conflicts with this file, the user wins; otherwise this
file is the default contract.

## What Wavemix is

A user-level PipeWire channel mixer for the Omarchy bar. Each app group gets a
channel with two sends: speakers and a shared virtual microphone. The mic has an
ordered, manifest-driven effect chain hosted in a PipeWire filter-chain.

The product is Linux-only today. Windows and macOS would require new audio
backends, not a port; do not assume `pactl`, `pw-cli`, PipeWire, Quickshell, or
systemd exist there.

## Tech stack

- **Language:** Python 3.10+ for the CLI and engine. Standard library only
  unless the user explicitly approves a new dependency.
- **Audio:** PipeWire, `pipewire-pulse`, WirePlumber; drives `pactl`, `pw-cli`,
  `pw-link`, and `libpipewire-module-filter-chain`.
- **UI:** QML on Quickshell, using Omarchy's `qs.Commons` and `qs.Ui`
  primitives. The bar widget and the floating Effects window are separate
  Omarchy plugins.
- **Effects:** LADSPA, LV2, and builtin PipeWire nodes, described by JSON
  manifests in `plugins/`.
- **Service:** a systemd user unit in `systemd/wavemix.service`.
- **Tests:** Python `unittest`.
- **Platform:** Arch Linux with Omarchy; Pipeless installs are not supported.
  No root access is required at runtime.

### File map

| Path | Purpose |
| --- | --- |
| `bin/wavemix` | CLI, routing graph, state, device and channel commands |
| `bin/wavemix_fx.py` | Effect manifests, chain compiler, live controls |
| `plugin/Panel.qml` | Bar widget and Mixer / Effects / Devices popup |
| `fx-plugin/FxWindow.qml` | Floating effect-chain editor |
| `plugins/*.json` | Bundled effect manifests |
| `tests/test_wavemix.py` | Unit tests for the CLI, state, manifests, compiler |
| `systemd/wavemix.service` | User service |
| `install.sh` | Copies the CLI, plugins, service, and generated config |
| `docs/superpowers/` | Design specs and implementation plans |
| `VERSION`, `CHANGELOG.md` | Release version and history |

### Data and compatibility

- Runtime state lives in `~/.config/wavemix/state.json`.
- `STATE_VERSION` is currently `2`. Migrations must preserve unknown fields and
  must not overwrite a newer state file.
- Manifest `schemaVersion` is currently `1`.
- Preserve CLI flags, JSON field names, and manifest keys unless the change is
  explicitly a breaking release.
- Never edit a user's installed state or user manifests as part of a test.

## Development flow

Use the Superpowers process skills. Do not jump straight to code.

### 1. Brainstorm

Classify the request before asking questions:

- **Spike:** a feasibility question. Present the question and the smallest probe,
  get approval, answer it, and do not keep production code.
- **Bounded:** a change to an existing flow. Ask the questions that matter, then
  present a short design in chat and stop for explicit approval.
- **Architectural:** a new subsystem, a restructure of how components interact,
  a new backend, or a breaking state/CLI change. Use the full design process.

State the classification out loud so the user can override it. One focused
question at a time is preferred.

### 2. Design

- **Bounded:** a short design in chat: approach, files touched, testing.
- **Architectural:** a written spec in
  `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`. Self-review it, commit
  it, and get the user to review it before planning.
- **UI work:** use the design-taste-frontend principles: one system, plain copy,
  real states, and verification from screenshots. Adapt it to QML; do not run
  its browser checkers against a QML panel. Prefer Omarchy primitives over new
  custom chrome.

Do not implement before the user approves the applicable design.

### 3. Plan

- Use the writing-plans skill for multi-step work.
- Put the plan in `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`.
- Every task must say what it changes, what test proves it, and how to verify it.
- Get the plan reviewed before executing.

### 4. Execute

- Use test-driven development for behavior changes: failing test, minimal
  implementation, passing test.
- Work in small, reviewable commits.
- Run the tests after every meaningful step.
- For bugs, use systematic debugging first: reproduce, gather evidence, find the
  root cause, add a failing test, then fix. Do not patch symptoms.
- Before claiming completion, use verification-before-completion: run the
  commands and report the actual output.
- Request code review for major changes or before merging a feature branch.

### Definition of done

- Tests pass.
- QML loads with no errors in the user journal.
- User-visible changes are checked in the real panel or window.
- `CHANGELOG.md` has an `Unreleased` entry for user-visible changes.
- No debug probes, temporary IPC methods, or generated files remain.
- The working tree is clean, or the remaining changes are explicitly reported.

## Commit strategy

Use Conventional Commits and one logical change per commit.

**Types:** `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `release`,
`revert`.

**Scopes used here:** `cli`, `fx`, `plugin`, `ui`, `state`, `tests`, `docs`,
`install`, `license`.

Rules:

- Subject in the imperative mood, lowercase after the type, 72 characters or
  fewer. Example: `fix(plugin): hold slider value until the poll confirms it`.
- The body explains **why**, not just what. Reference the affected behavior.
- Tests belong with the behavior they cover.
- Do not mix unrelated cleanup with a feature or a fix.
- Do not commit `__pycache__`, `*.pyc`, local state, screenshots, or files from
  `/tmp`.
- Commit at logical checkpoints. Do not leave finished work uncommitted at
  handoff.
- Never commit directly to `main` for a multi-step feature if a branch is in use;
  use `feat/...`, `fix/...`, or `release/...`.
- Never force-push `main` or rewrite published history.
- Do not push, tag, or publish a release unless the user asks.

## Versioning and releases

Use SemVer.

- **Major:** breaking CLI, state, or manifest changes.
- **Minor:** new effects, tabs, screens, or other backward-compatible features.
- **Patch:** bug fixes with no new behavior.

Feature work since 1.2.0 is a **minor** release. A fix-only release is a patch.

### Version locations

All four must agree in a release:

1. `VERSION`
2. `bin/wavemix_fx.py` → `WAVEMIX_VERSION`
3. `plugin/manifest.json` → `version`
4. `fx-plugin/manifest.json` → `version`

Bundled effect manifests also have their own definition `version`. Bump a
manifest version only when its ports, controls, or defaults change. Bump its
`minWavemix` only when it needs a newer core feature. Do not bump every effect
manifest just because the core version changed.

`state.json` (`STATE_VERSION`) and manifest `schemaVersion` are separate from
the release version.

### Changelog

Follow Keep a Changelog:

- Keep `## [Unreleased]` at the top.
- Add user-visible changes there as they land.
- On release, rename it to `## [X.Y.Z] - YYYY-MM-DD`.
- Use `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`.

### Release checklist

1. Confirm the tree is clean and tests pass:

   ```bash
   git status
   python3 -m unittest discover -s tests -v
   ```

2. Confirm which versions are actually released:

   ```bash
   git tag --sort=-v:refname
   git ls-remote --tags origin
   ```

   `VERSION` saying a number does not mean it was tagged or pushed.

3. Write the `Unreleased` notes and review them.

4. Create a release commit that **only** bumps versions and moves the changelog:

   ```bash
   git add VERSION bin/wavemix_fx.py plugin/manifest.json \
     fx-plugin/manifest.json CHANGELOG.md
   git commit -m "release: wavemix X.Y.Z"
   git tag -a vX.Y.Z -m "Wavemix X.Y.Z"
   ```

5. Push the branch and tags:

   ```bash
   git push origin main --follow-tags
   ```

6. Create the GitHub release from the tag and paste the changelog.

7. Verify from a clean clone:

   ```bash
   git clone --branch vX.Y.Z git@github.com:mnisyif/wavemix.git /tmp/wavemix-release
   cd /tmp/wavemix-release && ./install.sh
   ~/.local/bin/wavemix --version
   ```

8. Never move or retag a published tag. Fix forward with a new patch release.

For a multi-version maintenance line, use a `release/X.Y` branch and cherry-pick
fixes. Otherwise release from `main`.

## Testing and verification

### Python

```bash
python3 -m unittest discover -s tests -v
```

Tests must pass before a commit that claims a fix or feature.

### QML and the real panel

```bash
./install.sh
omarchy restart shell
journalctl --user -f | grep -iE 'Panel.qml|FxWindow.qml|TypeError|ReferenceError'
```

- Use a full `omarchy restart shell` after changing bar-widget QML; a plugin
  rescan does not always recreate a live bar widget.
- Open and inspect the panel without the mouse:

  ```bash
  omarchy-shell mnisyif.wavemix open
  omarchy-shell mnisyif.wavemix tab mixer
  omarchy-shell mnisyif.wavemix tab effects
  omarchy-shell mnisyif.wavemix tab devices
  omarchy-shell mnisyif.wavemix close
  ```

- Take a screenshot of any visual change and inspect it before claiming it
  works.
- Check that the filter-chain still loads and that no QML binding errors appear
  in the journal.
- `fx apply` restarts PipeWire. Warn the user before doing it, especially if
  they may be on a call or playing audio.

### CLI smoke checks

```bash
~/.local/bin/wavemix --version
~/.local/bin/wavemix fx plugins --json
~/.local/bin/wavemix fx state --json
```

## Code and UI conventions

### Python

- Follow the existing two-space indentation.
- Keep the CLI layer thin; put parsing and rendering in `bin/wavemix_fx.py`.
- Keep JSON output stable; other tools and the QML panel consume it.
- Do not add third-party packages for something the standard library can do.
- Add a unit test for every behavior change, including state migration and
  manifest validation.

### QML

- Import and use `qs.Commons` and `qs.Ui`; use `Style`, `Color`, `Border`, and
  `Util` tokens instead of hardcoded theme values.
- Use the shell's `Panel`, `KeyboardPanel`, `CursorSurface`, `ButtonGroup`,
  `Dropdown`, `PanelSlider`, `ToggleSwitch`, and `PanelHero` patterns before
  inventing new components.
- Keep keyboard navigation working: `j`/`k` move, `h`/`l` switch tabs or adjust
  the selected control, `Enter` activates, `Esc` closes.
- Keep copy plain and specific. Prefer "Effects chain", "Output", and "Stream"
  over vague labels.
- Preserve the persistent hero and independent per-tab scrolling.
- Never leave temporary preview IPC methods or debug probes in the installed
  plugin.

### Audio

- The CLI is the source of truth for audio state; QML reads it through
  `status`, `devices`, and `fx state` JSON.
- Do not bypass `wavemix` by editing PipeWire config directly unless the change
  is explicitly about generated config.
- The mic effect chain is compiled from enabled manifests; do not add
  hand-written filter-chain fragments.
- Keep user state under `~/.config/wavemix/` and user manifests under
  `~/.config/wavemix/plugins/`.

## Safety

- Do not delete or rewrite `~/.config/wavemix/state.json`, user manifests, or
  the user's device selection. Back up and migrate instead.
- Do not install system packages, load kernel modules, or run `sudo` without
  explicit approval.
- Do not restart PipeWire or apply an effect chain during an active call unless
  the user asks for it.
- Do not change the license. The project is MIT; keep the copyright and
  permission notice.
- Do not publish, push, tag, or open a pull request without explicit permission.

## Current workflow debt to fix when releasing

- `v1.2.0` has no tag even though `VERSION` and the changelog say 1.2.0. Tag the
  commit that actually shipped 1.2.0 before tagging 1.3.0.
- `main` contains unreleased post-1.2.0 work. Add its `Unreleased` changelog
  entries before the next release.
- `VERSION` and `WAVEMIX_VERSION` are separate literals. The test catches drift;
  do not remove that test.
