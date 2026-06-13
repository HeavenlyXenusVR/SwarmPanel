import { useCallback, useEffect, useState } from "react";
import { Bug, ListMusic, Music, RefreshCw, Radio, Upload, Users } from "lucide-react";
import { apiFetch } from "../api.js";
import { useLiveRefresh } from "../hooks/useLiveRefresh.js";
import { DataTable } from "../components/swarm.jsx";
import { Metric, MetricGrid, Page, SectionHead } from "../components/ui.jsx";

function formatBytes(bytes) {
  const value = Number(bytes) || 0;
  if (value <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  const exponent = Math.min(units.length - 1, Math.floor(Math.log(value) / Math.log(1024)));
  return `${(value / 1024 ** exponent).toFixed(exponent ? 1 : 0)} ${units[exponent]}`;
}

export default function LumisoundAdminPage({ ctx }) {
  const [data, setData] = useState(null);
  const showToast = ctx.showToast;
  const load = useCallback(async ({ background = false, force = false } = {}) => {
    try {
      const result = await apiFetch("/api/lumisound/admin", { force });
      setData(result.data);
    } catch (error) {
      if (!background) showToast(error.message, "error");
    }
  }, [showToast]);
  useEffect(() => { load(); }, [load]);
  useLiveRefresh(() => load({ background: true, force: true }), { interval: 15_000 });

  const summary = data?.summary || {};
  const users = data?.users || [];
  const uploads = (data?.uploads || []).map((row) => ({ ...row, file_size: formatBytes(row.file_size_bytes) }));
  const bugReports = data?.bug_reports || [];
  const listenRooms = data?.listen_rooms || [];

  return (
    <Page
      title="Lumisound"
      eyebrow="Admin Workspace"
      lede="Account, library, and activity data for the Lumisound iOS app."
      actions={<button type="button" onClick={() => load({ force: true })}><RefreshCw size={16} />Refresh</button>}
    >
      <MetricGrid>
        <Metric icon={Users} label="Users" value={summary.users ?? users.length} />
        <Metric icon={Users} label="Active Users" value={summary.active_users ?? 0} />
        <Metric icon={Upload} label="Uploads" value={summary.uploads ?? uploads.length} />
        <Metric icon={ListMusic} label="Playlists" value={summary.playlists ?? 0} />
        <Metric icon={Music} label="Plays Logged" value={summary.play_history ?? 0} />
        <Metric icon={Bug} label="Open Bug Reports" value={summary.bug_reports_open ?? bugReports.length} />
        <Metric icon={Radio} label="Active Listen Rooms" value={summary.listen_rooms_active ?? listenRooms.length} />
      </MetricGrid>
      <section className="dashboard-grid">
        <div className="panel wide">
          <SectionHead title="Users" count={users.length} />
          <DataTable rows={users} />
        </div>
        <div className="panel wide">
          <SectionHead title="Recent Uploads" count={uploads.length} />
          <DataTable rows={uploads} />
        </div>
        <div className="panel">
          <SectionHead title="Bug Reports" count={bugReports.length} />
          <DataTable rows={bugReports} />
        </div>
        <div className="panel">
          <SectionHead title="Active Listen Rooms" count={listenRooms.length} />
          <DataTable rows={listenRooms} />
        </div>
      </section>
    </Page>
  );
}
