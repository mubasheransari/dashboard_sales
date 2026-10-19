'use client';

import { useState, type ReactNode } from 'react';
import type { SheetTable } from '@/lib/types';
import { cellAt, currentMonthColumn, findColumn, num, rowsOfKind } from '@/lib/dashboard-model';

const PREVIEW = 8;

export default function PerformanceList({ table, title, subtitle, icon }: { table: SheetTable | undefined; title: string; subtitle: string; icon: ReactNode }) {
  const [showAll, setShowAll] = useState(false);
  if (!table) return null;
  const mtd = currentMonthColumn(table);
  const target = findColumn(table, /^RSF Target/i, { group: 'month' });
  const ach = findColumn(table, /^Achievement/i);

  const items = rowsOfKind(table, 'item')
    .map((row) => ({ row, mtd: num(cellAt(row, mtd)), target: num(cellAt(row, target)), ach: cellAt(row, ach) }))
    .sort((a, b) => b.mtd - a.mtd);
  const maxMtd = Math.max(1, ...items.map((i) => i.mtd));
  const shown = showAll ? items : items.slice(0, PREVIEW);

  return (
    <section className="panel region-panel">
      <div className="panel-heading">
        <div><h2>{title}</h2><p>{subtitle}</p></div>
        <span className="round-icon">{icon}</span>
      </div>
      <div className="region-list">
        {shown.map((it, i) => {
          const pct = it.target > 0 ? Math.min(100, (it.mtd / it.target) * 100) : (it.mtd / maxMtd) * 100;
          return (
            <div className="region-row" key={it.row.label}>
              <div className="region-meta">
                <span className="region-rank">{String(i + 1).padStart(2, '0')}</span>
                <span className="region-name">{it.row.label}</span>
                <b>{cellAt(it.row, mtd)?.t ?? '0'} <small>kg</small></b>
              </div>
              <div className="progress-track"><div className={`progress-fill fill-${i % 4}`} style={{ width: `${Math.max(1.5, pct)}%` }} /></div>
              <div className="region-sub">
                {target && cellAt(it.row, target) ? <span>Target {cellAt(it.row, target)?.t}</span> : <span />}
                {ach && it.ach ? <span>{it.ach.t} achieved</span> : null}
              </div>
            </div>
          );
        })}
      </div>
      {items.length > PREVIEW && (
        <button className="show-more" onClick={() => setShowAll((v) => !v)}>
          {showAll ? 'Show top 8 only' : `Show all ${items.length}`}
        </button>
      )}
    </section>
  );
}
