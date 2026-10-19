import type { DashboardData } from './types';

/**
 * Oracle ORDS data source (server-side only; the browser never talks to Oracle).
 *
 *   GET {ORDS_BASE_URL}/dash/dashboard/            latest active report
 *   GET {ORDS_BASE_URL}/dash/dashboard/{reportId}  when ORDS_REPORT_ID is set
 *
 * ORDS_BASE_URL = host + "/ords" + schema alias, e.g. http://tapex.mezangrp.com/ords/<alias>
 *
 * Authentication (picked automatically):
 *   1. OAuth2 client credentials   ORDS_CLIENT_ID + ORDS_CLIENT_SECRET   (ORDS requires HTTPS for this)
 *   2. API key header              ORDS_API_KEY (+ optional ORDS_API_KEY_HEADER, default X-API-Key)
 *   3. none                        endpoint is public
 */
export type AuthMode = 'oauth' | 'apikey' | 'none';
type Scope = 'read' | 'write';

/** HTTP error from ORDS, carrying the status and the message the Oracle package produced. */
export class OrdsHttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

const env = (name: string) => process.env[name]?.trim() ?? '';

export const ordsBaseUrl = () => env('ORDS_BASE_URL').replace(/\/+$/, '');
export const ordsConfigured = () => ordsBaseUrl() !== '';

/** read  = ORDS_CLIENT_ID / ORDS_CLIENT_SECRET / ORDS_API_KEY            (dashboard GET)
 *  write = ORDS_WRITE_CLIENT_ID / ORDS_WRITE_CLIENT_SECRET / ORDS_WRITE_API_KEY   (admin POST, server only) */
const creds = (scope: Scope) =>
  scope === 'write'
    ? { id: env('ORDS_WRITE_CLIENT_ID'), secret: env('ORDS_WRITE_CLIENT_SECRET'), key: env('ORDS_WRITE_API_KEY') }
    : { id: env('ORDS_CLIENT_ID'), secret: env('ORDS_CLIENT_SECRET'), key: env('ORDS_API_KEY') };

export function ordsAuthMode(scope: Scope = 'read'): AuthMode {
  const c = creds(scope);
  if (c.id && c.secret) return 'oauth';
  if (c.key) return 'apikey';
  return 'none';
}

export const ordsWriteConfigured = () => ordsConfigured() && ordsAuthMode('write') !== 'none';

const timeoutMs = () => Number(env('ORDS_TIMEOUT_MS')) || 20_000;

// ---- OAuth token cache per scope (lives as long as the Node process) ----
const cachedTokens: Record<Scope, { value: string; expires: number } | null> = { read: null, write: null };

