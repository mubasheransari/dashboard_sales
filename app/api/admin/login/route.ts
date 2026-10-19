import { NextResponse } from 'next/server';
import {
  ADMIN_COOKIE, adminEnabled, checkPassword, clientIp, createSessionToken,
  loginAllowed, loginFailed, loginSucceeded, sameOrigin, sessionCookieOptions,
} from '@/lib/admin-auth';

export const runtime = 'nodejs';

export async function POST(req: Request) {
  if (!adminEnabled()) return NextResponse.json({ error: 'Admin is not configured (set ADMIN_PASSWORD and ADMIN_SESSION_SECRET).' }, { status: 503 });
  if (!sameOrigin(req)) return NextResponse.json({ error: 'Bad origin.' }, { status: 403 });
  const ip = clientIp(req);
  if (!loginAllowed(ip)) return NextResponse.json({ error: 'Too many attempts. Try again in 10 minutes.' }, { status: 429 });

  const body = (await req.json().catch(() => ({}))) as { password?: unknown };
  if (typeof body.password !== 'string' || !checkPassword(body.password)) {
    loginFailed(ip);
    return NextResponse.json({ error: 'Wrong password.' }, { status: 401 });
  }
  loginSucceeded(ip);
  const res = NextResponse.json({ ok: true });
  res.cookies.set(ADMIN_COOKIE, createSessionToken(), sessionCookieOptions(req));
  return res;
}
