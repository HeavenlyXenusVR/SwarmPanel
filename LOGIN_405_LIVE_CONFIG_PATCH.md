# SwarmPanel Login 405 / live-config hardening patch

## Problem fixed

The uploaded `live-config.json` was invalid JSON because it had an extra git-hash-like line before the closing brace. When the GitHub Pages/static React app could not parse that file, API origin discovery could fail and the login POST could hit the static host/proxy instead of FastAPI, returning an HTML `405 Not Allowed`.

## Fixes

- Repaired `live-config.json` to valid JSON.
- Bumped frontend API cache version to flush stale API-origin cache.
- Made remote config parsing tolerate accidental trailing garbage by recovering the first valid JSON object.
- Forced non-GET API requests, including login/register/logout/control actions, to refresh the live backend origin before sending.
- Added retry-on-405/404 for replayable requests when running from a remote static host.
- Added a clearer frontend error message for HTML `405 Not Allowed` responses.
- Added script-side validation so live-config.json is not auto-published if it is invalid JSON.

## Local check

After applying, restart the SwarmPanel live backend/tunnel and hard-refresh the GitHub Pages panel page.
