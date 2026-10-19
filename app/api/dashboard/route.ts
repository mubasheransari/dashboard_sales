import { NextResponse } from 'next/server';
import { google } from 'googleapis';
import { sampleData } from '@/lib/data';
import { parseWorkbookRows } from '@/lib/parse-workbook';
import { getOrdsData, ordsConfigured } from '@/lib/ords';
import type { DashboardData } from '@/lib/types';

export const runtime = 'nodejs';
export const revalidate = 0;

/**
 * Reads the Dashboard workbook straight from Google Sheets, in its original layout,
 * and returns every table / row / column found in it.
 *
 * Env vars:
 *   GOOGLE_SHEETS_ID               spreadsheet id (from the sheet URL)
 *   GOOGLE_SERVICE_ACCOUNT_EMAIL   service account email (sheet shared with it as Viewer)
 *   GOOGLE_PRIVATE_KEY             service account private key
 *   GOOGLE_SHEET_TAB               (optional) tab name, e.g. "13 Oct". Empty = first tab.
 */
async function getLiveData(): Promise<DashboardData | null> {
  const spreadsheetId = process.env.GOOGLE_SHEETS_ID;
  const email = process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL;
  const rawKey = process.env.GOOGLE_PRIVATE_KEY;
  if (!spreadsheetId || !email || !rawKey) return null; // not configured -> sample data

  const auth = new google.auth.JWT({
    email,
    key: rawKey.replace(/\\n/g, '\n'),
    scopes: ['https://www.googleapis.com/auth/spreadsheets.readonly'],
  });
  const sheets = google.sheets({ version: 'v4', auth });

  // Pick the tab: the one named in GOOGLE_SHEET_TAB, otherwise the first tab.
  const wanted = process.env.GOOGLE_SHEET_TAB?.trim();
  const meta = await sheets.spreadsheets.get({ spreadsheetId, fields: 'sheets.properties.title' });
  const titles = (meta.data.sheets ?? []).map((s) => s.properties?.title).filter((t): t is string => !!t);
  const tab = wanted || titles[0];
  if (!tab) throw new Error('The spreadsheet has no tabs.');
  if (wanted && !titles.includes(wanted)) {
    throw new Error(`Tab "${wanted}" not found. Available tabs: ${titles.join(', ')}`);
  }

  // The whole tab, twice: raw numbers/date serials (for charts + logic) and the text exactly
  // as the sheet displays it (so 155%, 2,767, "-" etc. look the same as in the sheet).
  const range = `'${tab.replace(/'/g, "''")}'`;
  const [rawRes, fmtRes] = await Promise.all([
    sheets.spreadsheets.values.get({ spreadsheetId, range, valueRenderOption: 'UNFORMATTED_VALUE', dateTimeRenderOption: 'SERIAL_NUMBER' }),
    sheets.spreadsheets.values.get({ spreadsheetId, range, valueRenderOption: 'FORMATTED_VALUE' }),
  ]);

  return parseWorkbookRows(rawRes.data.values ?? [], fmtRes.data.values ?? [], `Google Sheets · ${tab}`);
}

export async function GET() {
  const headers = { 'Cache-Control': 'no-store, max-age=0' };
  let failure = '';

  // 1) Oracle ORDS (preferred)
  try {
    const ords = await getOrdsData();
    if (ords) return NextResponse.json(ords, { headers });
  } catch (error) {
    failure = 'Oracle ORDS';
    console.error('[dashboard] Oracle ORDS fetch failed:', error);
  }

  // 2) Google Sheets (only if configured)
  try {
    const live = await getLiveData();
    if (live) return NextResponse.json(live, { headers });
  } catch (error) {
    failure = failure || 'Google Sheets';
    console.error('[dashboard] Google Sheets fetch failed:', error);
  }

  // 3) Built-in sample data. The banner names whichever live source was configured but failed.
  const label = failure || (ordsConfigured() ? 'Oracle ORDS' : '');
  return NextResponse.json(
    label ? { ...sampleData, source: `Sample data (${label} connection unavailable)` } : sampleData,
    { status: 200, headers },
  );
}
