import type { Cell, DashboardData, RowKind, SheetTable, TableColumn, TableRow } from './types';

/* ---------- small helpers ---------- */

export const num = (c: Cell | null | undefined): number => (c && typeof c.v === 'number' ? c.v : 0);
export const hasNum = (c: Cell | null | undefined): c is Cell => !!c && typeof c.v === 'number';

export const tableById = (data: DashboardData | null, id: string) => data?.tables.find((t) => t.id === id);
export const rowOfKind = (t: SheetTable | undefined, kind: RowKind) => t?.rows.find((r) => r.kind === kind);
export const rowsOfKind = (t: SheetTable | undefined, ...kinds: RowKind[]) => (t?.rows ?? []).filter((r) => kinds.includes(r.kind));

/** First column whose header matches `re` (optionally limited to a group). */
export function findColumn(t: SheetTable | undefined, re: RegExp, opts: { group?: string; kind?: TableColumn['kind'] } = {}) {
  return t?.columns.find((c) => (!opts.group || c.group === opts.group) && (!opts.kind || c.kind === opts.kind) && re.test(c.label));
}
export const currentMonthColumn = (t: SheetTable | undefined) => t?.columns.find((c) => c.kind === 'month' && c.isCurrentMonth);

export const cellAt = (row: TableRow | undefined, col: TableColumn | undefined) => (row && col ? row.cells[col.index] ?? null : null);

