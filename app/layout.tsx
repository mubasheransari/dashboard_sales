import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Mezan Tea | Sales Dashboard',
  description: 'Mezan Tea daily sales performance and monthly sales trends dashboard.',
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
