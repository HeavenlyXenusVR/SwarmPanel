#!/usr/bin/env bash
set -euo pipefail

# NixOS/user-profile friendly PATH. systemd user services do not always inherit
# the interactive shell PATH, so keep repo-local tools, profile tools, and
# NixOS system tools visible.
export PATH="${HOME}/.local/bin:${HOME}/.nix-profile/bin:/etc/profiles/per-user/${USER}/bin:/run/current-system/sw/bin:${PATH:-}"


PORT="${1:-8000}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read_env_value() {
  local key="$1"
  local env_file="${ROOT_DIR}/.env"
  [[ -f "${env_file}" ]] || return 0
  grep -E "^${key}=" "${env_file}" | tail -n 1 | cut -d= -f2- | sed -e 's/^\"//' -e 's/\"$//' -e "s/^'//" -e "s/'$//" || true
}
VENV_DIR="${ROOT_DIR}/.venv"
BIN_DIR="${ROOT_DIR}/.bin"
PYTHON_BIN="${VENV_DIR}/bin/python"
PYTHON_TARGET_DIR="${ROOT_DIR}/.runtime/python-packages"
CONFIG_FILE="${ROOT_DIR}/live-config.json"
PAGES_ORIGIN="${PANEL_PAGES_ORIGIN:-$(read_env_value PANEL_PAGES_ORIGIN)}"
PAGES_URL="${PANEL_PAGES_PUBLIC_URL:-$(read_env_value PANEL_PAGES_PUBLIC_URL)}"
if [[ -z "${PAGES_URL}" ]]; then
  echo "PANEL_PAGES_PUBLIC_URL must be set for live mode, for example: https://YOUR_GITHUB_USERNAME.github.io/SwarmPanel/" >&2
  exit 1
fi
if [[ -z "${PAGES_ORIGIN}" ]]; then
  PAGES_ORIGIN="$(python3 - "${PAGES_URL}" <<'PY'
import sys
from urllib.parse import urlparse
parsed = urlparse(sys.argv[1] if len(sys.argv) > 1 else '')
print(f'{parsed.scheme}://{parsed.netloc}' if parsed.scheme and parsed.netloc else '')
PY
)"
fi
LOG_DIR="${ROOT_DIR}/.runtime"
UVICORN_LOG="${LOG_DIR}/uvicorn.log"
TUNNEL_LOG="${LOG_DIR}/cloudflared.log"
TUNNEL_PROVIDER="${PANEL_TUNNEL_PROVIDER:-auto}"
# Set PANEL_NGROK_DOMAIN to your free static ngrok subdomain to get a stable URL.
# Claim one at https://dashboard.ngrok.com/domains (free, one per account).
NGROK_STATIC_DOMAIN="${PANEL_NGROK_DOMAIN:-${NGROK_STATIC_DOMAIN:-}}"
PID_FILE="${LOG_DIR}/live_backend.pid"
INSTANCE_LOCK_FILE="${LOG_DIR}/live-manager.lock"
AUTO_PUSH_CONFIG="${PANEL_AUTO_PUSH_CONFIG:-1}"
PUSH_OFFLINE_CONFIG="${PANEL_PUSH_OFFLINE_CONFIG:-0}"

mkdir -p "${BIN_DIR}" "${LOG_DIR}"
echo "$$" > "${PID_FILE}"

current_live_url() {
  CONFIG_FILE_PATH="${CONFIG_FILE}" python3 <<'PY'
import json
import os
from pathlib import Path

config_path = Path(os.environ["CONFIG_FILE_PATH"])
try:
    payload = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    print("")
else:
    print(str(payload.get("panel_url") or "").strip())
PY
}

acquire_instance_lock() {
  exec {INSTANCE_LOCK_FD}> "${INSTANCE_LOCK_FILE}"
  if flock -n "${INSTANCE_LOCK_FD}"; then
    return 0
  fi

  local existing_url
  existing_url="$(current_live_url)"
  echo "Another SwarmPanel live tunnel manager is already running."
  if [[ -n "${existing_url}" ]]; then
    echo "Current published live URL: ${existing_url}"
  else
    echo "Current published live URL is not available yet. Reuse the running manager instead of starting a second tunnel."
  fi
  exit 0
}