export const monthLongName = (key: string) =>
  key ? new Date(`${key}-01T12:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' }) : '';

/* ---------- chart series ---------- */

export type DailyPoint = { date: string; sales: number };
export type MonthlyPoint = { month: string; label: string; sales: number; isCurrent: boolean };

export function dailySeries(t: SheetTable | undefined, row: TableRow | undefined): DailyPoint[] {
  if (!t || !row) return [];
  return t.columns
    .filter((c) => c.kind === 'day' && c.date)
    .map((c) => ({ date: c.date as string, sales: num(row.cells[c.index]) }));
}

export function monthlySeries(t: SheetTable | undefined, row: TableRow | undefined): MonthlyPoint[] {
  if (!t || !row) return [];
  return t.columns
    .filter((c) => c.kind === 'month' && c.month)
    .sort((a, b) => (a.month as string).localeCompare(b.month as string))
    .map((c) => ({
      month: c.month as string,
      label: c.isCurrentMonth ? `${c.short} MTD` : c.short,
      sales: num(row.cells[c.index]),
      isCurrent: !!c.isCurrentMonth,
    }));
}

/* ---------- selectable series (for the trend chart) ---------- */

export type SeriesOption = { key: string; label: string; group: string; tableId: string; row: TableRow };

export function seriesOptions(data: DashboardData | null): SeriesOption[] {
  const out: SeriesOption[] = [];
  for (const t of data?.tables ?? []) {
    const groupName = t.id === 'region' ? 'Regions' : t.id === 'blend' ? 'Blends' : t.title;
    t.rows.forEach((r, i) => {
      if (r.kind === 'growth' || r.kind === 'detail') return;
      if (!t.columns.some((c) => c.kind === 'day' && hasNum(r.cells[c.index]))) return;
      const label = r.kind === 'total' ? `TOTAL (${t.id === 'region' ? 'all regions' : 'all blends'})` : r.label;
      out.push({ key: `${t.id}:${i}`, label, group: r.kind === 'item' ? groupName : 'Totals & channels', tableId: t.id, row: r });
    });
  }
  return out;
}

/* ---------- KPI cards ---------- */

export type Kpi = { title: string; value: string; unit?: string; note?: string; pill?: string; negative?: boolean; tone: 'solid' | 'tint' };
export type KpiSection = { title: string; subtitle?: string; cards: Kpi[] };

const unitOf = (col: TableColumn | undefined) => (col && /^kg$/i.test(col.unit) ? 'kg' : undefined);

function card(
  t: SheetTable | undefined,
  rowKind: RowKind,
  col: TableColumn | undefined,
  title: string,
  extra: Partial<Kpi> = {},
): Kpi | null {
  const cell = cellAt(rowOfKind(t, rowKind), col);
  if (!cell || cell.t === '—') return null;
  return { title, value: cell.t, unit: cell.t.trim().endsWith('%') ? undefined : unitOf(col), negative: typeof cell.v === 'number' && cell.v < 0, tone: 'tint', ...extra };
}

export function buildKpiSections(t: SheetTable | undefined): KpiSection[] {
  if (!t) return [];
  const f = (re: RegExp, group?: string) => findColumn(t, re, { group });
  const monthName = t.currentMonth ? new Date(`${t.currentMonth}-01T12:00:00`).toLocaleDateString('en-GB', { month: 'long' }) : 'Month';

  const mtd = currentMonthColumn(t);
  const target = f(/^RSF Target/i, 'month');
  const remaining = f(/^Remaining/i);
  const achievement = f(/^Achievement/i, 'month');
  const lastYear = t.columns.find((c) => c.kind === 'metric' && c.group === 'month' && /primary sales/i.test(c.label) && !/mtd/i.test(c.label));
  const fg = t.columns.find((c) => /^FG$/i.test(c.label) && c.kind === 'metric');
  const transit = f(/^Transit/i);
  const totalSc = f(/^Total SC/i);
  const fgAvail = f(/FG Available/i);
  const wh = f(/WH Utilized/i);
  const ytd = f(/^YTD Primary/i);
  const ytdRsf = f(/^YTD RSF/i);
  const ytdOver = f(/^Over\/?\s*Under/i);
  const ytdAch = ytd ? t.columns.find((c) => c.group === ytd.group && /^Achieve/i.test(c.label)) : undefined;

  const total = rowOfKind(t, 'total');
  const growth = rowOfKind(t, 'growth');
  const growthCell = cellAt(growth, lastYear);
  const achCell = cellAt(total, achievement);

  const ok = (x: Kpi | null): x is Kpi => !!x;

  const sections: KpiSection[] = [
    {
      title: 'Month at a glance',
      subtitle: `${monthName} primary sales against RSF target`,
      cards: [
        card(t, 'total', mtd, `${monthName} MTD sales`, { tone: 'solid', pill: achCell && achCell.t !== '—' ? `${achCell.t} of RSF` : undefined, note: 'Total primary sales' }),
        card(t, 'total', target, 'RSF target', { note: `${monthName} target` }),
        card(t, 'total', remaining, 'Remaining volume', { note: 'Still to reach RSF' }),
        card(t, 'total', lastYear, `Last year · ${lastYear?.label.match(/[A-Za-z]{3,9}\s+\d{4}/)?.[0] ?? 'same month'}`, {
          note: 'Same month, last year',
          pill: growthCell && growthCell.t !== '—' ? growthCell.t : undefined,
        }),
      ].filter(ok),
    },
    {
      title: 'Stock & warehouse',
      subtitle: 'Finished goods, transit and capacity',
      cards: [
        card(t, 'total', fg, 'FG stock', { tone: 'solid' }),
        card(t, 'total', transit, 'In transit'),
        card(t, 'total', totalSc, 'Total stock cover', { note: 'FG + transit' }),
        card(t, 'total', fgAvail, 'FG vs RSF', { note: 'FG available against RSF' }),
        card(t, 'total', wh, 'WH utilised', { note: 'Warehouse capacity used' }),
      ].filter(ok),
    },
    {
      title: 'Year to date',
      subtitle: t.groups.find((g) => /to\s*date/i.test(g.label))?.label.replace(/^YTD · /, '') ?? undefined,
      cards: [
        card(t, 'total', ytd, 'YTD primary sales', { tone: 'solid' }),
        card(t, 'total', ytdRsf, 'YTD RSF'),
        card(t, 'total', ytdOver, 'Over / under'),
        card(t, 'total', ytdAch, 'YTD achievement'),
      ].filter(ok),
    },
    {
      title: 'Including export',
      subtitle: 'Grand total and export lines',
      cards: [
        card(t, 'grand', mtd, `Grand total ${monthName} MTD`, { tone: 'solid' }),
        card(t, 'export', lastYear, 'Export · same month last year'),
        card(t, 'export', ytd, 'Export YTD'),
        card(t, 'grand', ytd, 'Grand total YTD'),
      ].filter(ok),
    },
  ];
  return sections.filter((s) => s.cards.length);
}
