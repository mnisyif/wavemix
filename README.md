# Wavemix

A PipeWire channel mixer for the [Omarchy](https://omarchy.org) bar.

Wavemix gives each app group its own channel with two independent sends:

- **out** — to your speakers
- **stream** — to the shared virtual microphone

Each channel also has a **live level meter** that shows its raw incoming audio,
before the send faders. The bar keeps moving even when a channel's sends are
muted or turned down, so you can always see which channel is producing sound.

The bar shows a microphone and a speaker icon: left-click either to mute it,
right-click either to open the mixer.

## Features

- Per-channel buses over PipeWire null sinks
- Independent output and virtual-mic sends with their own faders and checks
- Live pre-fader level meters for every channel, with peak hold
- Route apps to channels by name, with rules that survive restarts
- Physical output/input device selection
- Optional mic noise suppression through a PipeWire filter chain
- Everything is user-level; state lives in `~/.config/wavemix/state.json`

## Requirements

- Arch Linux with Omarchy (the bar runs inside Quickshell)
- PipeWire with `pipewire-pulse` and WirePlumber
- Python 3.10+
- `pactl` and `pw-link` on `PATH`

Optional, for the **Noise suppression** switch: an RNNoise LADSPA plugin such as
`noise-suppression-for-voice`, plus the filter-chain fragment described below.

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
| `plugin/manifest.json` | `~/.config/omarchy/plugins/mnisyif.wavemix/manifest.json` |
| `plugin/Panel.qml` | `~/.config/omarchy/plugins/mnisyif.wavemix/Panel.qml` |
| `systemd/wavemix.service` | `~/.config/systemd/user/wavemix.service` |

It then enables and restarts the `wavemix` user service and asks the shell to
rescan plugins. If the widget still does not appear, restart the shell:

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

### CLI

```sh
wavemix status --json      # state plus the live graph
wavemix devices --json     # available outputs and inputs
wavemix apps --json        # app streams and their channels

wavemix send browser output volume 40
wavemix send browser output on
wavemix channel add "Podcasts"
wavemix route firefox podcasts
wavemix device output <sink-name>
```

Run `wavemix --help` for the full list.

## Noise suppression (optional)

The mic FX switch uses a PipeWire filter-chain node. Install an RNNoise LADSPA
plugin, then copy the example fragment and restart PipeWire:

```sh
install -Dm644 extras/90-wavemix-micfx.conf \
  ~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf

systemctl --user restart pipewire pipewire-pulse wireplumber
```

The fragment in `extras/` expects the plugin at
`/usr/lib/ladspa/librnnoise_ladspa.so`; adjust the path if your package puts it
elsewhere.

## Repository layout

```
bin/wavemix                     PipeWire channel mixer CLI and watcher
plugin/manifest.json            Omarchy bar-widget manifest
plugin/Panel.qml                Bar widget and mixer panel (live meters)
systemd/wavemix.service         User service that keeps the graph reconciled
extras/90-wavemix-micfx.conf    Optional RNNoise filter-chain fragment
install.sh                      Installer
```

## Uninstall

```sh
systemctl --user disable --now wavemix.service
rm -f ~/.local/bin/wavemix \
      ~/.config/systemd/user/wavemix.service \
      ~/.config/pipewire/pipewire.conf.d/90-wavemix-micfx.conf
rm -rf ~/.config/omarchy/plugins/mnisyif.wavemix
omarchy restart shell
```

Channel state is kept in `~/.config/wavemix/`; remove that directory too if you
want a clean slate.

## License

MIT. See [LICENSE](LICENSE).
