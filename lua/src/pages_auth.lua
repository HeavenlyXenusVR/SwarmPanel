-- Server-rendered public screens: sign in / register and sign out. Every
-- other page module assumes an authenticated session; this is the only one
-- reachable without one.
local httpd = require("httpd")
local html = require("html")
local accounts = require("accounts")
local kit = require("page_kit")
local auth = require("auth")
local ratelimit = require("ratelimit")
local config = require("config")

local M = {}

function M.register(cfg)
  local settings = cfg.settings
  local get_auth = cfg.get_auth
  local session_cookie_header = cfg.session_cookie_header
  local clear_session_cookie_header = cfg.clear_session_cookie_header
  local session_view, page_shell, denied = kit.session_view, kit.page_shell, kit.denied

  -- ---------------------------------------------------------------------
  -- Login (public) -- mirrors pages/AuthPage.jsx
  -- ---------------------------------------------------------------------
  httpd.route("GET", "/login", function(req)
    local a = get_auth(req)
    if a then return 303, "", { Location = "/" } end
    local next_path = req.query["next"]
    -- Mirrors AuthPage.jsx: a login/register mode toggle on one form. The
    -- register fields (guild_id/email/verification_webhook_url) were
    -- entirely missing from the first Lua-rendered pass -- POST
    -- /api/session/register already existed and worked server-side the
    -- whole time, there was just no page that could reach it, so new
    -- guild accounts had no way to sign up at all.
    local body = ([[
      <form id="auth-form" class="auth-card form-panel">
        <h1>SwarmPanel</h1>
        <span class="page-lede" id="auth-lede">Sign in to reach fleet command.</span>
        <div class="segmented" role="tablist">
          <button type="button" class="active" data-auth-mode="login">Login</button>
          <button type="button" data-auth-mode="register">Register</button>
        </div>
        <div id="auth-error" class="notice notice-error" hidden></div>
        <label class="field"><span>Username</span><input type="text" name="username" autocomplete="username" required></label>
        <label class="field"><span>Password</span><input type="password" name="password" autocomplete="current-password"></label>
        <div data-auth-register hidden>
          <label class="field"><span>Guild ID</span><input type="text" name="guild_id"></label>
          <label class="field"><span>Email (optional)</span><input type="email" name="email"></label>
          <div class="segmented" role="tablist">
            <button type="button" class="active" data-auth-proof-mode="webhook">Server Webhook</button>
            <button type="button" data-auth-proof-mode="discord">Discord DM</button>
          </div>
          <div data-auth-proof-webhook>
            <label class="field"><span>Discord Verification Webhook</span><input type="text" name="verification_webhook_url" placeholder="https://discord.com/api/webhooks/..."></label>
            <div class="auth-proof-guide">
              <div class="auth-proof-head">
                <div><strong>How webhook proof works</strong>
                <p>SwarmPanel verifies that the webhook URL belongs to the same Discord server as the guild ID you entered, then sends your real verification code there.</p></div>
              </div>
              <div class="auth-proof-steps">
                <article><span>1</span><div><strong>Open your Discord server settings</strong><p>Go to the server you want to register, then open a text channel you manage.</p></div></article>
                <article><span>2</span><div><strong>Create a temporary webhook</strong><p>Channel Settings &rarr; Integrations &rarr; Webhooks &rarr; New Webhook. Copy the URL.</p></div></article>
                <article><span>3</span><div><strong>Paste the URL here and register</strong><p>Remove the webhook after you finish verification.</p></div></article>
              </div>
              <div class="auth-proof-footnote">
                <span>This prevents someone else from claiming your guild by typing its ID first.</span>
                <span>The webhook only needs to stay active until the verification code is confirmed.</span>
              </div>
            </div>
          </div>
          <div data-auth-proof-discord hidden>
            <label class="field"><span>Your Discord User ID</span><input type="text" name="discord_user_id" placeholder="1234567890123456"></label>
            <div class="auth-proof-guide">
              <div class="auth-proof-head">
                <div><strong>How Discord DM proof works</strong>
                <p>SwarmPanel's verification bot sends a real code straight to your Discord DMs. Enter it after registering to finish verifying.</p></div>
              </div>
              <div class="auth-proof-steps">
                <article><span>1</span><div><strong>Enable Developer Mode</strong><p>Discord Settings &rarr; Advanced &rarr; Developer Mode.</p></div></article>
                <article><span>2</span><div><strong>Copy your User ID</strong><p>Right-click your own name or avatar anywhere in Discord &rarr; Copy User ID.</p></div></article>
                <article><span>3</span><div><strong>Share a server with the bot first</strong><p>Bots can only DM accounts that share a server with them and allow DMs from server members.</p></div></article>
              </div>
            </div>
          </div>
        </div>
        <input type="hidden" name="next" value="%s">
        <button type="submit" class="primary liquid-glass" id="auth-submit">Login</button>
      </form>
      <script>
        const authForm = document.getElementById("auth-form");
        const authLede = document.getElementById("auth-lede");
        const authSubmit = document.getElementById("auth-submit");
        const registerFields = document.querySelector("[data-auth-register]");
        const proofWebhookBox = document.querySelector("[data-auth-proof-webhook]");
        const proofDiscordBox = document.querySelector("[data-auth-proof-discord]");
        let authMode = "login";
        let proofMode = "webhook";
        function applyProofMode() {
          proofWebhookBox.hidden = proofMode !== "webhook";
          proofDiscordBox.hidden = proofMode !== "discord";
          authForm.verification_webhook_url.required = authMode === "register" && proofMode === "webhook";
          authForm.discord_user_id.required = authMode === "register" && proofMode === "discord";
          authLede.textContent = authMode === "login"
            ? "Sign in to reach fleet command."
            : proofMode === "webhook"
              ? "Register your guild identity with a Discord webhook that proves guild ownership and receives your verification code."
              : "Register your guild identity, then verify straight from Discord DMs -- no webhook needed.";
        }
        document.querySelectorAll("[data-auth-proof-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            proofMode = btn.getAttribute("data-auth-proof-mode");
            document.querySelectorAll("[data-auth-proof-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            applyProofMode();
          });
        });
        document.querySelectorAll("[data-auth-mode]").forEach((btn) => {
          btn.addEventListener("click", () => {
            authMode = btn.getAttribute("data-auth-mode");
            document.querySelectorAll("[data-auth-mode]").forEach((b) => b.classList.toggle("active", b === btn));
            registerFields.hidden = authMode !== "register";
            authForm.password.required = authMode === "login";
            authForm.guild_id.required = authMode === "register";
            applyProofMode();
            authSubmit.textContent = authMode === "login" ? "Login" : "Create Account";
          });
        });
        authForm.addEventListener("submit", async (e) => {
          e.preventDefault();
          const errBox = document.getElementById("auth-error");
          errBox.hidden = true;
          const fd = new FormData(authForm);
          const endpoint = authMode === "login" ? "/api/session/login" : "/api/session/register";
          const payload = Object.fromEntries(fd);
          try {
            const res = await fetch(endpoint, {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify(payload),
            });
            const data = await res.json();
            if (!res.ok) throw new Error(data.detail || (authMode === "login" ? "Login failed" : "Registration failed"));
            window.location = fd.get("next") || "/";
          } catch (err) {
            errBox.textContent = err.message || "Something went wrong";
            errBox.hidden = false;
          }
        });
      </script>
    ]]):format(html.esc(next_path or ""))
    return 200, html.layout({ title = "Login", path = "/login", session = { authenticated = false }, body = body }),
      { ["Content-Type"] = "text/html; charset=utf-8" }
  end)

  httpd.route("POST", "/logout", function(req)
    return 303, "", { Location = "/login", ["Set-Cookie"] = clear_session_cookie_header() }
  end)
end

return M
