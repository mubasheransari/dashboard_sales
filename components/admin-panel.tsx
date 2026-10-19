'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { DashboardData, SheetTable, TableColumn } from '@/lib/types';

type Tab = 'daily' | 'cell' | 'structure';
type Json = Record<string, unknown>;
type Pending = { id: number; label: string; cell: Json };

const EDITABLE_ROW_KINDS = ['item', 'channel', 'export', 'detail'];   // totals are recalculated by Oracle
const ROW_KIND_LABELS: Record<string, string> = {
  item: 'Region / blend (adds to National total)', channel: 'Channel (adds to TOTAL)', export: 'Export', detail: 'Detail (helper row)',
};
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const addDays = (isoDate: string, n: number) => { const d = new Date(`${isoDate}T12:00:00`); d.setDate(d.getDate() + n); return iso(d); };
const parseNumber = (s: string): number | null => {
  const t = s.replace(/,/g, '').trim();
  if (t === '' || !/^-?\d*\.?\d+(e[+-]?\d+)?$/i.test(t)) return null;
  return Number(t);
};

async function post(url: string, body: unknown): Promise<Json> {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const json = (await res.json().catch(() => ({}))) as Json;
  if (res.status === 401 && url !== '/api/admin/login') { window.location.reload(); }
  if (!res.ok) throw new Error(typeof json.error === 'string' ? json.error : `Request failed (${res.status})`);
  return json;
}

function summarize(result: Json): string {
  const r = (result.result ?? {}) as Json;
  const parts: string[] = [];
  if (Number(r.written)) parts.push(`${r.written} value(s) saved`);
  if (Number(r.cleared)) parts.push(`${r.cleared} cleared`);
  if (Number(r.columns_created)) parts.push(`${r.columns_created} column(s) created`);
  if (Number(r.rows_created)) parts.push(`${r.rows_created} row(s) created`);
  return (parts.length ? parts.join(', ') : 'Saved') + '. Totals were recalculated.';
}

export default function AdminPanel() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [canWrite, setCanWrite] = useState(true);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [saving, setSaving] = useState(false);
  const [tableId, setTableId] = useState('');
  const [tab, setTab] = useState<Tab>('daily');

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const res = await fetch('/api/admin/data', { cache: 'no-store' });
      if (res.status === 401) { window.location.reload(); return; }
      const json = (await res.json()) as { data?: DashboardData; canWrite?: boolean; error?: string };
      if (!res.ok || !json.data) throw new Error(json.error ?? 'Could not load data');
      setData(json.data);
      setCanWrite(json.canWrite !== false);
      setTableId((cur) => (cur && json.data!.tables.some((t) => t.id === cur) ? cur : json.data!.tables[0]?.id ?? ''));
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load data');
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => { void load(); }, [load]);

  const table = data?.tables.find((t) => t.id === tableId);

  /** Send one save to Oracle, then reload so the screen shows exactly what is stored. */
  async function save(body: Json): Promise<boolean> {
    setSaving(true);
    setError('');
    setNotice('');
    try {
      const result = await post('/api/admin/save', { table: tableId, ...body });
      setNotice(summarize(result));
      await load();
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Save failed');
      return false;
    } finally {
      setSaving(false);
    }
  }

  async function logout() {
    await post('/api/admin/logout', {}).catch(() => undefined);
    window.location.reload();
  }

  return (
    <div className="admin-shell">
      <header className="admin-top">
        <div>
          <h1>Dashboard admin</h1>
          <p>
            {data ? <>Source: {data.source} · Report date {data.reportDate} · Updated {new Date(data.updatedAt).toLocaleString()}</> : 'Loading…'}
          </p>
        </div>
        <div className="admin-actions">
          <a className="admin-btn ghost" href="/" target="_blank" rel="noreferrer">View dashboard</a>
          <button className="admin-btn ghost" onClick={() => void load()} disabled={loading}>Reload</button>
          <button className="admin-btn ghost" onClick={() => void logout()}>Sign out</button>
        </div>
      </header>

      {error && <div className="admin-msg error">{error}</div>}
      {notice && <div className="admin-msg ok">{notice} Open the dashboard and press Refresh to see it.</div>}
      {!canWrite && <div className="admin-msg error">Write credentials are not configured on the server (ORDS_WRITE_API_KEY). You can look, but not save.</div>}

      {data && table && (
        <>
          <div className="admin-bar">
            <label className="admin-field inline">
              <span>Table</span>
              <select value={tableId} onChange={(e) => { setTableId(e.target.value); setNotice(''); }}>
                {data.tables.map((t) => <option key={t.id} value={t.id}>{t.title}</option>)}
              </select>
            </label>
            <div className="admin-tabs" role="tablist">
              {([['daily', 'Daily entry'], ['cell', 'Edit any cell'], ['structure', 'Add row / column']] as [Tab, string][]).map(([k, label]) => (
                <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? 'selected' : ''} onClick={() => { setTab(k); setNotice(''); }}>{label}</button>
              ))}
            </div>
          </div>

          {tab === 'daily' && <DailyEntry key={table.id} table={table} saving={saving || !canWrite} onSave={save} setError={setError} />}
          {tab === 'cell' && <CellEditor key={table.id} table={table} saving={saving || !canWrite} onSave={save} />}
          {tab === 'structure' && <StructureEditor key={table.id} table={table} saving={saving || !canWrite} onSave={save} setError={setError} />}
        </>
      )}
      {loading && !data && <div className="admin-card">Loading data from Oracle…</div>}
    </div>
  );
}

