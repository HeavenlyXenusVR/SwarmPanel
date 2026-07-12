export function safeHex(value, fallback) {
  return /^#[0-9a-f]{6}$/i.test(value || "") ? value : fallback;
}
export function pick(row, keys) {
  return Object.fromEntries(keys.map((key) => [key, row?.[key]]).filter(([, value]) => value !== undefined));
}
export function unique(values) {
  return Array.from(new Set(values));
}
export function uniqueBy(rows, key) {
  const seen = new Set();
  return rows.filter((row) => {
    const value = String(row?.[key] || "");
    if (!value || seen.has(value)) return false;
    seen.add(value);
    return true;
  });
}
export function formatCell(value) {
  if (value === null || value === undefined) return "";
  if (typeof value === "boolean") return value ? "yes" : "no";
  if (typeof value === "object") return JSON.stringify(value).slice(0, 220);
  return String(value);
}
export function number(value) {
  return new Intl.NumberFormat().format(Number(value || 0));
}
export function initials(value) {
  return String(value || "SP").trim().split(/\s+/).slice(0, 2).map((part) => part[0]).join("").toUpperCase() || "SP";
}
export function titleCase(value) {
  return String(value || "").replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}
export function formatTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

export function formatRelativeTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  const diffMs = Date.now() - date.getTime();
  const diffSeconds = Math.round(diffMs / 1000);
  const abs = Math.abs(diffSeconds);
  if (abs < 5) return "just now";
  const units = [
    ["year", 31536000],
    ["month", 2592000],
    ["week", 604800],
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
    ["second", 1],
  ];
  for (const [unit, seconds] of units) {
    if (abs >= seconds || unit === "second") {
      const value = Math.round(abs / seconds);
      const suffix = diffSeconds >= 0 ? "ago" : "from now";
      return `${value} ${unit}${value === 1 ? "" : "s"} ${suffix}`;
    }
  }
  return date.toLocaleString();
}

export function formatDurationSeconds(value) {
  const totalSeconds = Math.max(0, Math.floor(Number(value) || 0));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}
