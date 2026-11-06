#!/usr/bin/env bash
# Install Wavemix for the current user.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
bin_home="${XDG_BIN_HOME:-$HOME/.local/bin}"
plugin_dir="$config_home/omarchy/plugins/mnisyif.wavemix"
service_dir="$config_home/systemd/user"

install -d "$bin_home" "$plugin_dir" "$service_dir"

install -m 0755 "$repo/bin/wavemix" "$bin_home/wavemix"
install -m 0644 "$repo/plugin/manifest.json" "$plugin_dir/manifest.json"
install -m 0644 "$repo/plugin/Panel.qml" "$plugin_dir/Panel.qml"
install -m 0644 "$repo/systemd/wavemix.service" "$service_dir/wavemix.service"

# Create a default state file on first install; leave an existing one alone.
"$bin_home/wavemix" init >/dev/null || true

systemctl --user daemon-reload
systemctl --user enable wavemix.service
systemctl --user restart wavemix.service

# A fresh install usually picks this up; a restart is the fallback.
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins || true
fi

printf '%s\n' \
  "Wavemix installed." \
  "If the bar widget is missing, run: omarchy restart shell"
