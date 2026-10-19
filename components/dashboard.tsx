'use client';

import { useEffect, useMemo, useState } from 'react';
import {
  Area, AreaChart, Bar, CartesianGrid, Cell, ComposedChart,
  Line, ResponsiveContainer, Tooltip, XAxis, YAxis,
} from 'recharts';
import {
  Activity, AlertTriangle, CalendarDays, ChevronDown, Clock3,
  Filter, Layers, Leaf, MapPin, RefreshCw,
} from 'lucide-react';
import type { DashboardData } from '@/lib/types';
import {
  buildKpiSections, dailySeries, monthlySeries, seriesOptions, tableById,
} from '@/lib/dashboard-model';
import KpiSections from './kpi-sections';
import PerformanceList from './performance-list';
import DetailTable from './detail-table';

/* Optional: put your logo file in /public (e.g. /public/logo.png) and set this to '/logo.png'.
   Leave empty to show the text wordmark. */
const LOGO_SRC = '';

/* Mezan Tea red + white palette (keep in sync with app/globals.css) */
const C = {
  red: '#d4141c',
  redDark: '#a30d14',
  redMid: '#e8545a',
  redLight: '#f4a3a6',
  grid: '#f8ecec',
  axis: '#a58a8c',
  line: '#f1dcdc',
};

const fmt = new Intl.NumberFormat('en-PK', { maximumFractionDigits: 0 });
const compact = (v: number) => v >= 1000000 ? `${(v / 1000000).toFixed(1)}M` : v >= 1000 ? `${(v / 1000).toFixed(v >= 10000 ? 0 : 1)}k` : fmt.format(v);
const dateLabel = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('en-PK', { day: '2-digit', month: 'short' });
const longDate = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' });

const tooltipStyle = { border: `1px solid ${C.line}`, borderRadius: 12, boxShadow: '0 8px 24px #a30d1418', fontFamily: 'DM Sans, sans-serif' };
const tick = { fill: C.axis, fontSize: 12 };