release_instance_lock() {
  if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
    flock -u "${INSTANCE_LOCK_FD}" || true
    eval "exec ${INSTANCE_LOCK_FD}>&-"
    INSTANCE_LOCK_FD=""
  fi
}

flush_local_dns_cache() {
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches >/dev/null 2>&1 || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    systemd-resolve --flush-caches >/dev/null 2>&1 || true
  fi
}

write_config() {
  local panel_url="$1"
  cat > "${CONFIG_FILE}" <<EOF
{
  "panel_url": "${panel_url}",
  "updated_at": "$(date -Is)"
}
EOF
}

write_offline_config() {
  cat > "${CONFIG_FILE}" <<EOF
{
  "panel_url": "",
  "updated_at": "$(date -Is)"
}
EOF
}


validate_config_json() {
  CONFIG_FILE_PATH="${CONFIG_FILE}" python3 <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["CONFIG_FILE_PATH"])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"Invalid live-config.json; refusing to publish: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print("Invalid live-config.json; root must be an object.", file=sys.stderr)
    sys.exit(1)
PY
}

run_host_git() {
  if command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host git -C "${ROOT_DIR}" "$@"
  else
    git -C "${ROOT_DIR}" "$@"
  fi
}

publish_config() {
  validate_config_json || return
  if [[ "${AUTO_PUSH_CONFIG}" != "1" ]]; then
    return
  fi
  if ! command -v git >/dev/null 2>&1 && ! command -v flatpak-spawn >/dev/null 2>&1; then
    echo "Skipping live-config push because git is unavailable." >&2
    return
  fi
  if ! run_host_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipping live-config push because ${ROOT_DIR} is not a git work tree." >&2
    return
  fi
  if run_host_git diff --quiet -- live-config.json; then
    return
  fi
  echo "Publishing updated live-config.json to GitHub Pages..."
  run_host_git add live-config.json
  run_host_git commit -m "Update live backend URL" -- live-config.json || true
  run_host_git push origin main || echo "Could not push live-config.json automatically. Push it manually when convenient." >&2
}

install_python_deps() {
  if [[ -x "${VENV_DIR}/bin/python" ]] && ! "${VENV_DIR}/bin/python" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
    echo "Existing virtualenv Python wrapper is unusable; rebuilding ${VENV_DIR}..." >&2
    rm -rf "${VENV_DIR}"
  fi
  if [[ -x "${VENV_DIR}/bin/python" ]] && ! "${VENV_DIR}/bin/python" -m pip --version >/dev/null 2>&1; then
    echo "Existing virtualenv cannot run pip; rebuilding ${VENV_DIR}..." >&2
    rm -rf "${VENV_DIR}"
  fi
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    if ! python3 -m venv "${VENV_DIR}"; then
      echo "python3 venv support is unavailable; installing dependencies into ${PYTHON_TARGET_DIR}." >&2
      rm -rf "${VENV_DIR}"
      mkdir -p "${PYTHON_TARGET_DIR}"
      python3 -m pip install --upgrade --target "${PYTHON_TARGET_DIR}" -r "${ROOT_DIR}/requirements.txt"
      PYTHON_BIN="python3"
      export PYTHONPATH="${PYTHON_TARGET_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
      return
    fi
  fi
  if ! "${VENV_DIR}/bin/python" -c 'import sys; print(sys.executable)' >/dev/null 2>&1; then
    echo "Virtualenv Python wrapper is still unusable after creation; rebuilding ${VENV_DIR} with symlinks." >&2
    rm -rf "${VENV_DIR}"
    python3 -m venv --symlinks "${VENV_DIR}"
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python"
  "${PYTHON_BIN}" -m pip install --upgrade pip
  "${PYTHON_BIN}" -m pip install -r "${ROOT_DIR}/requirements.txt"
}

