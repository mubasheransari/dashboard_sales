import type { NextConfig } from 'next';

// Normal servers: `npm run build && npm start` (reads .env.production at startup).
// Docker: build with NEXT_OUTPUT=standalone to get a minimal server in .next/standalone.
const nextConfig: NextConfig = {
  output: process.env.NEXT_OUTPUT === 'standalone' ? 'standalone' : undefined,
};
export default nextConfig;
