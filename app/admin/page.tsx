import type { Metadata } from 'next';
import { adminEnabled, isAdminAuthed } from '@/lib/admin-auth';
import AdminLogin from '@/components/admin-login';
import AdminPanel from '@/components/admin-panel';

export const dynamic = 'force-dynamic';
export const metadata: Metadata = { title: 'Admin · Mezan Sales Dashboard', robots: { index: false, follow: false } };

export default async function AdminPage() {
  if (!adminEnabled()) {
    return (
      <main className="admin-center">
        <div className="admin-card">
          <h1>Admin is not configured</h1>
          <p>Set <code>ADMIN_PASSWORD</code> and <code>ADMIN_SESSION_SECRET</code> (16+ random characters) in the server environment, then restart the app.</p>
        </div>
      </main>
    );
  }
  return (await isAdminAuthed()) ? <AdminPanel /> : <AdminLogin />;
}
