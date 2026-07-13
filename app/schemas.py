"""Pydantic request models for every router, grouped by domain. Route paths
and validation behavior are unchanged from the pre-split main.py — this is a
pure relocation."""

from typing import Any

from pydantic import BaseModel, model_validator

from .bots import BOT_INDEX

# --- Database browser -------------------------------------------------------


class TruncateTableRequest(BaseModel):
    schema_name: str
    table_name: str
    confirm_text: str
    owner_confirm_text: str = ""


class TruncateSchemaRequest(BaseModel):
    schema_name: str
    confirm_text: str
    owner_confirm_text: str = ""


# --- Session / auth ----------------------------------------------------------


class SessionLoginRequest(BaseModel):
    username: str
    password: str
    guild_id: str | int | None = None


class SessionRegisterRequest(BaseModel):
    username: str
    guild_id: str | int
    password: str
    email: str | None = None
    verification_webhook_url: str | None = None
    registration_proof_url: str | None = None


class SessionAdminModeRequest(BaseModel):
    enabled: bool


class SessionEmailUpdateRequest(BaseModel):
    email: str | None = None


class SessionEmailCodeRequest(BaseModel):
    code: str


class SessionVerificationWebhookRequest(BaseModel):
    verification_webhook_url: str | None = None


class SessionPasswordUpdateRequest(BaseModel):
    current_password: str
    new_password: str


# --- Social (friends/follows/messages) ---------------------------------------


class SocialFollowRequest(BaseModel):
    following: bool = True


class SocialFriendActionRequest(BaseModel):
    action: str


class SocialMessageRequest(BaseModel):
    body: str


# --- Swarm accounts admin -----------------------------------------------------


class SwarmAccountDeleteRequest(BaseModel):
    account_id: int


class SwarmAccountUpdateRequest(BaseModel):
    account_id: int
    username: str | None = None
    guild_id: str | int | None = None
    email: str | None = None
    display_name: str | None = None
    public_profile: bool | None = None
    server_name: str | None = None


class SwarmAccountFlagRequest(BaseModel):
    account_id: int
    verified: bool


class SwarmAccountPasswordResetRequest(BaseModel):
    account_id: int
    new_password: str


class SwarmAccountBulkDeleteRequest(BaseModel):
    ids: list[int]


class SwarmAccountBulkVerifyRequest(BaseModel):
    ids: list[int]
    verified: bool = True


class SwarmAccountModeratorRequest(BaseModel):
    account_id: int
    moderator: bool


# --- Image Gallery admin ------------------------------------------------------


class GalleryUserDeleteRequest(BaseModel):
    user_id: int


class GalleryCommentDeleteRequest(BaseModel):
    comment_id: int


class GalleryPasswordResetRequest(BaseModel):
    user_id: int
    new_password: str


class GalleryUserUpdateRequest(BaseModel):
    user_id: int
    username: str | None = None
    display_name: str | None = None
    email: str | None = None
    public_profile: bool | None = None
    show_liked_count: bool | None = None
    adult_content_consent: bool | None = None


class GalleryUserFlagRequest(BaseModel):
    user_id: int
    verified: bool


class GalleryMediaDeleteRequest(BaseModel):
    media_id: int


class GalleryMediaUpdateRequest(BaseModel):
    media_id: int
    title: str | None = None
    is_adult: bool | None = None
    moderation_status: str | None = None
    moderation_reason: str | None = None


class GalleryReportStatusRequest(BaseModel):
    report_id: int
    status: str


class GalleryMediaBulkDeleteRequest(BaseModel):
    ids: list[int]


class GalleryCommentBulkDeleteRequest(BaseModel):
    ids: list[int]


class GalleryUserBulkDeleteRequest(BaseModel):
    ids: list[int]


# --- User profile / panel appearance ------------------------------------------


class UserProfileUpdateRequest(BaseModel):
    display_name: str | None = None
    avatar_url: str | None = None
    bio: str | None = None
    profile_headline: str | None = None
    profile_tags: list[str] | None = None
    profile_links: list[dict[str, str]] | None = None
    profile_banner_url: str | None = None
    profile_banner_mode: str | None = None
    profile_card_style: str | None = None
    profile_social_mode: str | None = None
    favorite_bot: str | None = None
    theme_accent: str | None = None
    public_profile: bool | None = None
    server_invite_url: str | None = None
    server_name: str | None = None
    server_icon_url: str | None = None
    profile_quote: str | None = None
    profile_layout_mode: str | None = None
    profile_header_style: str | None = None
    profile_border_accent: str | None = None


class PanelPreferencesUpdateRequest(BaseModel):
    theme_mode: str | None = None
    accent_color: str | None = None
    background_mode: str | None = None
    background_color: str | None = None
    background_image_url: str | None = None
    profile_backdrop_image_url: str | None = None
    profile_backdrop_strength: float | None = None
    layout_mode: str | None = None
    density: str | None = None
    card_shape: str | None = None
    font_scale: str | None = None
    motion: str | None = None
    operator_layout: str | None = None
    roster_layout: str | None = None
    profile_layout: str | None = None
    directory_layout: str | None = None
    tab_style: str | None = None
    surface_opacity: float | None = None
    surface_blur: int | None = None
    stream_card_style: str | None = None
    dashboard_density: str | None = None
    sidebar_style: str | None = None
    panel_font_family: str | None = None
    card_hover_effect: str | None = None
    notification_position: str | None = None
    bot_card_detail: str | None = None
    panel_radius: str | None = None
    accent_secondary: str | None = None
    show_bot_uptime: bool | None = None
    show_queue_pressure: bool | None = None
    compact_sidebar: bool | None = None


# --- Lumisound admin ------------------------------------------------------------


class LumisoundUploadDeleteRequest(BaseModel):
    upload_id: int


class LumisoundUserActiveRequest(BaseModel):
    user_id: int
    active: bool


class LumisoundBugReportStatusRequest(BaseModel):
    report_id: int
    status: str


# --- Configurable alerting ----------------------------------------------------


class AlertRuleCreateRequest(BaseModel):
    rule_type: str
    threshold_minutes: int = 5
    enabled: bool = True
    escalation_minutes: int | None = None
    escalate_email: bool = False


class AlertRuleUpdateRequest(BaseModel):
    rule_type: str | None = None
    threshold_minutes: int | None = None
    enabled: bool | None = None
    escalation_minutes: int | None = None
    escalate_email: bool | None = None


# --- Saved queues / playlists --------------------------------------------------


class SavedQueueItem(BaseModel):
    video_url: str
    title: str | None = None
    requester_id: str | int | None = None


class SavedQueueCreateRequest(BaseModel):
    guild_id: str | int
    bot_key: str
    name: str
    items: list[SavedQueueItem]


class SavedQueueDeleteRequest(BaseModel):
    guild_id: str | int


# --- Bot control ---------------------------------------------------------------


class BotControlRequest(BaseModel):
    bot_key: str
    guild_id: str | int | None = None
    action: str | None = None
    command: str | None = None
    payload: Any | None = None

    @model_validator(mode="after")
    def _sync_action_aliases(self):
        self.bot_key = str(self.bot_key or "").strip().lower()
        if self.bot_key not in BOT_INDEX:
            raise ValueError("Unknown bot key")
        normalized_action = (self.action or self.command or "").strip()
        if not normalized_action:
            raise ValueError("Missing action")
        self.action = normalized_action
        self.command = normalized_action
        if self.guild_id in (None, ""):
            if normalized_action.upper() == "RESTART":
                self.guild_id = "0"
            else:
                raise ValueError("guild_id is required for non-RESTART actions")
        return self
