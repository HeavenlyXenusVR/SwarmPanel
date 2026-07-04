"""User profiles, panel preferences, social graph (follow/friends/messages),
and the cross-server user directory."""

import json
import re
from typing import Any

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import (
    _account_guild_id,
    _account_id_for_auth,
    _hydrate_site_owner_auth,
    _require_api_auth,
)
from ..bots import ALL_BOTS, BOT_INDEX
from ..schemas import (
    PanelPreferencesUpdateRequest,
    SocialFollowRequest,
    SocialFriendActionRequest,
    SocialMessageRequest,
    UserProfileUpdateRequest,
)
from ..security import _bounded_query_limit
from ..services import db, settings
from ..validators import (
    PANEL_BACKGROUND_MODES,
    PANEL_BOT_CARD_DETAILS,
    PANEL_CARD_HOVER_EFFECTS,
    PANEL_DASHBOARD_DENSITY_MODES,
    PANEL_DENSITY_MODES,
    PANEL_FONT_FAMILIES,
    PANEL_FONT_MODES,
    PANEL_LAYOUT_MODES,
    PANEL_MOTION_MODES,
    PANEL_NOTIFICATION_POSITIONS,
    PANEL_OPERATOR_LAYOUT_MODES,
    PANEL_RADIUS_MODES,
    PANEL_ROSTER_LAYOUT_MODES,
    PANEL_SHAPE_MODES,
    PANEL_SIDEBAR_STYLES,
    PANEL_STREAM_CARD_MODES,
    PANEL_TAB_STYLE_MODES,
    PANEL_THEME_MODES,
    PROFILE_BANNER_MODES,
    PROFILE_BORDER_ACCENTS,
    PROFILE_CARD_STYLES,
    PROFILE_HEADER_STYLES,
    PROFILE_LAYOUT_MODES,
    PROFILE_SOCIAL_MODES,
    _normalize_choice,
    _normalize_optional_text,
    _normalize_panel_look_choice,
    _normalize_profile_accent,
    _normalize_public_url,
    _normalize_server_invite_url,
)

router = APIRouter()


def _social_mode(profile: dict[str, Any] | None) -> str:
    mode = str((profile or {}).get("profile_social_mode") or "open").strip().lower()
    return mode if mode in PROFILE_SOCIAL_MODES else "open"


def _friend_status(profile: dict[str, Any] | None) -> str:
    return str((profile or {}).get("friend_status") or "none").strip().lower()


def _can_access_social_target(profile: dict[str, Any] | None, action: str) -> bool:
    status = _friend_status(profile)
    if status == "self":
        return True

    public_profile = bool((profile or {}).get("public_profile"))
    mode = _social_mode(profile)
    is_friend = status == "friends"
    normalized_action = str(action or "").strip().lower()

    if not public_profile:
        return is_friend and normalized_action in {"message", "view_friends"}
    if mode == "quiet":
        return False
    if mode == "friends":
        if normalized_action == "friend_request":
            return status not in {"friends", "pending_out", "pending_in", "self"}
        return is_friend
    return True


def _social_permissions(profile: dict[str, Any] | None) -> dict[str, bool]:
    status = _friend_status(profile)
    return {
        "can_follow": _can_access_social_target(profile, "follow") and status not in {"self", "pending_out"},
        "can_friend": _can_access_social_target(profile, "friend_request"),
        "can_message": _can_access_social_target(profile, "message") and status != "self",
        "can_view_friends": _can_access_social_target(profile, "view_friends"),
    }


