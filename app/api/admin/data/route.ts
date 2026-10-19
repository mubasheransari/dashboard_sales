import { NextResponse } from 'next/server';
import { isAdminAuthed } from '@/lib/admin-auth';
import { getOrdsData, ordsConfigured, ordsWriteConfigured } from '@/lib/ords';

export const runtime = 'nodejs';
export const revalidate = 0;

/** The live dashboard data from Oracle (what the admin edits). Admin session required. */
export async function GET() {
  if (!(await isAdminAuthed())) return NextResponse.json({ error: 'Not signed in.' }, { status: 401 });
  if (!ordsConfigured()) return NextResponse.json({ error: 'ORDS_BASE_URL is not set, so there is nothing to edit.' }, { status: 503 });
  try {
    const data = await getOrdsData();
    return NextResponse.json({ data, canWrite: ordsWriteConfigured() }, { headers: { 'Cache-Control': 'no-store' } });
  } catch (error) {
    return NextResponse.json({ error: error instanceof Error ? error.message : String(error) }, { status: 502 });
  }
}
