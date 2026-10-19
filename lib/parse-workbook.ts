import type {
  Cell, DashboardData, RowKind, SheetTable, TableColumn, TableGroup, TableRow,
} from './types';

/**
 * Turns the Google Sheet (in the same layout as Dashboard.xlsx) into generic tables.
 *
 * Nothing is tied to a cell address. The parser looks for:
 *   - table headers ..... a cell in the first columns containing "... WISE"
 *                         (e.g. "G.T Primary Sales REGION WISE", "... BLEND WISE")
 *   - group labels ...... the row just above a header ("FG", "July 2026 Todate")
 *   - report date ....... the first date two rows above a header (B1 / B26)
 *   - day columns ....... date cells in the header row ("Sunday" in place of a date is handled)
 *   - month columns ..... headers like "Primary Sales MTD <Month> <Year>"
 *   - row kinds ......... by label: National / Other Channels / TOTAL / Over last Year / Export / GRAND TOTAL
 * so adding rows (a new blend, a new region) or new columns just appears on the dashboard.
 */

type Raw = unknown;
type Rows = Raw[][];

const MONTHS = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const WEEKDAY = /^(sun|mon|tues|wednes|thurs|fri|satur)day$/i;
const ERROR_VALUE = /^#(DIV\/0!|REF!|N\/A|NAME\?|VALUE!|NUM!|NULL!|ERROR!)/i;
const DAY_MS = 86_400_000;

const clean = (v: Raw) => (typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : '');
const isBlank = (v: Raw) => v === null || v === undefined || (typeof v === 'string' && v.trim() === '');

function serialToDate(n: number): Date { return new Date(Date.UTC(1899, 11, 30) + Math.round(n * DAY_MS)); }

function toDate(v: Raw): Date | null {
  if (typeof v === 'number' && v > 20000 && v < 80000) return serialToDate(v);
  if (typeof v === 'string') {
    const s = v.trim();
    if (/^\d{4}-\d{2}-\d{2}/.test(s) || /^\d{1,2}[\s/-][A-Za-z]{3,9}[\s/-]\d{2,4}$/.test(s)) {
      const t = Date.parse(s);
      if (!Number.isNaN(t)) { const d = new Date(t); return new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())); }
    }
  }
  return null;
}
const iso = (d: Date) => d.toISOString().slice(0, 10);

