// Local stand-in for your Oracle ORDS server, for testing the dashboard + /admin without Oracle.
//   node scripts/mock-ords.mjs
// GET  http://localhost:9100/ords/hrms/dash/dashboard/        needs header  X-API-Key: test-key-123
// POST http://localhost:9100/ords/hrms/dash/manage/dashboard  needs header  X-API-Key: test-write-123
// Data lives in memory (restart = reset). It mimics what the Oracle package does: creates day columns /
// rows / metric columns on demand, writes cells and recalculates subtotal / TOTAL / GRAND TOTAL.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const data = JSON.parse(fs.readFileSync(path.join(root, 'lib', 'sample-data.json'), 'utf8'));
data.source = 'Oracle ORDS (mock)';

const READ_KEY = process.env.MOCK_KEY || 'test-key-123';
const WRITE_KEY = process.env.MOCK_WRITE_KEY || 'test-write-123';
const ALIAS = process.env.MOCK_ALIAS || 'hrms';
const PORT = Number(process.env.MOCK_PORT) || 9100;

const fmt = (v, unit) =>
  unit === '%' ? `${Math.abs(v * 100) < 10 && v !== 0 ? (v * 100).toFixed(1) : Math.round(v * 100)}%`
  : v === 0 ? '-' : Math.round(v).toLocaleString('en-US');

function reindex(t) {
  t.columns.forEach((c, i) => (c.index = i));
  t.groups = t.groups.filter((g) => t.columns.some((c) => c.group === g.id));
  for (const g of t.groups) g.columns = t.columns.filter((c) => c.group === g.id).map((c) => c.index);
}
function insertColumn(t, col, pos) {
  t.columns.splice(pos, 0, col);
  for (const r of t.rows) r.cells.splice(pos, 0, null);
  reindex(t);
}
function addDayColumn(t, date) {
  const days = t.columns.filter((c) => c.kind === 'day');
  const prev = days.filter((c) => c.date < date).pop();
  const next = days.find((c) => c.date > date);
  const pos = prev ? prev.index + 1 : next ? next.index : t.columns.length;
  const col = { index: 0, group: (days[0] ?? {}).group ?? 'daily', kind: 'day', label: date, short: date, unit: (days[0] ?? {}).unit ?? 'Kg', date };
  insertColumn(t, col, pos);
  return col;
}
function addMetric(t, c) {
  let g = t.groups.find((x) => x.id === c.group);
  if (!g) t.groups.push((g = { id: c.group, label: c.group_label || c.group, columns: [] }));
  const last = t.columns.filter((x) => x.group === c.group).pop();
  const col = { index: 0, group: c.group, kind: 'metric', label: c.label, short: c.short || c.label, unit: c.unit || '' };
  insertColumn(t, col, last ? last.index + 1 : t.columns.length);
  return col;
}
function addRow(t, label, kind = 'item') {
  const row = { label, kind, cells: t.columns.map(() => null) };
  const at = kind === 'item' ? t.rows.findIndex((r) => r.kind !== 'item') : t.rows.length;
  t.rows.splice(at < 0 ? t.rows.length : at, 0, row);
  return row;
}
const num = (r, i) => (r.cells[i] && typeof r.cells[i].v === 'number' ? r.cells[i].v : 0);
function recalc(t) {
  const of = (k) => t.rows.filter((r) => r.kind === k);
  const [sub] = of('subtotal'), [tot] = of('total'), [grand] = of('grand');
  const cur = t.currentMonth;
  const mtd = t.columns.find((c) => c.kind === 'month' && c.isCurrentMonth);
  if (mtd) for (const r of [...of('item'), ...of('channel')]) {
    const s = t.columns.filter((c) => c.kind === 'day' && c.date?.startsWith(cur)).reduce((a, c) => a + num(r, c.index), 0);
    r.cells[mtd.index] = { v: s, t: fmt(s, mtd.unit) };
  }
  for (const c of t.columns.filter((c) => c.kind === 'day' || c === mtd)) {
    const i = c.index;
    const items = of('item').reduce((a, r) => a + num(r, i), 0);
    const chans = of('channel').reduce((a, r) => a + num(r, i), 0);
    if (sub) sub.cells[i] = { v: items, t: fmt(items, c.unit) };
    if (tot) tot.cells[i] = { v: items + chans, t: fmt(items + chans, c.unit) };
    if (grand && c.kind === 'day') { const g = items + chans + of('export').reduce((a, r) => a + num(r, i), 0); grand.cells[i] = { v: g, t: fmt(g, c.unit) }; }
  }
}

