# Running the dashboard on your own server (not Vercel)

Requirements: Node.js 18.18+ (20 LTS recommended). The Next.js server calls Oracle ORDS itself, so the
browser never needs to reach the database server, and there are no CORS or mixed-content (HTTP/HTTPS) issues.
The Next.js server must be able to reach `http://tapex.mezangrp.com/ords` over the network.

## 1. Configure
Copy `.env.example` to `.env.production` and fill it in:
```
ORDS_BASE_URL=http://tapex.mezangrp.com/ords/<schema-alias>
ORDS_API_KEY=<READ key from oracle/06_http_api_key.sql>      # plain HTTP
# or, if you have HTTPS:  ORDS_CLIENT_ID / ORDS_CLIENT_SECRET (OAuth2)
```
`<schema-alias>`: run `SELECT pattern FROM user_ords_schemas;` in Oracle (the same alias your other APIs use).

## 2. Build and start
```bash
npm ci
npm run build
npm start            # listens on port 3000; use  npm start -- -p 8080  for another port
```
`.env.production` is read at startup. After changing it, restart the app.

## 3. Keep it running (PM2)
```bash
npm i -g pm2
pm2 start npm --name mezan-dashboard -- start
pm2 save && pm2 startup
```

## 4. Check the connection
Open `http://<your-server>:3000/api/dashboard/health`. You should see `"ok": true`, the table list and
`"source": "Oracle ORDS"`. If not, the `error` field says why (wrong alias, wrong key, module missing ...).
The dashboard footer also shows the source. Block `/api/dashboard/health` at your reverse proxy if the site is public.

## Docker (optional)
Build with `NEXT_OUTPUT=standalone npm run build`, then run `node .next/standalone/server.js`
(copy `.next/static` into `.next/standalone/.next/static`) and pass the ORDS_* variables as container env vars.

## Admin page (/admin)
Set in `.env.production` (or `.env.local` locally):
```
ADMIN_PASSWORD=<a strong password>
ADMIN_SESSION_SECRET=<output of: openssl rand -hex 24>
ORDS_WRITE_API_KEY=<the "write" key from dash_api_key>
```
Open `http://<your-server>:3000/admin`, sign in, and use:
* **Daily entry**: pick a date (a new date creates the day column automatically), type each region/blend/channel value, Save.
* **Edit any cell**: change a single value or text (Remarks, targets, stock ...); several edits are saved together.
* **Add row / column**: new region/blend/channel rows, new metric columns, empty day columns.
Totals (National, TOTAL, GRAND TOTAL, month-to-date) are recalculated by Oracle on every save. The public dashboard
shows the change on its next refresh. The write key and the password never reach the browser's JavaScript, but on plain HTTP
they cross the network unencrypted: use the admin page only on a trusted network/VPN, or put HTTPS in front of the app.