/* ------------------------------------------------------------------ Daily entry */
function DailyEntry({ table, saving, onSave, setError }: {
  table: SheetTable; saving: boolean; onSave: (b: Json) => Promise<boolean>; setError: (m: string) => void;
}) {
  const dayCols = useMemo(() => table.columns.filter((c) => c.kind === 'day' && c.date), [table]);
  const latest = dayCols.map((c) => c.date as string).sort().pop();
  const [date, setDate] = useState(() => (latest ? addDays(latest, 1) : iso(new Date())));
  const col = dayCols.find((c) => c.date === date);
  const rows = useMemo(() => table.rows.filter((r) => EDITABLE_ROW_KINDS.includes(r.kind)), [table]);

  const orig = useMemo(() => {
    const o: Record<string, string> = {};
    for (const r of rows) {
      const cell = col ? r.cells[col.index] : null;
      o[r.label] = cell && typeof cell.v === 'number' ? String(cell.v) : '';
    }
    return o;
  }, [rows, col]);
  const [inputs, setInputs] = useState<Record<string, string>>(orig);
  useEffect(() => setInputs(orig), [orig, date]);

  const changed = rows.filter((r) => (inputs[r.label] ?? '') !== (orig[r.label] ?? ''));

  async function submit() {
    const cells: Json[] = [];
    for (const r of changed) {
      const s = (inputs[r.label] ?? '').trim();
      if (s === '') { cells.push({ row: r.label, column: date, clear: true }); continue; }
      const n = parseNumber(s);
      if (n === null) { setError(`"${s}" is not a valid number for ${r.label}.`); return; }
      cells.push({ row: r.label, column: date, value: n, ...(col?.unit ? { unit: col.unit } : {}) });
    }
    await onSave({ cells });
  }

  return (
    <section className="admin-card">
      <div className="admin-card-head">
        <div>
          <h2>Daily entry</h2>
          <p>Type the day&apos;s sales per row. National total, TOTAL and GRAND TOTAL (and the month-to-date column) are recalculated automatically.</p>
        </div>
        <div className="admin-date">
          <label className="admin-field inline"><span>Date</span><input type="date" value={date} onChange={(e) => e.target.value && setDate(e.target.value)} /></label>
          {latest && (
            <div className="admin-quick">
              <button type="button" onClick={() => setDate(latest)}>Latest day</button>
              <button type="button" onClick={() => setDate(addDays(latest, 1))}>Next day</button>
            </div>
          )}
        </div>
      </div>
      {!col && <div className="admin-msg info">There is no column for {date} yet. It will be created when you save.</div>}

      <div className="admin-grid">
        {rows.map((r) => (
          <label key={r.label} className={`admin-entry${changed.includes(r) ? ' changed' : ''}`}>
            <span className="admin-entry-label">{r.label}<small>{r.kind}</small></span>
            <input inputMode="decimal" placeholder="—" value={inputs[r.label] ?? ''}
                   onChange={(e) => setInputs((p) => ({ ...p, [r.label]: e.target.value }))} />
            <em>{col?.unit || 'Kg'}</em>
          </label>
        ))}
      </div>
      <div className="admin-footer">
        <span>{changed.length} change(s) ready</span>
        <button className="admin-btn" onClick={() => void submit()} disabled={saving || changed.length === 0}>{saving ? 'Saving…' : `Save ${changed.length || ''} change(s)`}</button>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ Edit any cell */
function CellEditor({ table, saving, onSave }: { table: SheetTable; saving: boolean; onSave: (b: Json) => Promise<boolean> }) {
  const [rowLabel, setRowLabel] = useState(table.rows[0]?.label ?? '');
  const [colIndex, setColIndex] = useState<number>(table.columns.find((c) => c.kind !== 'day')?.index ?? 0);
  const [value, setValue] = useState('');
  const [queue, setQueue] = useState<Pending[]>([]);
  const [localError, setLocalError] = useState('');

  const col: TableColumn | undefined = table.columns.find((c) => c.index === colIndex);
  const row = table.rows.find((r) => r.label === rowLabel);
  const current = row && col ? row.cells[col.index] : null;
  const textMode = typeof current?.v === 'string' || /remark/i.test(col?.label ?? '');
  const isPercent = col?.unit === '%';

  function add() {
    setLocalError('');
    if (!row || !col) return;
    const column = col.kind === 'day' ? col.date : col.label;
    if (!column) { setLocalError('This column has no header text, so it cannot be addressed.'); return; }
    const cell: Json = { row: row.label, column, ...(col.kind !== 'day' ? { group: col.group } : {}), ...(col.unit ? { unit: col.unit } : {}) };
    if (value.trim() === '') cell.clear = true;
    else if (textMode) cell.text = value;
    else {
      const n = parseNumber(value);
      if (n === null) { setLocalError('Enter a valid number.'); return; }
      cell.value = isPercent ? n / 100 : n;          // percent columns are stored as ratios (85 -> 0.85)
    }
    const label = `${row.label} → ${col.kind === 'day' ? col.date : col.short || col.label}: ${value.trim() === '' ? '(clear)' : value}${isPercent && value ? '%' : ''}`;
    setQueue((q) => [...q.filter((p) => !(p.cell.row === cell.row && p.cell.column === cell.column && p.cell.group === cell.group && p.cell.unit === cell.unit)), { id: Date.now(), label, cell }]);
    setValue('');
  }

  async function saveAll() {
    if (await onSave({ cells: queue.map((p) => p.cell) })) setQueue([]);
  }

  return (
    <section className="admin-card">
      <div className="admin-card-head"><div><h2>Edit any cell</h2><p>Pick a row and a column, enter the new value, add it to the list, then save everything together.</p></div></div>
      <div className="admin-form">
        <label className="admin-field"><span>Row</span>
          <select value={rowLabel} onChange={(e) => setRowLabel(e.target.value)}>
            {table.rows.map((r) => <option key={r.label} value={r.label}>{r.label} ({r.kind})</option>)}
          </select>
        </label>
        <label className="admin-field"><span>Column</span>
          <select value={colIndex} onChange={(e) => setColIndex(Number(e.target.value))}>
            {table.groups.map((g) => (
              <optgroup key={g.id} label={g.label}>
                {g.columns.map((i) => { const c = table.columns[i]; return <option key={i} value={c.index}>{c.kind === 'day' ? c.date : c.short || c.label}{c.unit ? ` (${c.unit})` : ''}</option>; })}
              </optgroup>
            ))}
          </select>
        </label>
        <label className="admin-field"><span>{textMode ? 'New text' : isPercent ? 'New value (in %, e.g. 85)' : 'New value'}</span>
          <input value={value} onChange={(e) => setValue(e.target.value)} placeholder={`Current: ${current?.t ?? '—'}`} />
        </label>
        <button className="admin-btn" type="button" onClick={add}>Add to list</button>
      </div>
      {localError && <div className="admin-msg error">{localError}</div>}
      {queue.length > 0 && (
        <>
          <ul className="admin-queue">
            {queue.map((p) => <li key={p.id}><span>{p.label}</span><button onClick={() => setQueue((q) => q.filter((x) => x.id !== p.id))} aria-label="Remove">✕</button></li>)}
          </ul>
          <div className="admin-footer"><span>{queue.length} change(s) ready</span>
            <button className="admin-btn" onClick={() => void saveAll()} disabled={saving}>{saving ? 'Saving…' : 'Save all'}</button></div>
        </>
      )}
    </section>
  );
}

/* ------------------------------------------------------------------ Add row / column */
function StructureEditor({ table, saving, onSave, setError }: {
  table: SheetTable; saving: boolean; onSave: (b: Json) => Promise<boolean>; setError: (m: string) => void;
}) {
  const [rowLabel, setRowLabel] = useState('');
  const [rowKind, setRowKind] = useState('item');
  const [group, setGroup] = useState(table.groups.find((g) => g.id === 'fg')?.id ?? table.groups[0]?.id ?? '');
  const [colLabel, setColLabel] = useState('');
  const [unit, setUnit] = useState('Kg');
  const [newDate, setNewDate] = useState('');

  const clash = (l: string) => table.rows.some((r) => r.label.toLowerCase() === l.trim().toLowerCase());

  return (
    <div className="admin-two">
      <section className="admin-card">
        <h2>Add a row</h2>
        <p>A new region, blend or channel. It is placed after the last row of its kind. Then enter its values in Daily entry.</p>
        <label className="admin-field"><span>Name</span><input value={rowLabel} onChange={(e) => setRowLabel(e.target.value)} placeholder="e.g. Peshawar" /></label>
        <label className="admin-field"><span>Type</span>
          <select value={rowKind} onChange={(e) => setRowKind(e.target.value)}>
            {EDITABLE_ROW_KINDS.map((k) => <option key={k} value={k}>{ROW_KIND_LABELS[k]}</option>)}
          </select>
        </label>
        <button className="admin-btn" disabled={saving || !rowLabel.trim()} onClick={async () => {
          if (clash(rowLabel)) { setError(`A row named "${rowLabel.trim()}" already exists.`); return; }
          if (await onSave({ rows: [{ label: rowLabel.trim(), kind: rowKind }] })) setRowLabel('');
        }}>Add row</button>
      </section>

      <section className="admin-card">
        <h2>Add a column</h2>
        <p>A new metric (any header you like) shows up in the Detailed report. Fill its values with &quot;Edit any cell&quot;.</p>
        <label className="admin-field"><span>Group</span>
          <select value={group} onChange={(e) => setGroup(e.target.value)}>
            {table.groups.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}
          </select>
        </label>
        <label className="admin-field"><span>Header</span><input value={colLabel} onChange={(e) => setColLabel(e.target.value)} placeholder="e.g. Open Orders" /></label>
        <label className="admin-field"><span>Unit</span>
          <select value={unit} onChange={(e) => setUnit(e.target.value)}><option value="Kg">Kg</option><option value="%">% (percent)</option><option value="">none</option></select>
        </label>
        <button className="admin-btn" disabled={saving || !colLabel.trim() || !group} onClick={async () => {
          if (await onSave({ columns: [{ kind: 'metric', group, label: colLabel.trim(), ...(unit ? { unit } : {}) }] })) setColLabel('');
        }}>Add column</button>

        <hr />
        <h3>Add an empty day</h3>
        <label className="admin-field"><span>Date</span><input type="date" value={newDate} onChange={(e) => setNewDate(e.target.value)} /></label>
        <button className="admin-btn ghost" disabled={saving || !newDate} onClick={async () => {
          if (await onSave({ columns: [{ kind: 'day', date: newDate }] })) setNewDate('');
        }}>Add day column</button>
      </section>
    </div>
  );
}
