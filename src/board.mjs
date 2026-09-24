// Board ordering: the default headroom sort plus click-to-sort by column.
// Shared with the browser (served as /board.mjs) so the page and the tests use
// identical code. The macOS app mirrors this in macos/App/BoardSort.swift.
//
// Pure functions over the /api/usage `accounts` array. No I/O.
import { tierWeight } from './fleet.mjs';

// The binding usage of an account for the headroom sort: session or weekly.
export function worstPct(a) {
  if (!a.usage) return 0;
  return Math.max(a.usage.session?.pct ?? 0, a.usage.weekly?.pct ?? 0);
}

// Tiered by constraint: at-limit (>=90), then needs-relogin, then warnings,
// then by usage, idle. Sorted ascending: most available on top, most
// constrained at the bottom.
export function headroomKey(a, { warnPct = 70, critPct = 90 } = {}) {
  const worst = worstPct(a);
  let tier = 0;
  if (a.usage && worst >= critPct) tier = 3;
  else if (a.error === 'needs_relogin') tier = 2;
  else if (a.usage && worst >= warnPct) tier = 1;
  return tier * 1000 + worst;
}

// Sortable columns. `value` returns null when the account has no data for the
// column; those rows always sink to the bottom, whichever direction is chosen.
// `first` is the direction a first click uses: usage columns put the most
// headroom on top (like the default board), plan and overage the largest.
export const SORT_COLUMNS = {
  account: { label: 'account', first: 'asc', value: (a) => String(a.label || a.id || '').toLowerCase() },
  plan: { label: 'plan', first: 'desc', value: (a) => (a.tier ? tierWeight(a.tier).weight : null) },
  session: { label: 'session', first: 'asc', value: (a) => (a.usage ? (a.usage.session?.pct ?? 0) : null) },
  weekly: { label: 'weekly', first: 'asc', value: (a) => a.usage?.weekly?.pct ?? null },
  model: {
    label: 'model weekly', first: 'asc',
    value: (a) => {
      const pcts = (a.usage?.weeklyModels || []).map((m) => m?.pct).filter((p) => p != null);
      return pcts.length ? Math.max(...pcts) : null;
    },
  },
  overage: { label: 'overage', first: 'desc', value: (a) => (a.usage?.overage?.enabled ? a.usage.overage.usedUsd ?? 0 : null) },
};

export const DEFAULT_SORT = { key: 'headroom', dir: 'asc' };

// Next sort state after a click on column `key`: first click uses the column's
// natural direction, the second reverses it, the third returns to headroom.
export function nextSort(current, key) {
  const col = SORT_COLUMNS[key];
  if (!col) return DEFAULT_SORT;
  if (!current || current.key !== key) return { key, dir: col.first };
  if (current.dir === col.first) return { key, dir: col.first === 'asc' ? 'desc' : 'asc' };
  return DEFAULT_SORT;
}

// Parse a stored sort ("weekly:desc"); anything unrecognized is the default.
export function parseSort(s) {
  const [key, dir] = String(s || '').split(':');
  if (SORT_COLUMNS[key] && (dir === 'asc' || dir === 'desc')) return { key, dir };
  return DEFAULT_SORT;
}

const cmp = (x, y) => (typeof x === 'string' ? x.localeCompare(y) : x - y);

// Returns a new array in board order. Ties fall back to the headroom order,
// then the label, so rows never shuffle between refreshes.
export function sortAccounts(accounts, sort = DEFAULT_SORT, thresholds) {
  const list = Array.isArray(accounts) ? [...accounts] : [];
  const col = SORT_COLUMNS[sort?.key];
  const sign = sort?.dir === 'desc' ? -1 : 1;
  const name = (a) => String(a.label || a.id || '').toLowerCase();
  return list.sort((a, b) => {
    if (col) {
      const va = col.value(a), vb = col.value(b);
      if (va == null || vb == null) {
        if (va != null) return -1;
        if (vb != null) return 1;
      } else {
        const c = cmp(va, vb);
        if (c !== 0) return sign * c;
      }
    }
    const h = headroomKey(a, thresholds) - headroomKey(b, thresholds);
    if (h !== 0) return h;
    return name(a).localeCompare(name(b));
  });
}
