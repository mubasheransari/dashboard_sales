import sample from './sample-data.json';
import type { DashboardData } from './types';
export const sampleData = sample as DashboardData;

export function numberValue(value: unknown): number {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  if (typeof value === 'string') {
    const cleaned = value.replace(/,/g, '').trim();
    const n = Number(cleaned);
    return cleaned && Number.isFinite(n) ? n : 0;
  }
  return 0;
}
