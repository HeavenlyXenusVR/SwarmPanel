# SwarmPanel

![Witch Knot site icon](favicon.ico)

SwarmPanel is the React and FastAPI command center for Aria and the 12-node music bot fleet. It focuses on live operational visibility, queue and playback control, owner-safe administration, account profiles, social features, and mobile-friendly monitoring.

## What It Does

- Shows live bot status across all music nodes: track, guild, voice channel, queue depth, backup depth, filters, heartbeat, and drift.
- Sends direct bot controls to the fleet for play, pause, resume, skip, stop, loop, filter, queue, and recovery actions.
- Gives the owner expanded admin mode for database inspection, destructive-action safeguards, bot control, and operational review.
- Tracks Swarm health, stale nodes, Medic warnings, queue recovery candidates, voice failures, and database issues.
- Provides user accounts with profile pages, avatars, display names, bios, links, profile colors, visibility, and online or inactive presence.
- Supports profile discovery, friend requests, follows, and direct messages between panel users.
- Includes appearance controls with real previews so users can see how dashboard, queue, Medic, and database sections will look.
- Sends scoped Telegram operator alerts for important panel health issues without spamming normal logs.
- Publishes a static GitHub Pages frontend that reads `live-config.json` for the current live backend URL.

## Main Surfaces

- **Dashboard:** fleet status, health summaries, queue state, heartbeat checks, and active warnings.
- **Bots:** per-node command controls, current playback, guild/channel inventory, and Lavalink-backed playback state.
- **Medic:** Aria-reported drift, stale nodes, recovery candidates, and voice connection trouble.
- **Database:** schema browser, guarded table reads, guarded truncation, and owner-only destructive controls.
- **Users:** profile directory, social actions, presence, messaging, follows, and friend request flows.
- **Appearance:** theme customization, density choices, accent controls, light and dark modes, and live panel previews.

## Servers And Data

- Frontend: React and Vite, deployable to GitHub Pages.
- Backend: FastAPI app served from `app.main`.
- Database: MySQL schemas for panel accounts, Aria telemetry, and each music bot queue.
- Bot network: 12 Discord music bots plus Aria.
- Audio control: Lavalink-backed bots with panel-issued command requests.
- Operator alerts: Telegram bridge for scoped health and database notices.

## Guardrails

- Destructive database actions require explicit owner confirmation.
- Secrets belong in ignored environment files, never in committed code.
- Admin mode is treated as owner-only authority, not a regular user feature.
- Owner elevation requires a verified email that matches `SWARM_PANEL_SITE_OWNER_EMAIL`.
- Guild account registration requires a Discord webhook proof from the target server.
- External bot tokens are not surfaced in the frontend or README.
- Queue and Medic data should be treated as operational telemetry, not decoration.

## Copyright

(c) HeavenlyXenusVR. Discord: <https://discord.com/users/1304564041863266347>
