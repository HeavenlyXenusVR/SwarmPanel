import { useState } from "react";
import { CheckCircle2, LogIn, ShieldCheck, Webhook } from "lucide-react";
import { apiFetch } from "../api.js";
import { Page, Segmented } from "../components/ui.jsx";

export default function AuthPage({ ctx }) {
  const [mode, setMode] = useState("login");
  const [form, setForm] = useState({ username: "", password: "", guild_id: "", email: "", registration_proof_url: "" });
  const [busy, setBusy] = useState(false);
  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    try {
      const endpoint = mode === "login" ? "/api/session/login" : "/api/session/register";
      const data = await apiFetch(endpoint, { method: "POST", body: JSON.stringify(form), token: "" });
      ctx.loginWith(data);
    } catch (error) {
      ctx.showToast(error.message, "error");
    } finally {
      setBusy(false);
    }
  }
  return (
    <Page title={mode === "login" ? "Login" : "Register"} eyebrow="Session" lede={mode === "login" ? "Sign back into the panel." : "Register your guild identity with proof that you control the target Discord server."}>
      <form className="auth-card form-panel" onSubmit={submit}>
        <Segmented value={mode} onChange={setMode} options={[["login", "Login"], ["register", "Register"]]} />
        <label className="field"><span>Username</span><input value={form.username} onChange={(event) => setForm((current) => ({ ...current, username: event.target.value }))} required /></label>
        <label className="field"><span>Password</span><input type="password" value={form.password} onChange={(event) => setForm((current) => ({ ...current, password: event.target.value }))} /></label>
        {mode === "register" ? <label className="field"><span>Guild ID</span><input value={form.guild_id} onChange={(event) => setForm((current) => ({ ...current, guild_id: event.target.value }))} required /></label> : null}
        {mode === "register" ? <label className="field"><span>Email</span><input type="email" value={form.email} onChange={(event) => setForm((current) => ({ ...current, email: event.target.value }))} /></label> : null}
        {mode === "register" ? <label className="field"><span>Discord Webhook Proof</span><input value={form.registration_proof_url} onChange={(event) => setForm((current) => ({ ...current, registration_proof_url: event.target.value }))} placeholder="https://discord.com/api/webhooks/..." required /></label> : null}
        {mode === "register" ? (
          <div className="auth-proof-guide">
            <div className="auth-proof-head">
              <Webhook size={18} />
              <div>
                <strong>How webhook proof works</strong>
                <p>SwarmPanel verifies that the webhook URL belongs to the same Discord server as the guild ID you entered. The webhook can be deleted after signup.</p>
              </div>
            </div>
            <div className="auth-proof-steps">
              <article>
                <span>1</span>
                <div>
                  <strong>Open your Discord server settings</strong>
                  <p>Go to the server you want to register, then open a text channel you manage.</p>
                </div>
              </article>
              <article>
                <span>2</span>
                <div>
                  <strong>Create a temporary webhook</strong>
                  <p>Open Channel Settings, then Integrations, then Webhooks, then New Webhook. Copy the webhook URL when it appears.</p>
                </div>
              </article>
              <article>
                <span>3</span>
                <div>
                  <strong>Paste the URL here and register</strong>
                  <p>SwarmPanel checks the webhook’s guild binding. Once registration succeeds, you can remove the webhook from Discord.</p>
                </div>
              </article>
            </div>
            <div className="auth-proof-footnote">
              <span><ShieldCheck size={15} /> This prevents someone else from claiming your guild by typing its ID first.</span>
              <span><CheckCircle2 size={15} /> The webhook message channel does not need to stay active after verification.</span>
            </div>
          </div>
        ) : null}
        <button className="primary" type="submit" disabled={busy}><LogIn size={16} />{busy ? "Working" : mode === "login" ? "Login" : "Create Account"}</button>
      </form>
    </Page>
  );
}
