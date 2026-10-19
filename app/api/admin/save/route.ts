import { NextResponse } from 'next/server';
import { isAdminAuthed, sameOrigin } from '@/lib/admin-auth';
import { OrdsHttpError, ordsPostDashboard } from '@/lib/ords';

export const runtime = 'nodejs';

/**
 * Admin save: validates the request, then forwards ONLY known fields to the Oracle POST endpoint
 * (/dash/manage/dashboard) using the server-side write credentials.
 * Body: { table, cells?: [...], columns?: [...], rows?: [...] }
 */
type Obj = Record<string, unknown>;
const isObj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);
const str = (v: unknown, max = 300) => (typeof v === 'string' && v.trim() !== '' && v.length <= max ? v.trim() : undefined);
const DATE = /^\d{4}-\d{2}-\d{2}$/;
const ROW_KINDS = ['item', 'subtotal', 'channel', 'total', 'growth', 'export', 'grand', 'detail'];

function cleanCell(c: unknown, i: number): Obj {
  if (!isObj(c)) throw new Error(`cells[${i}] must be an object.`);
  const out: Obj = {};
  const row = str(c.row);
  const column = str(c.column);
  if (!row) throw new Error(`cells[${i}]: "row" is required.`);
  if (!column) throw new Error(`cells[${i}]: "column" is required.`);
  out.row = row;
  out.column = column;
  if (str(c.group)) out.group = str(c.group);
  if (str(c.unit, 20)) out.unit = str(c.unit, 20);
  if (c.clear === true) {
    out.clear = true;
  } else if ('value' in c && c.value !== undefined) {
    if (c.value === null) out.clear = true;
    else if (typeof c.value === 'number' && Number.isFinite(c.value)) out.value = c.value;
    else throw new Error(`cells[${i}]: "value" must be a number.`);
  } else if (typeof c.text === 'string') {
    if (c.text.length > 4000) throw new Error(`cells[${i}]: text is too long.`);
    out.text = c.text;
  } else {
    throw new Error(`cells[${i}] needs "value", "text" or "clear".`);
  }
  return out;
}

function cleanColumn(c: unknown, i: number): Obj {
  if (!isObj(c)) throw new Error(`columns[${i}] must be an object.`);
  const kind = c.kind === 'day' || c.kind === 'month' || c.kind === 'metric' ? c.kind : 'metric';
  const out: Obj = { kind };
  if (kind === 'day') {
    if (typeof c.date !== 'string' || !DATE.test(c.date)) throw new Error(`columns[${i}]: "date" must be YYYY-MM-DD.`);
    out.date = c.date;
  } else if (kind === 'month') {
    if (typeof c.month !== 'string' || !/^\d{4}-(0[1-9]|1[0-2])$/.test(c.month)) throw new Error(`columns[${i}]: "month" must be YYYY-MM.`);
    out.month = c.month;
  } else if (!str(c.label) || !str(c.group)) {
    throw new Error(`columns[${i}]: a metric column needs "group" and "label".`);
  }
  for (const k of ['label', 'short', 'group', 'group_label'] as const) if (str(c[k])) out[k] = str(c[k]);
  if (str(c.unit, 20)) out.unit = str(c.unit, 20);
  return out;
}

function cleanRow(r: unknown, i: number): Obj {
  if (!isObj(r) || !str(r.label)) throw new Error(`rows[${i}]: "label" is required.`);
  const kind = typeof r.kind === 'string' && ROW_KINDS.includes(r.kind) ? r.kind : 'item';
  return { label: str(r.label), kind };
}

export async function POST(req: Request) {
  if (!sameOrigin(req)) return NextResponse.json({ error: 'Bad origin.' }, { status: 403 });
  if (!(await isAdminAuthed())) return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });

  let payload: Obj;
  try {
    const body = (await req.json()) as unknown;
    if (!isObj(body)) throw new Error('Body must be a JSON object.');
    const table = str(body.table, 60);
    if (!table || !/^[A-Za-z0-9_-]+$/.test(table)) throw new Error('"table" is required.');
    const cells = Array.isArray(body.cells) ? body.cells : [];
    const columns = Array.isArray(body.columns) ? body.columns : [];
    const rows = Array.isArray(body.rows) ? body.rows : [];
    if (cells.length + columns.length + rows.length === 0) throw new Error('Nothing to save.');
    if (cells.length > 600 || columns.length > 50 || rows.length > 100) throw new Error('Too many items in one save.');
    payload = { table, recalc: true, auto_create_rows: false, auto_create_columns: true };
    if (cells.length) payload.cells = cells.map(cleanCell);
    if (columns.length) payload.columns = columns.map(cleanColumn);
    if (rows.length) payload.rows = rows.map(cleanRow);
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : 'Invalid request.' }, { status: 400 });
  }

  try {
    const result = await ordsPostDashboard(payload);
    return NextResponse.json({ ok: true, result });
  } catch (error) {
    if (error instanceof OrdsHttpError) {
      const status = error.status === 401 || error.status === 403 ? 502 : error.status >= 400 && error.status < 500 ? error.status : 502;
      const msg = error.status === 401 || error.status === 403 ? 'Oracle rejected the write credentials (check ORDS_WRITE_API_KEY).' : error.message;
      return NextResponse.json({ error: msg }, { status });
    }
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 502 });
  }
}
