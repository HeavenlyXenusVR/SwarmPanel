-- Community section: Directory (/users), Friends, Messages. Public profile
-- pages (/users/:id) share the profile renderer with /profile and live in
-- pages_account.lua; nav.lua still files them under Directory.
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")
local kit = require("page_kit")
local dashboard = require("dashboard")

local M = {}

function M.register(cfg)
  local music_bots = cfg.music_bots
  local session_view, page_shell, denied = kit.session_view, kit.page_shell, kit.denied

  -- -----------------------------------------------------------------
  -- Users
  -- -----------------------------------------------------------------
  httpd.route("GET", "/users", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    local body = html.page({
      title = "Directory", eyebrow = "Community", lede = "Find other operators in the swarm.",
      body = [[
        <div class="directory-toolbar">
          <div class="search-box search-box-wide">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true"><circle cx="7" cy="7" r="5" stroke="currentColor" stroke-width="1.6"/><path d="M11 11L14.5 14.5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>
            <input type="search" placeholder="Search users..." data-debounced-search id="user-search">
          </div>
          <label class="toggle-chip"><input type="checkbox" id="user-online-only"> Online now</label>
          <div class="directory-summary" id="user-summary"></div>
        </div>
        <div id="user-results" class="user-grid">]] .. html.skeleton_grid(6) .. [[</div>
      ]],
    })
    local script = [[
      function escUser(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
      function userInitials(label) {
        const parts = String(label || "").trim().split(/\s+/).filter(Boolean);
        if (!parts.length) return "SP";
        return (parts[0][0] + (parts[1] ? parts[1][0] : "")).toUpperCase();
      }
      function titleCaseUser(s) { return String(s || "").replace(/[_-]+/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()); }
      // Full port of UserCard from components/swarm.jsx -- the first pass
      // only rendered the display name and three bare buttons, so avatars,
      // handles, guild/favorite-bot chips, and follower/friend counts (all
      // already returned by /api/users/directory) never showed up anywhere
      // in the directory.
      // Each search bumps this; a slower, older response that lands after a
      // newer one is dropped instead of overwriting the newer results.
      let userSearchSeq = 0;
      async function renderUsers(q) {
        const seq = ++userSearchSeq;
        try {
          const onlineOnly = document.getElementById("user-online-only").checked;
          const res = await swarmFetch("/api/users/directory?q=" + encodeURIComponent(q || "") + (onlineOnly ? "&online=1" : ""));
          if (seq !== userSearchSeq) return;
          const cards = (res.users || []).map((u) => {
            const imageUrl = u.avatar_url || u.server_icon_url || "";
            const displayName = u.display_name || u.username || "Unknown operator";
            const guildLabel = u.server_name || u.profile_headline || (u.guild_id ? `Guild ${u.guild_id}` : "Swarm directory");
            const favoriteBot = u.favorite_bot ? titleCaseUser(u.favorite_bot) : "No favorite";
            const avatarImg = imageUrl ? `<img class="avatar-image" src="${escUser(imageUrl)}" alt="" loading="lazy" decoding="async" width="64" height="64">` : `<span class="avatar-fallback">${escUser(userInitials(displayName))}</span>`;
            const friendLocked = ["friends", "pending_out", "self"].includes(u.friend_status);
            const friendLabel = u.friend_status === "friends" ? "Friends" : u.friend_status === "pending_out" ? "Pending" : "Friend";
            return `
            <article class="user-card">
              <div class="user-card-main">
                <a class="avatar-link" href="/users/${u.id}">
                  <div class="avatar avatar-lg avatar-presence">${avatarImg}<span class="presence-dot avatar-dot ${u.is_online ? "online" : "inactive"}" aria-hidden="true"></span></div>
                </a>
                <div class="user-card-copy">
                  <div class="user-card-head">
                    <a href="/users/${u.id}"><h3>${escUser(displayName)}</h3></a>
                    <span class="presence-pill compact ${u.is_online ? "online" : "inactive"}"><span class="presence-dot" aria-hidden="true"></span>${u.is_online ? "Online" : "Inactive"}</span>
                  </div>
                  <p class="user-card-handle">@${escUser(u.username || "operator")}</p>
                  <p class="user-card-guild">${escUser(guildLabel)}</p>
                  <div class="chip-row user-card-tags">
                    <span>${escUser(favoriteBot)}</span>
                    ${u.server_name ? `<span>${escUser(u.server_name)}</span>` : ""}
                  </div>
                </div>
              </div>
              <div class="user-card-stats">
                <article><strong>${u.follower_count || 0}</strong><span>Followers</span></article>
                <article><strong>${u.friend_count || 0}</strong><span>Friends</span></article>
                <article><strong>${escUser(favoriteBot)}</strong><span>Favorite Bot</span></article>
              </div>
              <div class="inline-controls user-card-actions">
                <a class="button-link" href="/users/${u.id}">Open</a>
                <button type="button" data-follow="${u.id}" data-following="${u.followed_by_me ? "1" : ""}">${u.followed_by_me ? "Unfollow" : "Follow"}</button>
                <button type="button" data-friend="${u.id}" ${friendLocked ? "disabled" : ""}>${escUser(friendLabel)}</button>
                <a class="button-link" href="/messages?to=${encodeURIComponent(u.id)}">Message</a>
              </div>
            </article>`;
          }).join("");
          document.getElementById("user-results").innerHTML = cards || (onlineOnly ? "<p>Nobody matching is online right now.</p>" : "<p>No users found.</p>");
          const users = res.users || [];
          const onlineCount = users.filter((u) => u.is_online).length;
          document.getElementById("user-summary").innerHTML = users.length
            ? `<span>${users.length} shown</span><span>${onlineCount} online</span>`
            : "";
        } catch (err) { if (seq === userSearchSeq) swarmToast("Search failed.", "error"); }
      }
      document.getElementById("user-search").addEventListener("swarm:search", (e) => renderUsers(e.detail.query));
      document.getElementById("user-online-only").addEventListener("change", () => renderUsers(document.getElementById("user-search").value));
      renderUsers("");
      document.getElementById("user-results").addEventListener("click", async (e) => {
        const btn = e.target.closest("button");
        if (!btn || btn.disabled) return;
        const followId = btn.getAttribute("data-follow");
        const friendId = btn.getAttribute("data-friend");
        if (!followId && !friendId) return;
        btn.disabled = true;
        try {
          if (followId) {
            const wasFollowing = btn.getAttribute("data-following") === "1";
            await swarmFetch(`/api/users/${followId}/follow`, { method: "POST", body: JSON.stringify({ following: !wasFollowing }) });
            renderUsers(document.getElementById("user-search").value);
          }
          if (friendId) await swarmFetch(`/api/users/${friendId}/friend-request`, { method: "POST" });
          if (friendId) { btn.textContent = "Pending"; } else { btn.disabled = false; }
          swarmToast("Done.", "success");
        } catch (err) { btn.disabled = false; swarmToast(err.message, "error"); }
      });
    ]]
    return page_shell(req, a, "/users", "Directory", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Friends
  -- -----------------------------------------------------------------
  httpd.route("GET", "/friends", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    -- BUGFIX: the bare env-configured admin login (settings.admin_username/
    -- admin_password -- see /api/login's `auth_result = { ... guild_id =
    -- nil, site_owner = true, admin_mode = true ... }`) has no `users` table
    -- row at all, so account_id_for_auth() in routes.lua can NEVER resolve
    -- an account_id for it -- every /api/friends/* and /api/me/friends call
    -- 403s with "Guild account access required", every single time,
    -- forever, for this account type. The page used to render the full
    -- interactive friends UI regardless and let the client-side fetch fail,
    -- surfacing as a generic "Failed to load friends." toast -- repeating
    -- every 5s via swarmLiveRefresh, since nothing ever stopped retrying.
    -- Friends/social features are inherently per-guild-account (see
    -- social.lua/accounts.lua's users-table-keyed model); the site-admin
    -- login genuinely has no social identity to attach them to. Detect that
    -- up front and show a clear explanation instead of a page that's
    -- guaranteed to error forever.
    if not a.guild_id then
      local body = html.page({
        title = "Friends", eyebrow = "Community", lede = "Requests and confirmed friends.",
        body = [[
          <div class="empty-state">
            <p>Friends and social features are tied to a guild account, not the site admin login.</p>
            <p>Log in with a guild account (one registered to a specific bot/guild) to use Friends.</p>
          </div>
        ]],
      })
      return page_shell(req, a, "/friends", "Friends", body, "")
    end
    local body = html.page({
      title = "Friends", eyebrow = "Community", lede = "Requests and confirmed friends.",
      body = [[
        <div class="friends-columns">
          <div><h3>Incoming</h3><div id="friends-incoming"></div></div>
          <div><h3>Outgoing</h3><div id="friends-outgoing"></div></div>
          <div><h3>Friends</h3><div id="friends-list"></div></div>
        </div>
      ]],
    })
    local script = [[
      // BUGFIX (live-push migration): was swarmFetch (2 calls) on a 5s
      // swarmLiveRefresh poll. applyFriends() renders from the "friends"
      // live-push (routes.lua's SNAPSHOT_BUILDERS.friends bundles
      // friends+incoming+outgoing in one push, matching what this page
      // always fetched together anyway) -- accepting/declining/canceling a
      // request still does a direct fetch first for instant feedback on the
      // user's OWN action, same pattern as Controls' queues.
      function applyFriends(data) {
        const incoming = ((data && data.incoming) || []).map((r) =>
          `<div class="friend-row">${(r.username||"").replace(/</g,"&lt;")} <button data-accept="${r.id}">Accept</button> <button data-decline="${r.id}">Decline</button></div>`).join("");
        const outgoing = ((data && data.outgoing) || []).map((r) =>
          `<div class="friend-row">${(r.username||"").replace(/</g,"&lt;")} <button data-cancel="${r.id}">Cancel</button></div>`).join("");
        document.getElementById("friends-incoming").innerHTML = incoming || "<p>None.</p>";
        document.getElementById("friends-outgoing").innerHTML = outgoing || "<p>None.</p>";
        document.getElementById("friends-list").innerHTML =
          ((data && data.friends) || []).map((f) => `<div class="friend-row">${(f.username||"").replace(/</g,"&lt;")}</div>`).join("") || "<p>No friends yet.</p>";
      }
      window.swarmLive.watch("friends", (msg) => {
        if (msg.type === "snapshot") applyFriends(msg.data);
        else swarmToast("Failed to load friends.", "error");
      });
      document.body.addEventListener("click", async (e) => {
        const id = e.target.getAttribute("data-accept") || e.target.getAttribute("data-decline") || e.target.getAttribute("data-cancel");
        if (!id) return;
        const action = e.target.hasAttribute("data-accept") ? "accept" : e.target.hasAttribute("data-decline") ? "decline" : "cancel";
        try {
          await swarmFetch(`/api/friends/requests/${id}`, { method: "POST", body: JSON.stringify({ action }) });
          const [reqs, friends] = await Promise.all([swarmFetch("/api/friends/requests"), swarmFetch("/api/me/friends")]);
          applyFriends({ incoming: reqs.incoming, outgoing: reqs.outgoing, friends: friends.friends });
        } catch (err) { swarmToast(err.message, "error"); }
      });
    ]]
    return page_shell(req, a, "/friends", "Friends", body, script)
  end)

  -- -----------------------------------------------------------------
  -- Messages
  -- -----------------------------------------------------------------
  httpd.route("GET", "/messages", function(req)
    local a, status, headers = cfg.require_auth_page(req)
    if not a then return status, "", headers end
    -- BUGFIX: same class of bug as /friends (see that route's comment) --
    -- messages are guild-account-scoped (account_id_for_auth in routes.lua
    -- requires a.guild_id), so the bare env-configured admin login can
    -- never load a thread list/search here either. Same fix: a clear
    -- explanation instead of a page that's guaranteed to error forever.
    if not a.guild_id then
      local body = html.page({
        title = "Messages", eyebrow = "Community", lede = "Direct messages with other operators.",
        body = [[
          <div class="empty-state">
            <p>Messages are tied to a guild account, not the site admin login.</p>
            <p>Log in with a guild account (one registered to a specific bot/guild) to use Messages.</p>
          </div>
        ]],
      })
      return page_shell(req, a, "/messages", "Messages", body, "")
    end
    local body = html.page({
      title = "Messages", eyebrow = "Community", lede = "Direct messages with other operators.",
      body = [[
        <div class="messages-layout">
          <div class="messages-threads">
            <input type="search" placeholder="Find someone..." data-debounced-search id="msg-search">
            <div id="msg-search-results"></div>
            <div id="msg-threads"></div>
          </div>
          <div class="messages-conversation" id="msg-conversation">
            <p class="empty-state">Select a conversation.</p>
          </div>
        </div>
      ]],
    })
    local script = [[
      // Threads list watches "threads" (fixed, no params). The open
      // conversation is per-connection state: "thread_messages" takes the
      // other account's id as a watch param and is only watched once a
      // thread is actually open -- watching it with no params (as before)
      // made the server build and push an "account_id is required" error
      // every two seconds for every idle Messages tab.
      let activeThread = null;
      let threadsMarkup = null;
      let messagesMarkup = null;
      let sending = false;
      function escMsg(s) { return swarmEsc(s == null ? "" : s); }
      function msgTime(raw) {
        if (!raw) return "";
        let iso = String(raw);
        if (iso.indexOf("T") === -1) iso = iso.replace(" ", "T");
        if (!/(?:Z|[+-]\d\d(?::?\d\d)?)$/.test(iso)) iso += "Z";
        const d = new Date(iso);
        if (Number.isNaN(d.getTime())) return "";
        const sameDay = d.toDateString() === new Date().toDateString();
        return sameDay ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
          : d.toLocaleDateString([], { month: "short", day: "numeric" });
      }
      function applyThreads(data) {
        const markup = ((data && data.threads) || []).map((t) => {
          const unread = Number(t.unread_count || 0);
          const name = t.display_name || t.username || "Unknown";
          return `<button type="button" class="thread-item${String(t.account_id) === String(activeThread) ? " active" : ""}" data-thread="${escMsg(t.account_id)}">
              <span class="presence-dot ${t.is_online ? "online" : "inactive"}" aria-hidden="true"></span>
              <span class="thread-item-name">${escMsg(name)}</span>
              ${unread ? `<span class="nav-badge" aria-label="${unread} unread">${unread > 99 ? "99+" : unread}</span>` : ""}
            </button>`;
        }).join("") || "<p>No conversations yet.</p>";
        if (markup === threadsMarkup) return;
        threadsMarkup = markup;
        document.getElementById("msg-threads").innerHTML = markup;
      }
      window.swarmLive.watch("threads", (msg) => { if (msg.type === "snapshot") applyThreads(msg.data); });

      function applyMessages(data, forThread) {
        if (forThread !== undefined && String(forThread) !== String(activeThread)) return;
        const list = document.getElementById("msg-list");
        if (!list) return;
        const markup = ((data && data.messages) || []).map((m) =>
          `<div class="msg-bubble ${m.mine ? "mine" : ""}">${escMsg(m.body)}<small class="msg-time">${escMsg(msgTime(m.created_at))}</small></div>`).join("")
          || '<p class="empty-state">No messages yet. Say hello.</p>';
        if (markup === messagesMarkup) return;
        // Stay pinned to the newest message if the reader was already at
        // the bottom; leave their scroll position alone if they scrolled
        // up to read history (a re-render used to snap it back to the top).
        const atBottom = messagesMarkup === null || list.scrollHeight - list.scrollTop - list.clientHeight < 48;
        messagesMarkup = markup;
        list.innerHTML = markup;
        if (atBottom) list.scrollTop = list.scrollHeight;
      }
      function onThreadMessages(msg) {
        if (msg.type === "snapshot") applyMessages(msg.data);
      }

      async function openThread(id) {
        if (!id) return;
        activeThread = id;
        messagesMarkup = null;
        threadsMarkup = null;
        document.querySelectorAll("#msg-threads .thread-item").forEach((el) =>
          el.classList.toggle("active", el.getAttribute("data-thread") === String(id)));
        const box = document.getElementById("msg-conversation");
        box.innerHTML = '<div id="msg-list" class="msg-list"><p class="empty-state">Loading…</p></div><form id="msg-form"><input name="body" placeholder="Message..." maxlength="2000" autocomplete="off" required><button type="submit">Send</button></form>';
        window.swarmLive.watch("thread_messages", { account_id: id }, onThreadMessages);
        try { applyMessages(await swarmFetch(`/api/messages/${encodeURIComponent(id)}`), id); }
        catch (err) {
          if (String(id) === String(activeThread)) document.getElementById("msg-list").innerHTML = '<div class="notice notice-error">' + escMsg(err.message) + "</div>";
        }
        const form = document.getElementById("msg-form");
        form.body.focus();
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          const input = form.body;
          const text = input.value.trim();
          if (!text || sending) return;
          const target = activeThread;
          sending = true;
          form.querySelector("button").disabled = true;
          try {
            await swarmFetch(`/api/messages/${encodeURIComponent(target)}`, { method: "POST", body: JSON.stringify({ body: text }) });
            input.value = "";
            // Force the next render to scroll to the message just sent.
            messagesMarkup = null;
            applyMessages(await swarmFetch(`/api/messages/${encodeURIComponent(target)}`), target);
          } catch (err) { swarmToast(err.message, "error"); }
          finally {
            sending = false;
            form.querySelector("button").disabled = false;
            input.focus();
          }
        });
      }
      function threadClick(e) {
        const btn = e.target.closest("[data-thread]");
        if (btn) openThread(btn.getAttribute("data-thread"));
      }
      document.getElementById("msg-threads").addEventListener("click", threadClick);
      let msgSearchSeq = 0;
      document.getElementById("msg-search").addEventListener("swarm:search", async (e) => {
        const q = e.detail.query;
        const seq = ++msgSearchSeq;
        if (!q) { document.getElementById("msg-search-results").innerHTML = ""; return; }
        try {
          const res = await swarmFetch("/api/users/directory?q=" + encodeURIComponent(q));
          if (seq !== msgSearchSeq) return;
          document.getElementById("msg-search-results").innerHTML = (res.users || []).map((u) =>
            `<button type="button" class="thread-item" data-thread="${escMsg(u.id)}"><span class="presence-dot ${u.is_online ? "online" : "inactive"}" aria-hidden="true"></span><span class="thread-item-name">${escMsg(u.display_name || u.username)}</span></button>`).join("");
        } catch { /* ignore */ }
      });
      document.getElementById("msg-search-results").addEventListener("click", threadClick);
      // Deep link: /messages?to=<account id> opens that conversation.
      const initialThread = new URLSearchParams(window.location.search).get("to");
      if (initialThread) openThread(initialThread);
    ]]
    return page_shell(req, a, "/messages", "Messages", body, script)
  end)
end

return M
