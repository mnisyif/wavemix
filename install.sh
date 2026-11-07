#!/usr/bin/env bash
# Install Wavemix for the current user.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
plugin_dir="$config_home/omarchy/plugins/mnisyif.wavemix"
fx_plugin_dir="$config_home/omarchy/plugins/mnisyif.wavemix-fx"
service_dir="$config_home/systemd/user"
bundled_plugins="$data_home/wavemix/plugins"
config_file="$config_home/pipewire/pipewire.conf.d/90-wavemix-micfx.conf"

install -d "$bin_home" "$plugin_dir" "$fx_plugin_dir" "$service_dir"

install -m 0755 "$repo/bin/wavemix" "$bin_home/wavemix"
install -m 0644 "$repo/bin/wavemix_fx.py" "$bin_home/wavemix_fx.py"
install -m 0644 "$repo/plugin/manifest.json" "$plugin_dir/manifest.json"
install -m 0644 "$repo/plugin/Panel.qml" "$plugin_dir/Panel.qml"
install -m 0644 "$repo/fx-plugin/manifest.json" "$fx_plugin_dir/manifest.json"
install -m 0644 "$repo/fx-plugin/FxWindow.qml" "$fx_plugin_dir/FxWindow.qml"
install -m 0644 "$repo/systemd/wavemix.service" "$service_dir/wavemix.service"

# Bundled manifests are replaced as a set so a removed plugin really disappears.
# User manifests in the config directory are never touched.
rm -rf "$bundled_plugins"
install -d "$bundled_plugins"
install -m 0644 "$repo"/plugins/*.json "$bundled_plugins/"

# Create a default state file on first install; leave an existing one alone.
"$bin_home/wavemix" init >/dev/null || true

# Render before the service starts. Compare the result so an unchanged install
# does not restart PipeWire when the service comes back up.
config_before=""
if [ -f "$config_file" ]; then
  config_before="$(cat "$config_file")"
fi
"$bin_home/wavemix" fx render
config_after=""
if [ -f "$config_file" ]; then
  config_after="$(cat "$config_file")"
fi

systemctl --user daemon-reload
systemctl --user enable wavemix.service
systemctl --user restart wavemix.service

# fx apply is the only installer path that restarts PipeWire. Load the new
# chain only when the render actually changed it (fresh install or an update).
if [ "$config_before" != "$config_after" ]; then
  "$bin_home/wavemix" fx apply
fi

# A fresh install usually picks this up; a restart is the fallback.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins || true
  if command -v omarchy >/dev/null 2>&1; then
    omarchy plugin enable mnisyif.wavemix-fx >/dev/null 2>&1 || true
  fi
fi

printf '%s\n' \
  "Wavemix installed." \
  "If the bar widget is missing, run: omarchy restart shell"
