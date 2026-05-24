# SwarmPanel Recommended Fixes Patch - 2026-05-24

Applied in recommended order from the audit:

1. Added a clean release exporter that excludes `.env`, `.env.*`, `.git`, `.venv`, `.runtime`, `.bin`, `node_modules`, logs, backups, live tunnel config, and other local/runtime artifacts.
2. Hardened `.gitignore` and `.dockerignore` so secrets/runtime state are not copied into source releases or Docker build contexts.
3. Stopped storing API bearer tokens in persistent `localStorage`. Tokens now live in memory plus `sessionStorage`, with one-time migration/removal of legacy localStorage tokens.
4. Tightened CSP by removing `script-src 'unsafe-inline'` from FastAPI-served pages and narrowing `connect-src` to the app origin plus configured allowed origins.
5. Added stricter CSRF/origin handling for authenticated cookie requests while still allowing CLI/internal bearer-token API calls without browser Origin/Referer.
6. Removed fake PLAY/SMART_RECOMMEND frontend fields that the backend discarded (`shuffle_before_play`, `save_playlist`, fake loop default). Unsupported stale payloads are no longer silently accepted.
7. Added API allowlist support for real backend-supported control payload fields: `force` and `vc_id`.
8. Replaced raw account-admin/diagnostics exception text in API responses with request-reference messages while logging full exceptions server-side.
9. Changed panel preference saves to merge with existing saved preferences so partial API updates do not reset omitted settings to defaults.
10. Wrapped `control_bot()` writes in an explicit transaction with rollback on error, and made queue shuffle transaction handling safe when called inside that outer transaction.
11. Made live/public mode require explicit `PANEL_PAGES_PUBLIC_URL`, `PANEL_CORS_ALLOWED_ORIGINS`, `SWARM_PANEL_SITE_OWNER_EMAIL`, and `PANEL_SESSION_HTTPS_ONLY=true` instead of relying on personal hardcoded defaults.
12. Updated live backend/tunnel scripts to read `PANEL_PAGES_PUBLIC_URL` from environment or `.env`, export live-mode safety flags, and avoid publishing an offline config during successful startup.
13. Diagnostics no longer reveal prefixes/suffixes of tokens, DB passwords, Lavalink passwords, or Gemini keys; secret fields now report only `present` or `missing`.
14. Rebuilt the React production bundle and cleaned stale old asset files.

Validation performed:

- `python -m compileall -q app scripts` passed.
- `bash -n scripts/start_live_backend.sh` passed.
- `bash -n scripts/start_live_tunnel_service.sh` passed.
- `node --check scripts/write-root-shell.mjs` passed.
- `node --check scripts/mock-ui-test.mjs` passed.
- `npm run build` passed.
- `npm run test:mock-ui` could not run in this sandbox because the Playwright Chromium browser binary is not installed.

The returned zip was generated with `scripts/export_clean_release.py` and should not contain local secrets, `.env` files, Git history, virtualenvs, node_modules, logs, or live tunnel config.