function parseMonth(header: string) {
  const m = header.match(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*'?(\d{4})\b/i);
  if (!m) return null;
  const idx = MONTHS.findIndex((n) => n.startsWith(m[1].toLowerCase()));
  return { key: `${m[2]}-${String(idx + 1).padStart(2, '0')}`, name: MONTHS[idx][0].toUpperCase() + MONTHS[idx].slice(1), year: m[2] };
}

const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'group';

/** Nicer names for the group bands. Anything not listed uses the text found in the sheet. */
const GROUP_LABELS: Record<string, string> = {
  fg: 'FG stock & warehouse',
};

/** Fallback display text when the sheet did not give us a formatted value. */
function fallbackText(v: number, unit: string): string {
  if (unit === '%') return `${(v * 100).toFixed(Math.abs(v * 100) < 10 && v !== 0 ? 1 : 0)}%`;
  return Number.isInteger(v) ? v.toLocaleString('en-US') : v.toLocaleString('en-US', { maximumFractionDigits: 1 });
}

function makeCell(raw: Raw, formatted: Raw, unit: string): Cell | null {
  if (isBlank(raw)) return null;
  if (typeof raw === 'string' && ERROR_VALUE.test(raw.trim())) return { v: null, t: '—' };
  if (typeof raw === 'number') {
    const f = typeof formatted === 'string' ? formatted.replace(/\s+/g, ' ').trim() : '';
    return { v: raw, t: f || fallbackText(raw, unit) };
  }
  if (typeof raw === 'boolean') return null;
  return { v: String(raw).trim(), t: String(raw).replace(/\s+/g, ' ').trim() };
}

function rowKind(label: string, state: { seenSubtotal: boolean; seenTotal: boolean; seenGrand: boolean }): RowKind {
  const l = label.toLowerCase();
  if (/^grand\s*total/.test(l)) { state.seenGrand = true; return 'grand'; }
  if (state.seenGrand) return 'detail';
  if (/^total$/.test(l)) { state.seenTotal = true; return 'total'; }
  if (/over\s+last\s+year/.test(l)) return 'growth';
  if (/^export/.test(l)) return 'export';
  if (/^national\b/.test(l)) { state.seenSubtotal = true; return 'subtotal'; }
  if (state.seenSubtotal && !state.seenTotal) return 'channel';
  return 'item';
}

function cleanLabel(label: string, kind: RowKind): string {
  let s = label.replace(/\s+/g, ' ').trim();
  if (kind === 'item') s = s.replace(/^g\.?t\.?\s+primary\s+sales\s+of\s+/i, '').replace(/\s+region$/i, '').trim();
  if (kind === 'detail') s = s.replace(/^[(\s]+/, '').replace(/[,)\s]+$/, '').trim();
  return s || label.trim();
}

function parseTable(raw: Rows, fmt: Rows, headerRow: number, nextHeaderRow: number): SheetTable | null {
  const at = (r: number, c: number) => raw[r]?.[c];
  const header = raw[headerRow] ?? [];
  const title = clean((header.slice(0, 3).find((c) => /wise/i.test(clean(c))) as string) ?? '');
  const idWord = title.match(/(\w+)\s+wise/i)?.[1] ?? title;
  const id = slug(idWord);

  // unit row (Kg / %) directly under the header
  const unitRowIdx = headerRow + 1;
  const unitRow = raw[unitRowIdx] ?? [];
  const hasUnitRow = isBlank(unitRow[1]) && unitRow.slice(2).some((c) => /^(kg|%|pcs|units?)$/i.test(clean(c)));
  const firstDataRow = headerRow + (hasUnitRow ? 2 : 1);

  // report date + group labels live above the header
  const groupRow = raw[headerRow - 1] ?? [];
  const dateRow = raw[headerRow - 2] ?? [];
  let reportDate: Date | null = null;
  for (const c of dateRow) { const d = toDate(c); if (d) { reportDate = d; break; } }

  // data rows: stop at the next table or at its date row
  const dataRows: { r: number; label: string }[] = [];
  const end = Math.min(nextHeaderRow >= 0 ? nextHeaderRow : raw.length, raw.length);
  for (let r = firstDataRow; r < end; r++) {
    const row = raw[r] ?? [];
    if (toDate(row[1])) break;
    const label = clean(row[1]) || clean(row[0]);
    if (!label) continue;
    dataRows.push({ r, label });
  }
  if (!dataRows.length) return null;

  // which columns exist: those with a header or with any data
  let maxCol = 0;
  for (const row of [header, unitRow, ...dataRows.map((d) => raw[d.r] ?? [])]) maxCol = Math.max(maxCol, row.length);
  const candidates: number[] = [];
  for (let c = 2; c < maxCol; c++) {
    const hasHeader = !isBlank(header[c]);
    const hasData = dataRows.some(({ r }) => !isBlank(at(r, c)));
    if (hasHeader || hasData) candidates.push(c);
  }

  // build columns + groups in sheet order
  const columns: TableColumn[] = [];
  const groups: TableGroup[] = [];
  const groupById = new Map<string, TableGroup>();
  const ensureGroup = (gid: string, label: string) => {
    let g = groupById.get(gid);
    if (!g) { g = { id: gid, label, columns: [] }; groupById.set(gid, g); groups.push(g); }
    return g;
  };

  let stage: 'history' | 'days' | 'after' = 'history';
  let currentGroupId = 'history';
  let prevDay: Date | null = null;
  const dayDates: (Date | null)[] = [];

  for (const c of candidates) {
    const h = header[c];
    const hText = clean(h);
    const unit = clean(unitRow[c]);
    const groupLabel = clean(groupRow[c]);

    // day column?
    let day = toDate(h);
    if (!day && prevDay && WEEKDAY.test(hText)) day = new Date(prevDay.getTime() + DAY_MS);

    let kind: TableColumn['kind'] = 'metric';
    let gid: string;
    if (groupLabel) {
      gid = slug(groupLabel);
      currentGroupId = gid;
      ensureGroup(gid, GROUP_LABELS[gid] ?? (/to\s*date/i.test(groupLabel) ? `YTD · ${groupLabel}` : groupLabel));
      stage = 'after';
      day = null;
    } else if (day) {
      stage = 'days';
      gid = 'daily';
      currentGroupId = 'daily';
      kind = 'day';
    } else if (stage === 'history') {
      gid = 'history';
    } else if (stage === 'days') {
      stage = 'after';
      gid = 'month';
      currentGroupId = 'month';
    } else {
      gid = currentGroupId;
    }
    if (kind === 'day') prevDay = day;

    const month = kind !== 'day' && /mtd/i.test(hText) ? parseMonth(hText) : null;
    if (month) kind = 'month';

    const col: TableColumn = {
      index: columns.length,
      group: gid,
      kind,
      label: kind === 'day' && day ? iso(day) : hText,
      short: hText,
      unit,
      ...(kind === 'day' && day ? { date: iso(day) } : {}),
      ...(month ? { month: month.key } : {}),
    };
    if (month) col.short = `${month.name.slice(0, 3)} ${month.year}`;
    if (kind === 'day') col.short = day ? iso(day) : hText;
    columns.push(col);
    dayDates.push(kind === 'day' ? day : null);
    ensureGroup(gid, GROUP_LABELS[gid] ?? (gid === 'history' ? 'Previous months' : gid === 'daily' ? 'Daily sales' : gid === 'month' ? 'Month performance' : gid));
    groupById.get(gid)!.columns.push(col.index);
    (col as TableColumn & { _src: number })._src = c;
  }

  // text-only blank-header columns are remarks
  for (const col of columns) {
    const src = (col as TableColumn & { _src: number })._src;
    if (!col.label) {
      const anyText = dataRows.some(({ r }) => typeof at(r, src) === 'string');
      col.label = col.short = anyText ? 'Remarks' : '';
    }
  }

  // current month = month of the daily columns
  const firstDay = columns.find((c) => c.date);
  const currentMonth = firstDay?.date?.slice(0, 7) ?? '';
  for (const col of columns) {
    if (col.kind === 'month' && col.month === currentMonth) col.isCurrentMonth = true;
  }
  const currentMonthName = currentMonth ? parseMonth(`${MONTHS[Number(currentMonth.slice(5)) - 1]} ${currentMonth.slice(0, 4)}`) : null;
  const dailyGroup = groupById.get('daily');
  if (dailyGroup && currentMonthName) dailyGroup.label = `Daily sales · ${currentMonthName.name} ${currentMonthName.year}`;
  const monthGroup = groupById.get('month');
  if (monthGroup && currentMonthName) monthGroup.label = `${currentMonthName.name} ${currentMonthName.year} performance`;

  // rows
  const state = { seenSubtotal: false, seenTotal: false, seenGrand: false };
  const rows: TableRow[] = dataRows.map(({ r, label }) => {
    const kind = rowKind(label, state);
    const cells = columns.map((col) => {
      const src = (col as TableColumn & { _src: number })._src;
      return makeCell(at(r, src), fmt[r]?.[src], col.unit);
    });
    return { label: cleanLabel(label, kind), kind, cells };
  });

  // drop future day columns that have no data and are after the report date
  const keep = columns.map((col) => {
    if (col.kind !== 'day' || !col.date) return true;
    if (!reportDate) return rows.some((row) => { const c = row.cells[col.index]; return c && typeof c.v === 'number' && c.v !== 0; });
    if (new Date(`${col.date}T00:00:00Z`) <= reportDate) return true;
    return rows.some((row) => { const c = row.cells[col.index]; return c && typeof c.v === 'number' && c.v !== 0; });
  });

  const remap = new Map<number, number>();
  const outColumns: TableColumn[] = [];
  columns.forEach((col, i) => {
    if (!keep[i]) return;
    remap.set(col.index, outColumns.length);
    const { _src, ...rest } = col as TableColumn & { _src?: number };
    void _src;
    outColumns.push({ ...rest, index: outColumns.length });
  });
  const outRows = rows.map((row) => ({ ...row, cells: row.cells.filter((_, i) => keep[i]) }));
  const outGroups = groups
    .map((g) => ({ ...g, columns: g.columns.filter((i) => remap.has(i)).map((i) => remap.get(i)!) }))
    .filter((g) => g.columns.length);

  return {
    id,
    title,
    reportDate: reportDate ? iso(reportDate) : '',
    currentMonth,
    groups: outGroups,
    columns: outColumns,
    rows: outRows,
  };
}

export function parseWorkbookRows(raw: Rows, formatted: Rows | undefined, sourceLabel: string): DashboardData {
  const fmt = formatted ?? [];
  const headers: number[] = [];
  raw.forEach((row, r) => {
    if ((row ?? []).slice(0, 3).some((c) => typeof c === 'string' && /\bwise\b/i.test(c) && !ERROR_VALUE.test(c))) headers.push(r);
  });
  if (!headers.length) throw new Error('Could not find any "... WISE" table headers in the sheet.');

  const tables: SheetTable[] = [];
  headers.forEach((h, i) => {
    const next = i + 1 < headers.length ? headers[i + 1] : -1;
    const t = parseTable(raw, fmt, h, next);
    if (t) tables.push(t);
  });
  if (!tables.length) throw new Error('The sheet has "WISE" headers but no data rows under them.');

  const reportDate = tables.find((t) => t.reportDate)?.reportDate ?? '';
  return {
    reportDate,
    tables,
    updatedAt: reportDate ? `${reportDate}T00:00:00.000Z` : new Date().toISOString(),
    source: sourceLabel,
  };
}