export default function Dashboard() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [period, setPeriod] = useState('This month');
  const [chartMode, setChartMode] = useState<'daily' | 'monthly'>('daily');
  const [seriesKey, setSeriesKey] = useState('');
  const [lastUpdated, setLastUpdated] = useState('');

  const loadData = async (manual = false) => {
    if (manual) setRefreshing(true); else setLoading(true);
    try {
      const res = await fetch('/api/dashboard', { cache: 'no-store' });
      if (!res.ok) throw new Error('Could not load dashboard data');
      const next = await res.json() as DashboardData;
      setData(next);
      setLastUpdated(new Date().toLocaleTimeString('en-PK', { hour: '2-digit', minute: '2-digit' }));
    } catch (e) { console.error(e); }
    finally { setLoading(false); setRefreshing(false); }
  };
  useEffect(() => { void loadData(); }, []);

  const regionTable = tableById(data, 'region') ?? data?.tables[0];
  const blendTable = tableById(data, 'blend');

  // Which row drives the trend chart (default: region-wise TOTAL)
  const options = useMemo(() => seriesOptions(data), [data]);
  const selected = options.find((o) => o.key === seriesKey)
    ?? options.find((o) => o.tableId === regionTable?.id && o.row.kind === 'total')
    ?? options[0];
  const selTable = tableById(data, selected?.tableId ?? '');

  const dailyAll = useMemo(() => dailySeries(selTable, selected?.row), [selTable, selected]);
  const monthly = useMemo(() => monthlySeries(selTable, selected?.row), [selTable, selected]);
  const filteredDaily = useMemo(() => {
    if (period === 'Last 7 days') return dailyAll.slice(-7);
    if (period === 'Last 30 days') return dailyAll.slice(-30);
    return dailyAll;
  }, [dailyAll, period]);

  const kpiSections = useMemo(() => buildKpiSections(regionTable), [regionTable]);

  const visibleDailySales = filteredDaily.reduce((sum, d) => sum + d.sales, 0);
  const activeDays = filteredDaily.filter((d) => d.sales > 0).length;
  const average = activeDays ? visibleDailySales / activeDays : 0;
  const bestDay = filteredDaily.reduce((best, d) => d.sales > best.sales ? d : best, { date: '', sales: 0 });
  const monthlyTotal = monthly.reduce((sum, m) => sum + m.sales, 0);
  const isFallback = !!data?.source.startsWith('Sample data (');

  const groups = useMemo(() => {
    const g = new Map<string, typeof options>();
    options.forEach((o) => g.set(o.group, [...(g.get(o.group) ?? []), o]));
    return [...g.entries()];
  }, [options]);

  return (
    <main className="app-shell">
      <header className="hero">
        <div className="hero-inner">
          <div className="topbar">
            <div className="brand">
              {LOGO_SRC
                // eslint-disable-next-line @next/next/no-img-element
                ? <img src={LOGO_SRC} alt="Mezan Tea" />
                : <>
                    <span className="brand-mark"><Leaf size={22} /></span>
                    <span className="brand-name">Mezan Tea<small>Sales dashboard</small></span>
                  </>}
            </div>
            <div className="top-actions">
              <div className="live-status"><span className="status-light" /> Live dashboard</div>
              <button className="icon-button" aria-label="Refresh dashboard" onClick={() => void loadData(true)} disabled={refreshing}>
                <RefreshCw size={17} className={refreshing ? 'spin' : ''} />
              </button>
            </div>
          </div>

          <div className="hero-body">
            <div>
              <h1>Sales overview</h1>
              <p>Track daily performance, monthly momentum, regions, blends, stock cover and year-to-date results — straight from your Google Sheet.</p>
              {data?.reportDate && <div className="report-chip"><CalendarDays size={15} /> Report date · {longDate(data.reportDate)}</div>}
            </div>
            <button className="primary-button" onClick={() => void loadData(true)} disabled={refreshing}>
              <RefreshCw size={16} className={refreshing ? 'spin' : ''} /> Refresh data
            </button>
          </div>
        </div>
      </header>

      <div className="page-content">
        <div className="filter-bar">
          <div className="filter-intro"><Filter size={16} /><span>View filters</span></div>
          <label className="select-wrap">
            <CalendarDays size={15} />
            <select value={period} onChange={(e) => setPeriod(e.target.value)} aria-label="Period">
              <option>This month</option><option>Last 7 days</option><option>Last 30 days</option>
            </select>
            <ChevronDown size={14} />
          </label>
          <label className="select-wrap">
            <Layers size={15} />
            <select value={selected?.key ?? ''} onChange={(e) => setSeriesKey(e.target.value)} aria-label="Chart shows" disabled={!options.length}>
              {groups.map(([g, list]) => (
                <optgroup key={g} label={g}>{list.map((o) => <option key={o.key} value={o.key}>{o.label}</option>)}</optgroup>
              ))}
            </select>
            <ChevronDown size={14} />
          </label>
          <div className="filter-spacer" />
          <div className="updated"><Clock3 size={14} /><span>Updated {lastUpdated || '—'}</span></div>
        </div>

        {isFallback && (
          <div className="notice" role="status">
            <AlertTriangle size={18} />
            <span>Google Sheets could not be read, so sample data is showing. Check the tab name, the sheet sharing and the environment variables.</span>
          </div>
        )}

        {loading && !data ? (
          <div className="panel loading-panel">Loading your sales data…</div>
        ) : (
          <>
            <KpiSections sections={kpiSections} />

            <section className="panel trend-panel">
              <div className="panel-heading">
                <div>
                  <h2>Daily and monthly trends</h2>
                  <p>Showing <b>{selected?.label ?? '—'}</b> · follow the sales curve and compare months.</p>
                </div>
                <div className="segmented">
                  <button className={chartMode === 'daily' ? 'selected' : ''} onClick={() => setChartMode('daily')}>Daily sales</button>
                  <button className={chartMode === 'monthly' ? 'selected' : ''} onClick={() => setChartMode('monthly')}>Monthly trend</button>
                </div>
              </div>

              <div className="chart-summary">
                <div>
                  <span className="summary-label">{chartMode === 'daily' ? 'Sales in selected period' : 'Total across months shown'}</span>
                  <strong>{fmt.format(chartMode === 'daily' ? visibleDailySales : monthlyTotal)}<small> kg</small></strong>
                </div>
                {chartMode === 'daily' && (
                  <div className="summary-chips">
                    <span><b>{fmt.format(average)}</b> kg avg per active day</span>
                    <span><b>{fmt.format(bestDay.sales)}</b> kg best day{bestDay.date ? ` · ${dateLabel(bestDay.date)}` : ''}</span>
                    <span><b>{activeDays}</b> active days</span>
                  </div>
                )}
              </div>

              <div className="chart-wrap">
                {chartMode === 'daily' ? (
                  <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={filteredDaily} margin={{ top: 14, right: 10, left: 0, bottom: 0 }}>
                      <defs>
                        <linearGradient id="salesFill" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="0%" stopColor={C.red} stopOpacity={0.32} />
                          <stop offset="100%" stopColor={C.red} stopOpacity={0.02} />
                        </linearGradient>
                      </defs>
                      <CartesianGrid stroke={C.grid} vertical={false} />
                      <XAxis dataKey="date" tickFormatter={dateLabel} axisLine={false} tickLine={false} tick={tick} dy={12} />
                      <YAxis tickFormatter={compact} axisLine={false} tickLine={false} tick={tick} width={48} />
                      <Tooltip
                        contentStyle={tooltipStyle}
                        labelFormatter={(v) => new Date(`${v}T12:00:00`).toLocaleDateString('en-PK', { weekday: 'short', day: 'numeric', month: 'short' })}
                        formatter={(v) => [`${fmt.format(Number(v))} kg`, 'Sales']}
                      />
                      <Area type="monotone" dataKey="sales" stroke={C.red} strokeWidth={3.2} fill="url(#salesFill)" activeDot={{ r: 5, fill: C.redDark, stroke: '#fff', strokeWidth: 3 }} />
                    </AreaChart>
                  </ResponsiveContainer>
                ) : (
                  <ResponsiveContainer width="100%" height="100%">
                    <ComposedChart data={monthly} margin={{ top: 14, right: 10, left: 0, bottom: 0 }}>
                      <CartesianGrid stroke={C.grid} vertical={false} />
                      <XAxis dataKey="label" axisLine={false} tickLine={false} tick={tick} dy={12} />
                      <YAxis tickFormatter={compact} axisLine={false} tickLine={false} tick={tick} width={48} />
                      <Tooltip contentStyle={tooltipStyle} formatter={(v) => [`${fmt.format(Number(v))} kg`, 'Sales']} />
                      <Bar dataKey="sales" barSize={44} radius={[8, 8, 0, 0]}>
                        {monthly.map((entry) => <Cell key={entry.month} fill={entry.isCurrent ? C.red : C.redLight} />)}
                      </Bar>
                      <Line dataKey="sales" stroke={C.redDark} strokeWidth={2.2} dot={{ r: 4, fill: C.redDark, stroke: '#fff', strokeWidth: 2 }} />
                    </ComposedChart>
                  </ResponsiveContainer>
                )}
              </div>

              <div className="chart-footer">
                <span><span className="footer-dot" /> {data?.source ?? 'Sales data'}</span>
                <span>Units: kg · Values reflect the sheet</span>
              </div>
            </section>

            <div className="lower-grid">
              <PerformanceList table={regionTable} title="Regional performance" subtitle={`${regionTable ? 'MTD sales against RSF target, by region.' : ''}`} icon={<MapPin size={18} />} />
              <PerformanceList table={blendTable} title="Blend performance" subtitle="MTD sales against RSF target, by blend." icon={<Activity size={18} />} />
            </div>

            {data && <DetailTable tables={data.tables} />}
          </>
        )}
      </div>

      <footer className="site-footer">
        <div className="footer-inner">
          <div>
            <div className="footer-brand"><span className="brand-mark"><Leaf size={18} /></span>Mezan Tea</div>
            <div>Mezan Tea Pvt Ltd. Plot No. A-22, Mauripur Road, S.I.T.E, Karachi</div>
          </div>
          <div className="footer-right">
            <div>Designed &amp; Developed by Mubasher Hasnain<br />Mezan Tea Pvt Ltd.</div>
          </div>
        </div>
      </footer>
    </main>
  );
}
