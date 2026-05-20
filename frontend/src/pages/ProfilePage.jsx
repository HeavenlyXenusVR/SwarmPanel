import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { Check, ExternalLink, Heart, KeyRound, Mail, MessageCircle, Music2, Save, ShieldCheck, UserPlus } from "lucide-react";
import { apiFetch, cachedFetch, clearCache } from "../api.js";
import { EmptyState, Page, SkeletonGrid } from "../components/ui.jsx";
import { IdentityAvatar, PresencePill } from "../components/swarm.jsx";
import { pick } from "../utils/format.js";
import { profileLayoutClass } from "../utils/control.js";

function profileToForm(profile = {}) {
  const links = Array.isArray(profile.profile_links) ? profile.profile_links : [];
  return {
    ...profile,
    profile_tags_text: (profile.profile_tags || []).join(", "),
    profile_links: [...links, {}, {}, {}, {}, {}].slice(0, 5),
    profile_banner_mode: profile.profile_banner_mode || "gradient",
    profile_card_style: profile.profile_card_style || "solid",
    profile_social_mode: profile.profile_social_mode || "open",
  };
}

function formToPayload(form) {
  const tags = String(form.profile_tags_text || "").split(",").map((tag) => tag.trim()).filter(Boolean);
  const links = (Array.isArray(form.profile_links) ? form.profile_links : []).map((link) => ({
    label: String(link?.label || "").trim(),
    url: String(link?.url || "").trim(),
  })).filter((link) => link.label && link.url);
  return {
    ...pick(form, ["display_name", "avatar_url", "bio", "profile_headline", "profile_banner_url", "profile_banner_mode", "profile_card_style", "profile_social_mode", "favorite_bot", "theme_accent", "public_profile", "server_invite_url", "server_name", "server_icon_url"]),
    profile_tags: tags,
    profile_links: links,
  };
}

function ProfileAvatar({ profile }) {
  const src = profile?.avatar_url || profile?.server_icon_url;
  return <IdentityAvatar src={src} label={profile?.display_name || profile?.username || "SP"} online={profile?.is_online} className="avatar profile-avatar-xl avatar-presence" />;
}