async def _load_social_target_profile(account_id: int, viewer_id: int | None) -> dict[str, Any]:
    profile = await db.get_account_by_id(account_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")
    profile.update(await db.get_account_social_snapshot(int(profile["id"]), viewer_id))
    return profile


def _clean_profile_updates(payload: UserProfileUpdateRequest) -> dict[str, Any]:
    raw_updates = payload.model_dump(exclude_unset=True)
    updates: dict[str, Any] = {}
    for key, value in raw_updates.items():
        if key == "display_name":
            updates[key] = _normalize_optional_text(value, "Display name", 80)
        elif key == "avatar_url":
            updates[key] = _normalize_public_url(value, "Avatar URL")
        elif key == "bio":
            updates[key] = _normalize_optional_text(value, "Bio", 280)
        elif key == "profile_headline":
            updates[key] = _normalize_optional_text(value, "Profile headline", 140)
        elif key == "profile_tags":
            clean_tags = []
            for raw_tag in value or []:
                tag = re.sub(r"[^A-Za-z0-9_.-]+", "", str(raw_tag or "").strip())[:32]
                if tag and tag.lower() not in {existing.lower() for existing in clean_tags}:
                    clean_tags.append(tag)
            updates[key] = json.dumps(clean_tags[:12], separators=(",", ":"))
        elif key == "profile_links":
            clean_links = []
            for raw_link in value or []:
                label = _normalize_optional_text((raw_link or {}).get("label"), "Link label", 32)
                url = _normalize_public_url((raw_link or {}).get("url"), "Profile link", 600)
                if label and url:
                    clean_links.append({"label": label, "url": url})
            updates[key] = json.dumps(clean_links[:5], separators=(",", ":"))
        elif key == "profile_banner_url":
            updates[key] = _normalize_public_url(value, "Profile banner URL")
        elif key == "profile_banner_mode":
            updates[key] = _normalize_choice(value, "Profile banner", PROFILE_BANNER_MODES, "gradient")
        elif key == "profile_card_style":
            updates[key] = _normalize_choice(value, "Profile card style", PROFILE_CARD_STYLES, "solid")
        elif key == "profile_social_mode":
            updates[key] = _normalize_choice(value, "Profile social mode", PROFILE_SOCIAL_MODES, "open")
        elif key == "favorite_bot":
            favorite = _normalize_optional_text(value, "Favorite bot", 50)
            if favorite and favorite not in BOT_INDEX:
                raise ValueError("Favorite bot must be one of the known swarm bots")
            updates[key] = favorite
        elif key == "theme_accent":
            updates[key] = _normalize_profile_accent(value)
        elif key == "public_profile":
            updates[key] = bool(value)
        elif key == "server_invite_url":
            updates[key] = _normalize_server_invite_url(value)
        elif key == "server_name":
            updates[key] = _normalize_optional_text(value, "Server name", 120)
        elif key == "server_icon_url":
            updates[key] = _normalize_public_url(value, "Server icon URL")
        elif key == "profile_quote":
            updates[key] = _normalize_optional_text(value, "Profile quote", 160)
        elif key == "profile_layout_mode":
            updates[key] = _normalize_choice(value, "Profile layout", PROFILE_LAYOUT_MODES, "default")
        elif key == "profile_header_style":
            updates[key] = _normalize_choice(value, "Profile header style", PROFILE_HEADER_STYLES, "solid")
        elif key == "profile_border_accent":
            updates[key] = _normalize_choice(value, "Profile border accent", PROFILE_BORDER_ACCENTS, "none")
    return updates


def _clean_panel_preferences(payload: PanelPreferencesUpdateRequest) -> dict[str, Any]:
    raw = payload.model_dump(exclude_unset=True)
    preferences = {
        "theme_mode": "dark",
        "accent_color": "#89b4fa",
        "background_mode": "default",
        "background_color": "#0b0e18",
        "background_image_url": None,
        "profile_backdrop_image_url": None,
        "profile_backdrop_strength": 0.18,
        "layout_mode": "standard",
        "density": "comfortable",
        "card_shape": "soft",
        "font_scale": "normal",
        "motion": "standard",
        "operator_layout": "command",
        "roster_layout": "cards",
        "tab_style": "rail",
        "surface_opacity": 0.92,
        "surface_blur": 18,
        "stream_card_style": "telemetry",
        "dashboard_density": "command",
    }
    if "theme_mode" in raw:
        preferences["theme_mode"] = _normalize_choice(raw.get("theme_mode"), "Theme mode", PANEL_THEME_MODES, "dark")
    if "accent_color" in raw:
        preferences["accent_color"] = _normalize_profile_accent(raw.get("accent_color")) or "#89b4fa"
    if "background_mode" in raw:
        preferences["background_mode"] = _normalize_choice(raw.get("background_mode"), "Background mode", PANEL_BACKGROUND_MODES, "default")
    if "background_color" in raw:
        preferences["background_color"] = _normalize_profile_accent(raw.get("background_color")) or "#0b0e18"
    if "background_image_url" in raw:
        preferences["background_image_url"] = _normalize_public_url(raw.get("background_image_url"), "Background image URL")
    if "profile_backdrop_image_url" in raw:
        preferences["profile_backdrop_image_url"] = _normalize_public_url(raw.get("profile_backdrop_image_url"), "Profile backdrop image URL")
    if "profile_backdrop_strength" in raw:
        try:
            strength = float(raw.get("profile_backdrop_strength"))
        except (TypeError, ValueError):
            raise ValueError("Profile backdrop strength must be a number between 0.0 and 0.55") from None
        preferences["profile_backdrop_strength"] = max(0.0, min(strength, 0.55))
    if "layout_mode" in raw:
        preferences["layout_mode"] = _normalize_choice(raw.get("layout_mode"), "Layout mode", PANEL_LAYOUT_MODES, "standard")
    if "density" in raw:
        preferences["density"] = _normalize_choice(raw.get("density"), "Density", PANEL_DENSITY_MODES, "comfortable")
    if "card_shape" in raw:
        preferences["card_shape"] = _normalize_choice(raw.get("card_shape"), "Card shape", PANEL_SHAPE_MODES, "soft")
    if "font_scale" in raw:
        preferences["font_scale"] = _normalize_choice(raw.get("font_scale"), "Font scale", PANEL_FONT_MODES, "normal")
    if "motion" in raw:
        preferences["motion"] = _normalize_choice(raw.get("motion"), "Motion", PANEL_MOTION_MODES, "standard")
    if "operator_layout" in raw or "profile_layout" in raw:
        preferences["operator_layout"] = _normalize_panel_look_choice(
            raw.get("operator_layout", raw.get("profile_layout")),
            "Operator layout",
            "operator_layout",
            PANEL_OPERATOR_LAYOUT_MODES,
            "command",
        )
    if "roster_layout" in raw or "directory_layout" in raw:
        preferences["roster_layout"] = _normalize_panel_look_choice(
            raw.get("roster_layout", raw.get("directory_layout")),
            "Roster layout",
            "roster_layout",
            PANEL_ROSTER_LAYOUT_MODES,
            "cards",
        )
    if "tab_style" in raw:
        preferences["tab_style"] = _normalize_panel_look_choice(raw.get("tab_style"), "Tab style", "tab_style", PANEL_TAB_STYLE_MODES, "rail")
    if "surface_opacity" in raw:
        try:
            opacity = float(raw.get("surface_opacity"))
        except (TypeError, ValueError):
            raise ValueError("Surface opacity must be a number between 0.35 and 1.0") from None
        preferences["surface_opacity"] = max(0.35, min(opacity, 1.0))
    if "surface_blur" in raw:
        try:
            blur = int(raw.get("surface_blur"))
        except (TypeError, ValueError):
            raise ValueError("Surface blur must be an integer between 0 and 36") from None
        preferences["surface_blur"] = max(0, min(blur, 36))
    if "stream_card_style" in raw:
        preferences["stream_card_style"] = _normalize_panel_look_choice(
            raw.get("stream_card_style"),
            "Bot card style",
            "stream_card_style",
            PANEL_STREAM_CARD_MODES,
            "telemetry",
        )
    if "dashboard_density" in raw:
        preferences["dashboard_density"] = _normalize_panel_look_choice(
            raw.get("dashboard_density"),
            "Dashboard density",
            "dashboard_density",
            PANEL_DASHBOARD_DENSITY_MODES,
            "command",
        )
    if "sidebar_style" in raw:
        preferences["sidebar_style"] = _normalize_choice(raw.get("sidebar_style"), "Sidebar style", PANEL_SIDEBAR_STYLES, "full")
    if "panel_font_family" in raw:
        preferences["panel_font_family"] = _normalize_choice(raw.get("panel_font_family"), "Panel font", PANEL_FONT_FAMILIES, "system")
    if "card_hover_effect" in raw:
        preferences["card_hover_effect"] = _normalize_choice(raw.get("card_hover_effect"), "Card hover", PANEL_CARD_HOVER_EFFECTS, "lift")
    if "notification_position" in raw:
        preferences["notification_position"] = _normalize_choice(raw.get("notification_position"), "Notification position", PANEL_NOTIFICATION_POSITIONS, "br")
    if "bot_card_detail" in raw:
        preferences["bot_card_detail"] = _normalize_choice(raw.get("bot_card_detail"), "Bot card detail", PANEL_BOT_CARD_DETAILS, "full")
    if "panel_radius" in raw:
        preferences["panel_radius"] = _normalize_choice(raw.get("panel_radius"), "Panel radius", PANEL_RADIUS_MODES, "medium")
    if "accent_secondary" in raw:
        preferences["accent_secondary"] = _normalize_profile_accent(raw.get("accent_secondary")) or None
    if "show_bot_uptime" in raw:
        preferences["show_bot_uptime"] = bool(raw.get("show_bot_uptime", True))
    if "show_queue_pressure" in raw:
        preferences["show_queue_pressure"] = bool(raw.get("show_queue_pressure", True))
    if "compact_sidebar" in raw:
        preferences["compact_sidebar"] = bool(raw.get("compact_sidebar", False))
    return preferences


@router.get("/api/users/me")
async def api_user_profile_me(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or settings.admin_username)
    if not scoped_guild_id:
        return {
            "editable": False,
            "profile": {
                "username": username,
                "display_name": username,
                "guild_id": None,
                "public_profile": False,
                "has_password": False,
                "panel_preferences": _clean_panel_preferences(PanelPreferencesUpdateRequest()),
                "bio": "Built-in admin sessions can browse the user directory; registered accounts own public profiles.",
            },
            "favorite_bot_options": [
                {"key": bot.key, "display_name": bot.display_name, "kind": bot.kind}
                for bot in ALL_BOTS
            ],
        }

    profile = await db.get_account_profile(username, scoped_guild_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    profile.update(await db.get_account_social_snapshot(int(profile["id"]), int(profile["id"])))
    profile["activity"] = (
        await db.get_music_activity_summary_for_guilds([scoped_guild_id])
    ).get(str(scoped_guild_id), db._empty_music_activity_summary())
    return {
        "editable": True,
        "profile": profile,
        "favorite_bot_options": [
            {"key": bot.key, "display_name": bot.display_name, "kind": bot.kind}
            for bot in ALL_BOTS
        ],
    }


@router.post("/api/users/me")
async def api_update_user_profile(request: Request, payload: UserProfileUpdateRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required to edit a public profile")
    try:
        updates = _clean_profile_updates(payload)
        profile = await db.update_account_profile(username, scoped_guild_id, updates)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    profile["activity"] = (
        await db.get_music_activity_summary_for_guilds([scoped_guild_id])
    ).get(str(scoped_guild_id), db._empty_music_activity_summary())
    return {"ok": True, "profile": profile}


@router.get("/api/users/preferences")
async def api_user_panel_preferences(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    defaults = _clean_panel_preferences(PanelPreferencesUpdateRequest())
    if not scoped_guild_id or not username:
        return {"editable": False, "preferences": defaults}

    profile = await db.get_account_profile(username, scoped_guild_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    stored_preferences = profile.get("panel_preferences") or {}
    try:
        preferences = _clean_panel_preferences(PanelPreferencesUpdateRequest(**stored_preferences)) if stored_preferences else defaults
    except Exception:
        preferences = defaults
    return {
        "editable": True,
        "preferences": preferences,
    }


@router.post("/api/users/preferences")
async def api_update_user_panel_preferences(request: Request, payload: PanelPreferencesUpdateRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    scoped_guild_id = _account_guild_id(auth)
    username = str(auth.get("username") or "")
    if not scoped_guild_id or not username:
        raise HTTPException(status_code=403, detail="Guild account access required to save panel preferences")
    try:
        current_profile = await db.get_account_profile(username, scoped_guild_id)
        if not current_profile:
            raise HTTPException(status_code=404, detail="Account profile not found")
        defaults = _clean_panel_preferences(PanelPreferencesUpdateRequest())
        stored_preferences = current_profile.get("panel_preferences") or {}
        if isinstance(stored_preferences, str):
            try:
                stored_preferences = json.loads(stored_preferences)
            except Exception:
                stored_preferences = {}
        if not isinstance(stored_preferences, dict):
            stored_preferences = {}
        try:
            base_preferences = _clean_panel_preferences(PanelPreferencesUpdateRequest(**stored_preferences)) if stored_preferences else defaults
        except Exception:
            base_preferences = defaults
        requested_updates = payload.model_dump(exclude_unset=True)
        preferences = _clean_panel_preferences(PanelPreferencesUpdateRequest(**{**base_preferences, **requested_updates}))
        profile = await db.update_account_panel_preferences(username, scoped_guild_id, preferences)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not profile:
        raise HTTPException(status_code=404, detail="Account profile not found")
    return {"ok": True, "preferences": profile.get("panel_preferences") or preferences}


@router.get("/api/users/search")
async def api_search_users(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    query = " ".join(str(request.query_params.get("q") or "").split())[:80]
    limit = _bounded_query_limit(request.query_params.get("limit"), default=24, max_limit=50)
    viewer_id = None
    try:
        viewer_id = await _account_id_for_auth(auth)
    except Exception:
        viewer_id = None
    users = await db.search_account_profiles(query, limit, viewer_account_id=viewer_id)
    return {"ok": True, "query": query, "users": users, "limit": limit}


@router.get("/api/users/directory")
async def api_user_directory(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    query = " ".join(str(request.query_params.get("q") or "").split())[:80]
    limit = _bounded_query_limit(request.query_params.get("limit"), default=24, max_limit=50)
    viewer_id = None
    try:
        viewer_id = await _account_id_for_auth(auth)
    except Exception:
        viewer_id = None
    # The swarm directory is a cross-server roster of public profiles — each
    # account is tied to its own home guild, so scoping by guild_id would only
    # ever show a viewer their own profile (or none at all). Visibility is
    # already gated by public_profile=1 in search_account_profiles.
    users = await db.search_account_profiles(query, limit, viewer_account_id=viewer_id, guild_id=None)
    return {"ok": True, "query": query, "users": users, "limit": limit}


@router.get("/api/users/{account_id}/profile")
async def api_public_user_profile(account_id: int, request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    viewer_id = None
    try:
        viewer_id = await _account_id_for_auth(auth)
    except Exception:
        viewer_id = None
    profile = await db.get_public_account_profile(account_id, viewer_id)
    if not profile:
        raise HTTPException(status_code=404, detail="Profile not found")
    permissions = _social_permissions(profile)
    friends = await db.list_account_friends(int(profile["id"])) if permissions["can_view_friends"] else []
    return {
        "ok": True,
        "profile": profile,
        "friends": friends[:12],
        "social_permissions": permissions,
        "favorite_bot_options": [
            {"key": bot.key, "display_name": bot.display_name, "kind": bot.kind}
            for bot in ALL_BOTS
        ],
    }


@router.post("/api/users/{account_id}/follow")
async def api_follow_account(account_id: int, request: Request, payload: SocialFollowRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    target_profile = await _load_social_target_profile(account_id, actor_id)
    if payload.following and not _social_permissions(target_profile)["can_follow"]:
        raise HTTPException(status_code=403, detail="This profile is not accepting follows.")
    try:
        return {"ok": True, **await db.set_account_follow(actor_id, account_id, payload.following)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.post("/api/users/{account_id}/friend-request")
async def api_send_account_friend_request(account_id: int, request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    target_profile = await _load_social_target_profile(account_id, actor_id)
    if not _social_permissions(target_profile)["can_friend"]:
        raise HTTPException(status_code=403, detail="This profile is not accepting friend requests.")
    try:
        return {"ok": True, **await db.send_account_friend_request(actor_id, account_id)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None


@router.get("/api/friends/requests")
async def api_account_friend_requests(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    return {
        "ok": True,
        "incoming": await db.list_account_friend_requests(actor_id, mode="incoming"),
        "outgoing": await db.list_account_friend_requests(actor_id, mode="outgoing"),
    }


@router.post("/api/friends/requests/{request_id}")
async def api_account_friend_request_action(request_id: int, request: Request, payload: SocialFriendActionRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    try:
        result = await db.respond_account_friend_request(actor_id, request_id, payload.action)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    if not result:
        raise HTTPException(status_code=404, detail="Friend request not found")
    return {"ok": True, "request": result}


@router.get("/api/me/friends")
async def api_account_friends(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    return {"ok": True, "friends": await db.list_account_friends(actor_id)}


@router.get("/api/messages/threads")
async def api_account_message_threads(request: Request):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    return {"ok": True, "threads": await db.list_account_message_threads(actor_id)}


@router.get("/api/messages/{account_id}")
async def api_account_messages(account_id: int, request: Request, limit: int = 80):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    target_profile = await _load_social_target_profile(account_id, actor_id)
    if not _social_permissions(target_profile)["can_message"]:
        raise HTTPException(status_code=403, detail="This profile is not accepting direct messages.")
    try:
        messages = await db.list_account_messages(actor_id, account_id, limit=limit)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"ok": True, "messages": messages}


@router.post("/api/messages/{account_id}")
async def api_send_account_message(account_id: int, request: Request, payload: SocialMessageRequest):
    auth = await _hydrate_site_owner_auth(request, _require_api_auth(request))
    actor_id = await _account_id_for_auth(auth)
    target_profile = await _load_social_target_profile(account_id, actor_id)
    if not _social_permissions(target_profile)["can_message"]:
        raise HTTPException(status_code=403, detail="This profile is not accepting direct messages.")
    try:
        message = await db.send_account_message(actor_id, account_id, payload.body)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from None
    return {"ok": True, "message": message}
