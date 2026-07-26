#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-/etc/nixos/configuration.nix}"

if [[ ! -f "$CONFIG" ]]; then
  echo "NixOS configuration not found: $CONFIG" >&2
  exit 1
fi

sudo cp -a "$CONFIG" "$CONFIG.bak.swarmpanel-nixos-deps.$(date +%F_%H%M%S)"

add_pkg() {
  local pkg="$1"
  if grep -Eq "^[[:space:]]*${pkg//./\\.}[[:space:]]*$" "$CONFIG"; then
    return 0
  fi
  sudo sed -i "/environment.systemPackages = with pkgs; \[/a\\    ${pkg}" "$CONFIG"
}

# CLI/runtime tools used by SwarmPanel live scripts on NixOS.
add_pkg git
add_pkg gh
add_pkg cloudflared
add_pkg curl
add_pkg wget
add_pkg jq
add_pkg dnsutils
add_pkg iproute2
add_pkg lsof
add_pkg psmisc
add_pkg python311Full
add_pkg nodejs

# Keep flakes/nix-command enabled for profile/flake based tools.
grep -q 'nix.settings.experimental-features' "$CONFIG" || sudo sed -i '/system.stateVersion/a\\\n  nix.settings.experimental-features = [ "nix-command" "flakes" ];' "$CONFIG"

echo "Added/verified SwarmPanel NixOS dependencies in $CONFIG"
echo "Next: sudo nixos-rebuild dry-build && sudo nixos-rebuild switch"
