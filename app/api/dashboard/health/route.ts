import { NextResponse } from 'next/server';
import { getOrdsData, ordsAuthMode, ordsBaseUrl, ordsConfigured, ordsWriteConfigured } from '@/lib/ords';

export const runtime = 'nodejs';
export const revalidate = 0;

/**
 * Diagnostics: open /api/dashboard/health to see whether the ORDS connection works and why not.
 * Never returns secrets. Block this path at your reverse proxy if the site is public.
 */
export async function GET() {
  const info: Record<string, unknown> = {
    configured: ordsConfigured(),
    baseUrl: ordsBaseUrl() || null,
    authMode: ordsAuthMode('read'),
    writeConfigured: ordsWriteConfigured(),
    https: ordsBaseUrl().startsWith('https://'),
  };
  if (!ordsConfigured()) {
    return NextResponse.json({ ...info, ok: false, error: 'ORDS_BASE_URL is not set.' }, { status: 200 });
  }
  const started = Date.now();
  try {
    const data = await getOrdsData();
    return NextResponse.json({
      ...info,
      ok: true,
      ms: Date.now() - started,
      source: data?.source,
      reportDate: data?.reportDate,
      updatedAt: data?.updatedAt,
      tables: data?.tables.map((t) => ({ id: t.id, columns: t.columns.length, rows: t.rows.length })),
    });
  } catch (error) {
    return NextResponse.json({ ...info, ok: false, ms: Date.now() - started, error: error instanceof Error ? error.message : String(error) }, { status: 200 });
  }
}