ngrok_bin() {
  # Prefer the user-local install we put in ~/.local/bin, then PATH, then .bin/
  for candidate in "${HOME}/.local/bin/ngrok" "${BIN_DIR}/ngrok"; do
    if [[ -x "${candidate}" ]]; then echo "${candidate}"; return; fi
  done
  if command -v ngrok >/dev/null 2>&1; then command -v ngrok; return; fi
  echo "" # not found
}

start_ngrok_tunnel() {
  local bin
  bin="$(ngrok_bin)"
  if [[ -z "${bin}" ]]; then
    echo "ngrok binary not found; skipping ngrok tunnel." >&2
    return 1
  fi
  local ngrok_log="${LOG_DIR}/ngrok.log"
  : > "${ngrok_log}"

  if [[ -n "${NGROK_STATIC_DOMAIN}" ]]; then
    echo "Opening ngrok tunnel on static domain ${NGROK_STATIC_DOMAIN}..."
    "${bin}" http "--domain=${NGROK_STATIC_DOMAIN}" --log=stdout --log-format=json "${PORT}" >"${ngrok_log}" 2>&1 &
  else
    echo "Opening ngrok tunnel (random URL — set PANEL_NGROK_DOMAIN for a stable URL)..."
    "${bin}" http --log=stdout --log-format=json "${PORT}" >"${ngrok_log}" 2>&1 &
  fi
  TUNNEL_PID="$!"

  local panel_url=""
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "ngrok exited early. Last log lines:" >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
    fi
    panel_url="$(python3 -c "
import sys, json
for line in open('${ngrok_log}'):
    try:
        d=json.loads(line)
        u=d.get('url','')
        if u.startswith('https://'): print(u); break
    except: pass
" 2>/dev/null || true)"
    if [[ -n "${panel_url}" ]]; then
      echo "Waiting for ${panel_url} to answer through ngrok..."
      for _ in {1..40}; do
        if curl -fsS --max-time 10 "${panel_url}/api/session" >/dev/null 2>&1; then break; fi
        if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then break; fi
        sleep 1
      done
      if curl -fsS --max-time 10 "${panel_url}/api/session" >/dev/null 2>&1; then
        TUNNEL_LOG="${ngrok_log}"
        write_config "${panel_url}"
        flush_local_dns_cache
        PUBLISHED_PANEL_URL="${panel_url}"
        publish_config
        echo; echo "Live backend URL: ${panel_url}"; echo "GitHub Pages front-end: ${PAGES_URL}"; echo
        echo "Keep this script running while you want the live site connected."
        wait "${TUNNEL_PID}"; exit $?
      fi
      echo "ngrok URL never became reachable." >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
    fi
    sleep 0.5
  done
  echo "Timed out waiting for ngrok URL." >&2; tail -40 "${ngrok_log}" >&2 || true; return 1
}

cloudflared_bin() {
  if command -v cloudflared >/dev/null 2>&1; then
    command -v cloudflared
    return
  fi

  local local_bin="${BIN_DIR}/cloudflared"
  if [[ -x "${local_bin}" ]]; then
    echo "${local_bin}"
    return
  fi

  local machine
  machine="$(uname -m)"
  local arch="amd64"
  if [[ "${machine}" == "aarch64" || "${machine}" == "arm64" ]]; then
    arch="arm64"
  fi

  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  echo "Downloading cloudflared (${arch})..." >&2
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail "${url}" -o "${local_bin}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${local_bin}" "${url}"
  else
    echo "Need curl or wget to download cloudflared." >&2
    exit 1
  fi
  chmod +x "${local_bin}"
  echo "${local_bin}"
}

