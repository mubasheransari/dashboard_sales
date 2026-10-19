import crypto from 'node:crypto';
import { cookies } from 'next/headers';

/**
 * Minimal admin authentication (single shared password), fail-closed:
 *   ADMIN_PASSWORD         the admin password
 *   ADMIN_SESSION_SECRET   random string, 16+ chars, used to sign the session cookie
 * The session is an HttpOnly, SameSite=Strict cookie holding "<expiry>.<HMAC>".
 */
export const ADMIN_COOKIE = 'mezan_admin';
const SESSION_MS = 8 * 60 * 60 * 1000; // 8 hours

const secret = () => process.env.ADMIN_SESSION_SECRET?.trim() ?? '';
export const adminEnabled = () => !!process.env.ADMIN_PASSWORD?.trim() && secret().length >= 16;

const sign = (payload: string) => crypto.createHmac('sha256', secret()).update(payload).digest('base64url');
const sha = (v: string) => crypto.createHash('sha256').update(v).digest();

export function checkPassword(input: string): boolean {
  const expected = process.env.ADMIN_PASSWORD?.trim() ?? '';
  if (!expected) return false;
  return crypto.timingSafeEqual(sha(input), sha(expected));
}

export function createSessionToken(): string {
  const exp = String(Date.now() + SESSION_MS);
  return `${exp}.${sign(exp)}`;
}

export function verifySessionToken(token?: string | null): boolean {
  if (!token || !adminEnabled()) return false;
  const [exp, sig] = token.split('.');
  if (!exp || !sig || Number(exp) < Date.now()) return false;
  const good = sign(exp);
  return sig.length === good.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(good));
}

export async function isAdminAuthed(): Promise<boolean> {
  return verifySessionToken((await cookies()).get(ADMIN_COOKIE)?.value);
}

export const sessionCookieOptions = (req: Request) => ({
  httpOnly: true,
  sameSite: 'strict' as const,
  path: '/',
  maxAge: SESSION_MS / 1000,
  // The Secure flag is only possible over HTTPS; your host may be plain HTTP.
  secure: req.headers.get('x-forwarded-proto') === 'https' || new URL(req.url).protocol === 'https:',
});

/** Browsers always send Origin on cross-site POSTs; reject when it does not match this host (CSRF defence). */
export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get('origin');
  if (!origin) return true; // non-browser client (curl); the session cookie is still required
  try {
    return new URL(origin).host === (req.headers.get('x-forwarded-host') ?? req.headers.get('host'));
  } catch {
    return false;
  }
}

// ---- login throttling: 8 failed attempts per IP per 10 minutes (in memory) ----
const attempts = new Map<string, { n: number; reset: number }>();
export function loginAllowed(ip: string): boolean {
  const a = attempts.get(ip);
  return !a || a.reset < Date.now() || a.n < 8;
}
export function loginFailed(ip: string) {
  const a = attempts.get(ip);
  if (!a || a.reset < Date.now()) attempts.set(ip, { n: 1, reset: Date.now() + 10 * 60 * 1000 });
  else a.n += 1;
}
export const loginSucceeded = (ip: string) => void attempts.delete(ip);
export const clientIp = (req: Request) => req.headers.get('x-forwarded-for')?.split(',')[0].trim() || 'local';