function apply(body) {
  const t = data.tables.find((x) => x.id === body.table);
  if (!t) throw Object.assign(new Error(`Table "${body.table}" not found.`), { status: 404 });
  let colsNew = 0, rowsNew = 0, written = 0, cleared = 0, maxDate = '';
  for (const c of body.columns ?? []) {
    if (c.kind === 'day') { if (!t.columns.some((x) => x.kind === 'day' && x.date === c.date)) { addDayColumn(t, c.date); colsNew++; } }
    else if (!t.columns.some((x) => x.group === c.group && x.label.toLowerCase() === c.label.toLowerCase() && (!c.unit || x.unit === c.unit))) { addMetric(t, c); colsNew++; }
  }
  for (const r of body.rows ?? []) if (!t.rows.some((x) => x.label.toLowerCase() === r.label.toLowerCase())) { addRow(t, r.label, r.kind); rowsNew++; }
  (body.cells ?? []).forEach((c, i) => {
    let row = t.rows.find((r) => r.label.toLowerCase() === String(c.row).toLowerCase());
    if (!row) { if (body.auto_create_rows) { row = addRow(t, c.row); rowsNew++; } else throw Object.assign(new Error(`Row "${c.row}" not found (set "auto_create_rows": true to create it).`), { status: 404 }); }
    let col;
    if (/^\d{4}-\d{2}-\d{2}$/.test(c.column)) {
      col = t.columns.find((x) => x.kind === 'day' && x.date === c.column);
      if (!col) { if (body.auto_create_columns !== false) { col = addDayColumn(t, c.column); colsNew++; } else throw Object.assign(new Error(`No daily column for ${c.column}`), { status: 404 }); }
    } else {
      const m = t.columns.filter((x) => (x.label.toLowerCase() === c.column.toLowerCase() || x.short.toLowerCase() === c.column.toLowerCase()) && (!c.group || x.group === c.group) && (!c.unit || x.unit === c.unit));
      if (m.length === 0) throw Object.assign(new Error(`Column "${c.column}" not found.`), { status: 404 });
      if (m.length > 1) throw Object.assign(new Error(`Column "${c.column}" is ambiguous (${m.length} matches). Add "group" and/or "unit".`), { status: 409 });
      col = m[0];
    }
    if (c.clear) { row.cells[col.index] = null; cleared++; return; }
    if ('value' in c) { row.cells[col.index] = { v: c.value, t: c.display ?? fmt(c.value, col.unit) }; written++; if (col.kind === 'day' && col.date > maxDate) maxDate = col.date; }
    else if ('text' in c) { row.cells[col.index] = { v: c.text, t: c.text }; written++; }
    else throw Object.assign(new Error(`cells[${i + 1}] needs "value", "text" or "clear": true.`), { status: 400 });
  });
  if (maxDate && maxDate > data.reportDate) { data.reportDate = maxDate; t.reportDate = maxDate; }
  if (body.recalc !== false) recalc(t);
  data.updatedAt = new Date().toISOString();
  return { status: 'ok', columns_created: colsNew, rows_created: rowsNew, written, cleared, recalculated: body.recalc !== false };
}

http
  .createServer((req, res) => {
    const send = (code, body) => { res.writeHead(code, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    const url = req.url.split('?')[0];
    const key = req.headers['x-api-key'];
    console.log(new Date().toISOString(), req.method, url, key ? '(key sent)' : '(no key)');

    if (req.method === 'GET' && url.startsWith(`/ords/${ALIAS}/dash/dashboard/`)) {
      if (key !== READ_KEY && key !== WRITE_KEY) return send(401, { error: 'Missing or invalid API key', code: -20401 });
      return send(200, data);
    }
    if (req.method === 'POST' && url === `/ords/${ALIAS}/dash/manage/dashboard`) {
      if (key !== WRITE_KEY) return send(401, { error: 'Missing or invalid API key', code: -20401 });
      let raw = '';
      req.on('data', (d) => (raw += d));
      req.on('end', () => {
        try { send(200, apply(JSON.parse(raw))); }
        catch (e) { send(e.status ?? 400, { error: e.message, code: -20001 }); }
      });
      return;
    }
    send(404, { error: 'not found' });
  })
  .listen(PORT, () => console.log(`Mock ORDS on http://localhost:${PORT}/ords/${ALIAS}/dash/  (read key: ${READ_KEY}, write key: ${WRITE_KEY})`));