cleanup() {
  release_instance_lock
  if [[ -n "${PUBLISHED_PANEL_URL:-}" ]] && grep -Fq "\"panel_url\": \"${PUBLISHED_PANEL_URL}\"" "${CONFIG_FILE}" 2>/dev/null; then
    publish_offline_config
  fi
  rm -f "${PID_FILE}"
  if [[ -n "${UVICORN_PID:-}" ]]; then
    kill "${UVICORN_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

acquire_instance_lock

install_python_deps
CLOUDFLARED="$(cloudflared_bin)"

export PANEL_LIVE_MODE="${PANEL_LIVE_MODE:-true}"
export PANEL_SESSION_HTTPS_ONLY="${PANEL_SESSION_HTTPS_ONLY:-true}"
export PANEL_PAGES_PUBLIC_URL="${PAGES_URL}"
export PANEL_CORS_ALLOWED_ORIGINS="${PANEL_CORS_ALLOWED_ORIGINS:-${PAGES_ORIGIN},${PAGES_URL%/},http://127.0.0.1:${PORT},http://localhost:${PORT}}"
if [[ -z "${PANEL_DB_HOST:-}" || "${PANEL_DB_HOST}" == "host.docker.internal" ]]; then
  export PANEL_DB_HOST="127.0.0.1"
fi

cd "${ROOT_DIR}"
echo "Starting SwarmPanel backend on http://127.0.0.1:${PORT}"
"${PYTHON_BIN}" -m uvicorn app.main:app --host 127.0.0.1 --port "${PORT}" >"${UVICORN_LOG}" 2>&1 &
UVICORN_PID="$!"

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:${PORT}/api/session" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "${UVICORN_PID}" >/dev/null 2>&1; then
    echo "Backend exited early. Last log lines:" >&2
    tail -80 "${UVICORN_LOG}" >&2 || true
    exit 1
  fi
  sleep 0.5
done

# ── Tunnel provider dispatch ──────────────────────────────────────────────────
# Priority (auto mode): ngrok with static domain → Cloudflare quick tunnel
# Set PANEL_TUNNEL_PROVIDER=ngrok|cloudflare to force a specific provider.

if [[ "${TUNNEL_PROVIDER}" == "ngrok" ]] || \
   [[ "${TUNNEL_PROVIDER}" == "auto" && -n "${NGROK_STATIC_DOMAIN}" ]]; then
  start_ngrok_tunnel && exit 0 || true
fi

if [[ "${TUNNEL_PROVIDER}" == "cloudflare" || "${TUNNEL_PROVIDER}" == "auto" ]]; then
  echo "Opening Cloudflare quick tunnel..."
  "${CLOUDFLARED}" tunnel --no-autoupdate --protocol http2 --url "http://127.0.0.1:${PORT}" >"${TUNNEL_LOG}" 2>&1 &
  TUNNEL_PID="$!"

  PANEL_URL=""
  for _ in {1..80}; do
    if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then
      echo "Tunnel exited early. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      break
    fi
    PANEL_URL="$(grep -Eo 'https://[-a-zA-Z0-9.]+trycloudflare\.com' "${TUNNEL_LOG}" | tail -1 || true)"
    if [[ -n "${PANEL_URL}" ]]; then
      echo "Waiting for ${PANEL_URL} to answer through Cloudflare..."
      for _ in {1..40}; do
        if curl -fsS --max-time 10 "${PANEL_URL}/api/session" >/dev/null 2>&1; then break; fi
        if ! kill -0 "${TUNNEL_PID}" >/dev/null 2>&1; then break; fi
        sleep 1
      done
      if curl -fsS --max-time 10 "${PANEL_URL}/api/session" >/dev/null 2>&1; then
        write_config "${PANEL_URL}"
        flush_local_dns_cache
        PUBLISHED_PANEL_URL="${PANEL_URL}"
        publish_config
        echo; echo "Live backend URL: ${PANEL_URL}"; echo "Updated ${CONFIG_FILE}"
        echo "GitHub Pages front-end: ${PAGES_URL}"; echo
        echo "Keep this script running while you want the live site connected."
        wait "${TUNNEL_PID}"; exit $?
      fi
      echo "Cloudflare URL was created but never became reachable. Last log lines:" >&2
      tail -80 "${TUNNEL_LOG}" >&2 || true
      break
    fi
    sleep 0.5
  done
  echo "Cloudflare quick tunnel did not become usable." >&2
fi

echo "No tunnel could be established." >&2
exit 1
