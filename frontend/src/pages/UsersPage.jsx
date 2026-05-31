import { useCallback, useEffect, useState } from "react";
import { Search } from "lucide-react";
import { cachedFetch, query } from "../api.js";
import { UserCard } from "../components/swarm.jsx";
import { EmptyState, LoadingSection, Page } from "../components/ui.jsx";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { directoryLayoutClass } from "../utils/control.js";

export default function UsersPage({ ctx }) {
  const [q, setQ] = useState("");
  const [users, setUsers] = useState([]);
  const [loading, setLoading] = useState(true);

  const showToast = ctx.showToast;
  const loadUsers = useCallback(async ({ background = false, force = false } = {}) => {
    if (!background) setLoading(true);
    try {
      const data = await cachedFetch(`/api/users/directory${query({ q })}`, {
        ttl: force ? 0 : (background ? 4_000 : 8_000),
        staleTtl: background ? 8_000 : 20_000,
        force,
      });
      setUsers(data.users || []);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    } finally {
      if (!background) setLoading(false);
    }
  }, [showToast, q]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      loadUsers();
    }, 220);
    return () => window.clearTimeout(timer);
  }, [loadUsers]);
  useLiveRefresh(() => loadUsers({ background: true, force: true }), { interval: 5_000 });
  return (
    <Page
      title="Swarm Directory"
      eyebrow="Users"
      lede="Browse public identities, guild presence, favorite bots, and social links across the swarm."
      className="page-users"
    >
      <div className="directory-toolbar">
        <div className="search-box search-box-wide"><Search size={16} /><input value={q} onChange={(event) => setQ(event.target.value)} placeholder="Search users, servers, favorite bots" /></div>
        <div className="directory-summary">
          <span>{users.length} visible</span>
          <span>{q ? "filtered" : "all public"}</span>
        </div>
      </div>
      <LoadingSection
        loading={loading}
        title="Scanning swarm directory"
        tip="Public identities, guild presence, and profile cards are loading into the roster."
        count={4}
        minHeight={320}
      >
        <div className={`user-grid directory-grid ${directoryLayoutClass(ctx.preferences)}`}>{users.map((user) => <UserCard user={user} ctx={ctx} onChanged={() => loadUsers({ force: true })} key={`${user.username}-${user.guild_id}`} />)}</div>
        {!loading && !users.length ? <EmptyState title="No users found" /> : null}
      </LoadingSection>
    </Page>
  );
}
