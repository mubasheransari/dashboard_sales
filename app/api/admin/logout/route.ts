import { NextResponse } from 'next/server';
import { ADMIN_COOKIE, sessionCookieOptions } from '@/lib/admin-auth';

export const runtime = 'nodejs';

export async function POST(req: Request) {
  const res = NextResponse.json({ ok: true });
  res.cookies.set(ADMIN_COOKIE, '', { ...sessionCookieOptions(req), maxAge: 0 });
  return res;
}
