'use client';

import { useMemo, useState } from 'react';
import { Columns3, Table2 } from 'lucide-react';
import type { SheetTable, TableColumn, TableRow } from '@/lib/types';

const TAB_LABELS: Record<string, string> = { region: 'Region-wise', blend: 'Blend-wise' };
const FIRST_COL_LABEL: Record<string, string> = { region: 'Region', blend: 'Blend' };

const dayLabel = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' });
const weekday = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('en-GB', { weekday: 'short' });

/** Columns whose negative values the original sheet highlights (conditional formatting). */
const FLAG_NEGATIVE = /^(remaining|achievement)/i;

function cellClass(col: TableColumn, row: TableRow): string {
  const cell = row.cells[col.index];
  const cls: string[] = [];
  if (!cell) return 'empty';
  if (typeof cell.v === 'string') cls.push('text');
  else {
    cls.push('num');
    if (typeof cell.v === 'number' && cell.v < 0) cls.push('neg');
    if (typeof cell.v === 'number' && cell.v < 0 && FLAG_NEGATIVE.test(col.label)) cls.push('neg-flag');
    if (cell.t === '—') cls.push('dash');
  }
  return cls.join(' ');
}

export default function DetailTable({ tables }: { tables: SheetTable[] }) {
  const [activeId, setActiveId] = useState(tables[0]?.id ?? '');
  const [hidden, setHidden] = useState<Record<string, string[]>>({});
  const table = tables.find((t) => t.id === activeId) ?? tables[0];

  const hiddenGroups = useMemo(() => new Set(hidden[table?.id ?? ''] ?? []), [hidden, table]);
  if (!table) return null;

  const toggle = (gid: string) =>
    setHidden((h) => {
      const cur = new Set(h[table.id] ?? []);
      if (cur.has(gid)) cur.delete(gid); else cur.add(gid);
      return { ...h, [table.id]: [...cur] };
    });

  const visibleGroups = table.groups.filter((g) => !hiddenGroups.has(g.id));
  const visibleCols = visibleGroups.flatMap((g) => g.columns.map((i) => table.columns[i]));

  // soft heat for the daily cells (relative to each row's best day)
  const dailyMax = new Map<TableRow, number>();
  for (const row of table.rows) {
    let max = 0;
    for (const c of table.columns) if (c.kind === 'day') { const v = row.cells[c.index]?.v; if (typeof v === 'number' && v > max) max = v; }
    dailyMax.set(row, max);
  }

  return (
    <section className="panel report-panel">
      <div className="panel-heading">
        <div>
          <h2>Detailed report</h2>
          <p>Every column and row from the sheet — {table.title}.</p>
        </div>
        <div className="segmented">
          {tables.map((t) => (
            <button key={t.id} className={t.id === table.id ? 'selected' : ''} onClick={() => setActiveId(t.id)}>
              {TAB_LABELS[t.id] ?? t.title}
            </button>
          ))}
        </div>
      </div>

      <div className="chip-row" aria-label="Column groups">
        <span className="chip-label"><Columns3 size={15} /> Column groups</span>
        {table.groups.map((g) => (
          <button key={g.id} className={`chip ${hiddenGroups.has(g.id) ? 'off' : 'on'}`} onClick={() => toggle(g.id)} aria-pressed={!hiddenGroups.has(g.id)}>
            {g.label} <em>{g.columns.length}</em>
          </button>
        ))}
      </div>

      <div className="report-scroll">
        <table className="report">
          <thead>
            <tr className="g-row">
              <th className="sticky-col" rowSpan={2}>{FIRST_COL_LABEL[table.id] ?? 'Item'}</th>
              {visibleGroups.map((g, i) => (
                <th key={g.id} colSpan={g.columns.length} className={`g-${i % 5}`}><span className="g-label">{g.label}</span></th>
              ))}
            </tr>
            <tr className="c-row">
              {visibleCols.map((c) => (
                <th key={c.index} title={c.label} className={c.group === 'daily' ? 'day-head' : ''}>
                  {c.kind === 'day' && c.date ? (<>{dayLabel(c.date)}<small>{weekday(c.date)}</small></>) : (<>{c.short}{c.unit && <small>{c.unit}</small>}</>)}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {table.rows.map((row, ri) => (
              <tr key={`${row.label}-${ri}`} className={`r-${row.kind}`}>
                <th className="sticky-col" scope="row">{row.kind === 'detail' && <span className="indent">↳</span>}{row.label}</th>
                {visibleCols.map((c) => {
                  const cell = row.cells[c.index];
                  let style: React.CSSProperties | undefined;
                  if (c.kind === 'day' && cell && typeof cell.v === 'number' && cell.v > 0 && ['item', 'channel', 'subtotal', 'total'].includes(row.kind)) {
                    const max = dailyMax.get(row) || 1;
                    style = { background: `rgba(212, 20, 28, ${0.04 + (cell.v / max) * 0.22})` };
                  }
                  return <td key={c.index} className={cellClass(c, row)} style={style}>{cell?.t ?? ''}</td>;
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="table-foot">
        <span><Table2 size={13} /> {table.rows.length} rows · {visibleCols.length} of {table.columns.length} columns shown</span>
        <span>Scroll sideways for more →</span>
      </div>
    </section>
  );
}
