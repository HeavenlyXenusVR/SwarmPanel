# SwarmPanel Deep Audit Patch

## Fixed

- Hardened frontend live refresh polling so slow requests cannot overlap and dogpile the backend.
- Added frontend API fetch timeout protection so dead tunnels do not leave React views stuck forever.
- Validated remote live-config API origins so GitHub Pages mode only accepts safe http/https origins, with HTTPS enforced except localhost loopback.
- Bumped frontend cache version so stale cached API responses are discarded after this patch.
- Made package scripts call Vite directly through `node ./node_modules/vite/bin/vite.js`; this avoids broken `.bin/vite` wrapper files after zip extraction.
- Added safe backend error details for database/control/stability failures so raw DB or internal exception details do not get returned to the browser. Full detail stays in logs with a request id.
- Hardened websocket handling with receive timeouts, ping keepalive, and inbound message size limits.
- Enforced a minimum 32-character `PANEL_SESSION_SECRET`.

## Verified

- Python backend files compile.
- `scripts/api_route_test.py` passes with the project virtualenv.
- React/Vite production build passes using the direct Vite entry point.
