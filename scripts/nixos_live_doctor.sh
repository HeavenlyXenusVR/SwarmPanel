#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.nix-profile/bin:/etc/profiles/per-user/${USER}/bin:/run/current-system/sw/bin:${PATH:-}"

check_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '[ok] %-12s %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '[missing] %s\n' "$cmd"
  fi
}

echo "SwarmPanel NixOS live doctor"
echo "Root: $ROOT_DIR"
echo
for cmd in bash python3 git gh cloudflared curl jq ss systemctl; do
  check_cmd "$cmd"
done

echo
if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[ok] git work tree"
  git -C "$ROOT_DIR" remote -v | sed 's/^/  /'
else
  echo "[warn] not a git work tree; live-config auto-push will be skipped"
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    echo "[ok] gh auth"
  else
    echo "[warn] gh is installed but not authenticated. Run: gh auth login"
  fi
fi

echo
if [[ -f "$ROOT_DIR/.env" ]]; then
  echo "[ok] .env exists"
else
  echo "[warn] .env missing"
fi

if [[ -f "$ROOT_DIR/requirements.txt" ]]; then
  echo "[ok] requirements.txt exists"
else
  echo "[warn] requirements.txt missing"
fi

echo
if curl -fsS --max-time 5 http://127.0.0.1:8000/api/session >/dev/null 2>&1; then
  echo "[ok] local backend responding on :8000"
else
  echo "[info] local backend not responding on :8000"
fi
