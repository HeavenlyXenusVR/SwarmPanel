# SwarmPanel Bugfix Patch - 2026-05-20

## Fixed

- Loaded SwarmPanel `.env` and sibling `Music/.env` before music bot definitions are frozen, so per-bot schema overrides such as `GWS_DB_NAME`, `STRIFE_DB_NAME`, and `LOCKHART_DB_NAME` are actually honored by the panel at runtime.
- Preserved `admin_mode` for site-owner account logins through `/api/session/login`; owner accounts no longer lose admin access after the first session refresh.
- Honored `PANEL_TELEGRAM_POLLING_ENABLED=false`; the panel no longer starts Telegram polling or startup alerts when polling is explicitly disabled.
- Cleaned up the duplicate `/api/telegram/status` route decorator.
- Hardened the legacy `verify_token` helper so it returns success explicitly and rejects requests when `PANEL_API_KEY` is missing instead of accidentally accepting an empty/missing key.
- Fixed diagnostics to include the existing `SMART_RECOMMEND` and `RECOVER` panel actions, use each bot definition's actual `table_prefix`, and fall back to shared DB/Lavalink env keys instead of showing false missing values when per-bot keys are not set.

## Validation

- Python syntax compile check passed for `app/` and `scripts/`.
- FastAPI app import and route registration passed with an `aiomysql` stub because the sandbox does not have the package installed globally.
- React/Vite production build passed using the bundled node modules after fixing extraction-time executable bits in the sandbox.
