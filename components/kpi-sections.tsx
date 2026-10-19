import { ArrowUpRight, Boxes, CalendarRange, Target, type LucideIcon } from 'lucide-react';
import type { Kpi, KpiSection } from '@/lib/dashboard-model';

const ICONS: Record<string, LucideIcon> = {
  'Month at a glance': Target,
  'Stock & warehouse': Boxes,
  'Year to date': CalendarRange,
  'Including export': ArrowUpRight,
};

function KpiCard({ k, Icon }: { k: Kpi; Icon: LucideIcon }) {
  return (
    <article className="stat-card">
      <div className="stat-top"><span>{k.title}</span><span className={`stat-icon ${k.tone}`}><Icon size={19} /></span></div>
      <div className={`stat-value ${k.negative ? 'is-neg' : ''}`}>{k.value}{k.unit && <small> {k.unit}</small>}</div>
      <div className="stat-bottom">
        <span className="stat-note">{k.note ?? ' '}</span>
        {k.pill && <span className={`trend-pill ${k.negative ? '' : ''}`}>{k.pill}</span>}
      </div>
    </article>
  );
}

export default function KpiSections({ sections }: { sections: KpiSection[] }) {
  return (
    <>
      {sections.map((s) => {
        const Icon = ICONS[s.title] ?? Target;
        return (
          <section key={s.title} className="kpi-section">
            <div className="section-title"><h3>{s.title}</h3>{s.subtitle && <span>{s.subtitle}</span>}</div>
            <div className="stats-grid">
              {s.cards.map((k) => <KpiCard key={k.title} k={k} Icon={Icon} />)}
            </div>
          </section>
        );
      })}
    </>
  );
}
