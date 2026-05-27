#!/usr/bin/env bash
set -euo pipefail

# NixOS/user-profile friendly PATH. systemd user services do not always inherit
# the interactive shell PATH, so keep repo-local tools, profile tools, and
# NixOS system tools visible.
export PATH="${HOME}/.local/bin:${HOME}/.nix-profile/bin:/etc/profiles/per-user/${USER}/bin:/run/current-system/sw/bin:${PATH:-}"


ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/swarmpanel-live-backend.service"

mkdir -p "${SERVICE_DIR}"

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=SwarmPanel live backend and GitHub Pages tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${ROOT_DIR}
Environment=PANEL_SERVICE_START_BACKEND_IF_MISSING=1
Environment=PANEL_PUSH_OFFLINE_CONFIG=0
Environment=PANEL_CLOUDFLARE_PROTOCOL=http2
Environment=PATH=%h/.local/bin:%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin:/usr/bin:/bin
Environment=PANEL_KILL_STALE_PORT=1
ExecStart=/run/current-system/sw/bin/env bash -lc 'cd "${ROOT_DIR}" && exec bash ./scripts/start_live_tunnel_service.sh 8000'
Restart=always
RestartSec=15
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now swarmpanel-live-backend.service

if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "${USER}" >/dev/null 2>&1 || true
fi

systemctl --user --no-pager status swarmpanel-live-backend.service