export default function ProfilePage({ ctx }) {
  const { accountId } = useParams();
  const publicMode = Boolean(accountId);
  const [data, setData] = useState(null);
  const [form, setForm] = useState({});
  const [identity, setIdentity] = useState({ email: "", code: "", current_password: "", new_password: "" });
  const [busy, setBusy] = useState("");

  const load = useCallback(async () => {
    const payload = publicMode
      ? await cachedFetch(`/api/users/${accountId}/profile`, { ttl: 20_000, staleTtl: 120_000 })
      : await cachedFetch("/api/users/me", { ttl: 20_000, staleTtl: 120_000 });
    setData(payload);
    setForm(profileToForm(payload.profile || {}));
    setIdentity((current) => ({ ...current, email: payload.profile?.email || "" }));
  }, [accountId, publicMode]);

  useEffect(() => { load().catch((error) => ctx.showToast(error.message, "error")); }, [ctx, load]);

  function clearProfileCache() {
    clearCache("/api/users/me");
    clearCache("/api/users/directory");
    if (accountId) clearCache(`/api/users/${accountId}/profile`);
  }

  async function save(event) {
    event.preventDefault();
    setBusy("profile");
    try {
      const updated = await apiFetch("/api/users/me", { method: "POST", body: JSON.stringify(formToPayload(form)) });
      setForm(profileToForm(updated.profile));
      setData((current) => ({ ...(current || {}), ...updated }));
      clearProfileCache();
      ctx.showToast("Profile saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy("");
    }
  }

  async function saveEmail(event) {
    event.preventDefault();
    setBusy("email");
    try {
      const updated = await apiFetch("/api/session/email", { method: "POST", body: JSON.stringify({ email: identity.email }) });
      setData((current) => ({ ...(current || {}), profile: updated.profile || current?.profile }));
      setForm(profileToForm(updated.profile || form));
      clearProfileCache();
      ctx.showToast(updated.email_verification_sent ? "Verification sent." : "Email saved.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy("");
    }
  }

  async function verifyEmail(event) {
    event.preventDefault();
    setBusy("verify");
    try {
      const updated = await apiFetch("/api/session/email/verify", { method: "POST", body: JSON.stringify({ code: identity.code }) });
      setData((current) => ({ ...(current || {}), profile: updated.profile || current?.profile }));
      setForm(profileToForm(updated.profile || form));
      setIdentity((current) => ({ ...current, code: "" }));
      clearProfileCache();
      ctx.showToast("Email verified.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy("");
    }
  }

  async function changePassword(event) {
    event.preventDefault();
    setBusy("password");
    try {
      const updated = await apiFetch("/api/session/password", { method: "POST", body: JSON.stringify({ current_password: identity.current_password, new_password: identity.new_password }) });
      setData((current) => ({ ...(current || {}), profile: updated.profile || current?.profile }));
      setIdentity((current) => ({ ...current, current_password: "", new_password: "" }));
      ctx.showToast("Password changed.", "success");
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy("");
    }
  }

  async function follow() {
    try {
      await apiFetch(`/api/users/${data.profile.id}/follow`, { method: "POST", body: JSON.stringify({ following: !data.profile.followed_by_me }) });
      clearProfileCache();
      await load();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  async function friend() {
    try {
      await apiFetch(`/api/users/${data.profile.id}/friend-request`, { method: "POST" });
      clearProfileCache();
      await load();
    } catch (error) {
      ctx.showToast(error.message, "error");
    }
  }

  if (!data) return <Page title="Profile" eyebrow="Loading"><SkeletonGrid count={2} /></Page>;
  const profile = data.profile || {};
  const editable = Boolean(data.editable && !publicMode);
  const tags = Array.isArray(profile.profile_tags) ? profile.profile_tags : [];
  const links = Array.isArray(profile.profile_links) ? profile.profile_links : [];
  const activity = profile.activity || {};
  const profileClasses = `${profileLayoutClass(ctx.preferences)} public-profile-card-${profile.profile_card_style || "solid"} public-profile-banner-${profile.profile_banner_mode || "gradient"}`;
  const bannerStyle = {
    "--accent": profile.theme_accent || ctx.preferences.accent_color || "#89b4fa",
    "--profile-banner-url": profile.profile_banner_url ? `url("${String(profile.profile_banner_url).replace(/["\\]/g, "\\$&")}")` : "none",
  };

  return (
    <Page
      title={publicMode ? (profile.display_name || profile.username) : "Server Identity"}
      eyebrow={publicMode ? "Public Profile" : "Profile"}
      lede={publicMode ? "Public-facing profile card, live activity, and social links." : "Tune how your guild identity and activity appear across the swarm."}
      className="page-profile"
    >
      <section className={`panel public-profile-hero ${profileClasses}`} style={bannerStyle}>
        <ProfileAvatar profile={profile} />
        <div className="public-profile-copy">
          <h2>{profile.profile_headline || profile.display_name || profile.username}</h2>
          <p>{profile.bio || profile.server_name || `Guild ${profile.guild_id || "profile"}`}</p>
          <div className="chip-row"><PresencePill user={profile} />{tags.map((tag) => <span key={tag}>{tag}</span>)}<span>{profile.favorite_bot || "swarm"}</span><span>{profile.server_name || `Guild ${profile.guild_id || "server"}`}</span></div>
        </div>
        <div className="public-profile-actions">
          {publicMode ? <button type="button" onClick={follow}><Heart size={16} />{profile.followed_by_me ? "Unfollow" : "Follow"}</button> : null}
          {publicMode ? <button type="button" onClick={friend} disabled={["friends", "pending_out", "self"].includes(profile.friend_status)}><UserPlus size={16} />{profile.friend_status === "friends" ? "Friends" : profile.friend_status === "pending_out" ? "Pending" : "Friend"}</button> : null}
          {publicMode ? <Link className="button-link primary" to="/messages" state={{ user: profile }}><MessageCircle size={16} />Message</Link> : null}
          {!publicMode && profile.id ? <Link className="button-link" to={`/users/${profile.id}`}><ExternalLink size={16} />Public View</Link> : null}
        </div>
      </section>

      <section className="profile-dashboard-grid">
        <article className="panel profile-stat-panel"><strong>{profile.follower_count || 0}</strong><span>Followers</span></article>
        <article className="panel profile-stat-panel"><strong>{profile.following_count || 0}</strong><span>Following</span></article>
        <article className="panel profile-stat-panel"><strong>{profile.friend_count || 0}</strong><span>Friends</span></article>
        <article className="panel profile-stat-panel"><strong>{activity.total_plays || 0}</strong><span>Plays</span></article>
      </section>

      <section className="settings-grid profile-social-layout">
        <article className="panel form-panel">
          <div className="section-head"><h2><Music2 size={18} /> Swarm Activity</h2></div>
          <div className="event-list compact-events">
            {(activity.active_sessions || []).slice(0, 4).map((session) => <article className="event" key={`${session.bot_name}-${session.guild_id}`}><strong>{session.title || session.bot_name}</strong><p>{session.bot_name} / {session.channel_name || "voice"}</p></article>)}
            {!(activity.active_sessions || []).length ? <EmptyState title="No live sessions" /> : null}
          </div>
        </article>
        <article className="panel form-panel">
          <div className="section-head"><h2>Links</h2></div>
          <div className="profile-link-list">
            {links.map((link) => <a href={link.url} target="_blank" rel="noreferrer" key={`${link.label}-${link.url}`}><ExternalLink size={15} />{link.label}</a>)}
            {profile.server_invite_url ? <a href={profile.server_invite_url} target="_blank" rel="noreferrer"><ExternalLink size={15} />Discord</a> : null}
            {!links.length && !profile.server_invite_url ? <EmptyState title="No links" /> : null}
          </div>
        </article>
      </section>

      {!publicMode ? (
        <section className={`settings-grid ${profileLayoutClass(ctx.preferences)}`}>
          <form className="panel form-panel profile-editor" onSubmit={save}>
            <div className="profile-preview">
              <ProfileAvatar profile={{ ...profile, ...form }} />
              <div><strong>{form.display_name || data.username}</strong><p className="muted">{form.profile_headline || form.server_name || `Guild ${data.guild_id || data.account_guild_id || "profile"}`}</p></div>
            </div>
            <label className="field"><span>Display Name</span><input value={form.display_name || ""} onChange={(event) => setForm((current) => ({ ...current, display_name: event.target.value }))} disabled={!editable} /></label>
            <label className="field"><span>Headline</span><input value={form.profile_headline || ""} onChange={(event) => setForm((current) => ({ ...current, profile_headline: event.target.value }))} disabled={!editable} /></label>
            <label className="field"><span>Bio</span><textarea value={form.bio || ""} onChange={(event) => setForm((current) => ({ ...current, bio: event.target.value }))} disabled={!editable} /></label>
            <label className="field"><span>Tags</span><input value={form.profile_tags_text || ""} onChange={(event) => setForm((current) => ({ ...current, profile_tags_text: event.target.value }))} disabled={!editable} /></label>
            <div className="link-editor">
              {(form.profile_links || []).slice(0, 5).map((link, index) => (
                <div className="two-col" key={index}>
                  <label className="field"><span>Link Label</span><input value={link.label || ""} onChange={(event) => setForm((current) => ({ ...current, profile_links: (current.profile_links || []).map((item, itemIndex) => itemIndex === index ? { ...item, label: event.target.value } : item) }))} disabled={!editable} /></label>
                  <label className="field"><span>Link URL</span><input value={link.url || ""} onChange={(event) => setForm((current) => ({ ...current, profile_links: (current.profile_links || []).map((item, itemIndex) => itemIndex === index ? { ...item, url: event.target.value } : item) }))} disabled={!editable} /></label>
                </div>
              ))}
            </div>
            <div className="two-col">
              <label className="field"><span>Server Name</span><input value={form.server_name || ""} onChange={(event) => setForm((current) => ({ ...current, server_name: event.target.value }))} disabled={!editable} /></label>
              <label className="field"><span>Favorite Bot</span><select value={form.favorite_bot || ""} onChange={(event) => setForm((current) => ({ ...current, favorite_bot: event.target.value }))} disabled={!editable}><option value="">None</option>{(data.favorite_bot_options || []).map((bot) => <option key={bot.key} value={bot.key}>{bot.display_name}</option>)}</select></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Avatar URL</span><input value={form.avatar_url || ""} onChange={(event) => setForm((current) => ({ ...current, avatar_url: event.target.value }))} disabled={!editable} /></label>
              <label className="field"><span>Server Icon URL</span><input value={form.server_icon_url || ""} onChange={(event) => setForm((current) => ({ ...current, server_icon_url: event.target.value }))} disabled={!editable} /></label>
            </div>
            <div className="two-col">
              <label className="field"><span>Banner URL</span><input value={form.profile_banner_url || ""} onChange={(event) => setForm((current) => ({ ...current, profile_banner_url: event.target.value }))} disabled={!editable} /></label>
              <label className="field color-field"><span>Accent</span><input type="color" value={form.theme_accent || "#89b4fa"} onChange={(event) => setForm((current) => ({ ...current, theme_accent: event.target.value }))} disabled={!editable} /></label>
            </div>
            <div className="three-col">
              <label className="field"><span>Banner</span><select value={form.profile_banner_mode || "gradient"} onChange={(event) => setForm((current) => ({ ...current, profile_banner_mode: event.target.value }))} disabled={!editable}><option value="gradient">Gradient</option><option value="image">Image</option><option value="signal">Signal</option><option value="quiet">Quiet</option><option value="contrast">Contrast</option></select></label>
              <label className="field"><span>Cards</span><select value={form.profile_card_style || "solid"} onChange={(event) => setForm((current) => ({ ...current, profile_card_style: event.target.value }))} disabled={!editable}><option value="solid">Solid</option><option value="glass">Glass</option><option value="outline">Outline</option><option value="terminal">Terminal</option></select></label>
              <label className="field"><span>Social</span><select value={form.profile_social_mode || "open"} onChange={(event) => setForm((current) => ({ ...current, profile_social_mode: event.target.value }))} disabled={!editable}><option value="open">Open</option><option value="friends">Friends</option><option value="quiet">Quiet</option></select></label>
            </div>
            <label className="field"><span>Discord Invite</span><input value={form.server_invite_url || ""} onChange={(event) => setForm((current) => ({ ...current, server_invite_url: event.target.value }))} disabled={!editable} /></label>
            <label className="check-row"><input type="checkbox" checked={form.public_profile !== false} onChange={(event) => setForm((current) => ({ ...current, public_profile: event.target.checked }))} disabled={!editable} />Public profile</label>
            <button className="primary" type="submit" disabled={!editable || busy === "profile"}><Save size={16} />{busy === "profile" ? "Saving" : "Save"}</button>
          </form>
          <div className="panel form-panel">
            <h2><ShieldCheck size={18} /> Account</h2>
            <form className="mini-form" onSubmit={saveEmail}><label className="field"><span>Email</span><input type="email" value={identity.email} onChange={(event) => setIdentity((current) => ({ ...current, email: event.target.value }))} disabled={!editable} /></label><button type="submit" disabled={!editable || busy === "email"}><Mail size={16} />{busy === "email" ? "Saving" : "Save Email"}</button></form>
            <form className="mini-form" onSubmit={verifyEmail}><label className="field"><span>Code</span><input value={identity.code} onChange={(event) => setIdentity((current) => ({ ...current, code: event.target.value }))} disabled={!editable} /></label><button type="submit" disabled={!editable || busy === "verify"}><Check size={16} />{busy === "verify" ? "Checking" : "Verify"}</button></form>
            <form className="mini-form" onSubmit={changePassword}><label className="field"><span>Current</span><input type="password" value={identity.current_password} onChange={(event) => setIdentity((current) => ({ ...current, current_password: event.target.value }))} disabled={!editable} /></label><label className="field"><span>New</span><input type="password" value={identity.new_password} onChange={(event) => setIdentity((current) => ({ ...current, new_password: event.target.value }))} disabled={!editable} /></label><button type="submit" disabled={!editable || busy === "password"}><KeyRound size={16} />{busy === "password" ? "Saving" : "Change"}</button></form>
          </div>
        </section>
      ) : null}
    </Page>
  );
}