async function getToken(scope: Scope, force = false): Promise<string> {
  const cached = cachedTokens[scope];
  if (!force && cached && cached.expires > Date.now() + 30_000) return cached.value;
  const c = creds(scope);
  const basic = Buffer.from(`${c.id}:${c.secret}`).toString('base64');
  const res = await fetch(`${ordsBaseUrl()}/oauth/token`, {
    method: 'POST',
    headers: { Authorization: `Basic ${basic}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
    cache: 'no-store',
    signal: AbortSignal.timeout(timeoutMs()),
  });
  if (!res.ok) {
    const hint = res.status === 401 ? ' (wrong client id/secret)' : res.status === 404 ? ' (check ORDS_BASE_URL and the schema alias)' : '';
    throw new Error(`ORDS token request failed: HTTP ${res.status}${hint}. OAuth2 needs HTTPS - on plain HTTP use ORDS_API_KEY instead.`);
  }
  const json = (await res.json()) as { access_token: string; expires_in?: number };
  const token = { value: json.access_token, expires: Date.now() + (json.expires_in ?? 3600) * 1000 };
  cachedTokens[scope] = token;
  return token.value;
}

async function authHeaders(scope: Scope, forceToken = false): Promise<Record<string, string>> {
  switch (ordsAuthMode(scope)) {
    case 'oauth':
      return { Authorization: `Bearer ${await getToken(scope, forceToken)}` };
    case 'apikey':
      return { [env('ORDS_API_KEY_HEADER') || 'X-API-Key']: creds(scope).key };
    default:
      return {};
  }
}

async function request(path: string, scope: Scope, init: { method?: string; body?: string } = {}, forceToken = false) {
  return fetch(`${ordsBaseUrl()}${path}`, {
    method: init.method ?? 'GET',
    headers: {
      Accept: 'application/json',
      ...(init.body ? { 'Content-Type': 'application/json' } : {}),
      ...(await authHeaders(scope, forceToken)),
    },
    body: init.body,
    cache: 'no-store',
    signal: AbortSignal.timeout(timeoutMs()),
  });
}

/** Oracle drops empty strings / null keys, so give the UI every field it expects. */
export function normalizeDashboard(raw: DashboardData): DashboardData {
  if (!raw || !Array.isArray(raw.tables) || raw.tables.length === 0) {
    throw new Error('ORDS returned no tables. Has the data script (05_seed_current_data.sql) been run?');
  }
  return {
    ...raw,
    tables: raw.tables.map((t) => ({
      ...t,
      currentMonth: t.currentMonth ?? '',
      reportDate: t.reportDate ?? raw.reportDate ?? '',
      groups: t.groups ?? [],
      columns: (t.columns ?? []).map((c, index) => ({
        ...c,
        index: c.index ?? index,
        label: c.label ?? '',
        short: c.short ?? c.label ?? '',
        unit: c.unit ?? '',
      })),
      rows: (t.rows ?? []).map((r) => ({ ...r, cells: (r.cells ?? []).map((cell) => cell ?? null) })),
    })),
    source: raw.source || 'Oracle ORDS',
  };
}

/** Returns null when ORDS is not configured (caller falls back to other sources). Throws on failure. */
export async function getOrdsData(): Promise<DashboardData | null> {
  if (!ordsConfigured()) return null;
  const reportId = env('ORDS_REPORT_ID');
  const path = `/dash/dashboard/${reportId ? encodeURIComponent(reportId) : ''}`;

  let res = await request(path, 'read');
  if (res.status === 401 && ordsAuthMode('read') === 'oauth') res = await request(path, 'read', {}, true); // token expired / revoked
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    const hint =
      res.status === 404 ? ' - URL not found: check ORDS_BASE_URL (host/ords/<schema alias>) and that module "dash" exists'
      : res.status === 401 || res.status === 403 ? ' - not authorised: check the client credentials / API key'
      : '';
    throw new Error(`ORDS request failed: HTTP ${res.status}${hint}. ${body}`);
  }
  return normalizeDashboard((await res.json()) as DashboardData);
}

/**
 * Admin write: POST {ORDS_BASE_URL}/dash/manage/dashboard with the WRITE credentials (never sent to the browser).
 * Body shape (see oracle/ package): { table, columns?, rows?, cells? }. Throws OrdsHttpError on failure.
 */
export async function ordsPostDashboard(body: unknown): Promise<Record<string, unknown>> {
  if (!ordsConfigured()) throw new OrdsHttpError(503, 'ORDS_BASE_URL is not set.');
  if (!ordsWriteConfigured()) {
    throw new OrdsHttpError(503, 'Write credentials are not set (ORDS_WRITE_API_KEY, or ORDS_WRITE_CLIENT_ID + ORDS_WRITE_CLIENT_SECRET).');
  }
  const path = '/dash/manage/dashboard';
  const payload = JSON.stringify(body);
  let res = await request(path, 'write', { method: 'POST', body: payload });
  if (res.status === 401 && ordsAuthMode('write') === 'oauth') res = await request(path, 'write', { method: 'POST', body: payload }, true);

  const text = await res.text();
  let json: Record<string, unknown> = {};
  try { json = text ? (JSON.parse(text) as Record<string, unknown>) : {}; } catch { /* non-JSON error page */ }
  if (!res.ok) {
    const msg = typeof json.error === 'string' ? json.error : text.slice(0, 300) || `HTTP ${res.status}`;
    throw new OrdsHttpError(res.status, msg);
  }
  return json;
}
