# Mezan Tea — Sales Dashboard (Next.js)

A red-and-white sales dashboard for Mezan Tea that reads your **Dashboard.xlsx** layout directly from
**Google Sheets** and shows **every table, row and column** of it.

## What the dashboard shows

| Section | Source in the sheet |
|---|---|
| **Month at a glance** | MTD sales, RSF target, remaining volume, same month last year (TOTAL row) |
| **Stock & warehouse** | FG, Transit, Total SC, FG vs RSF, WH utilised |
| **Year to date** | YTD primary sales, YTD RSF, Over/Under, Achieve % |
| **Including export** | GRAND TOTAL and Export rows |
| **Daily & monthly trends** | Daily columns + "Primary Sales MTD" month columns. Use the **chart selector** to switch the chart to any region, blend, channel or total |
| **Regional / Blend performance** | MTD vs RSF target and achievement for every region and blend |
| **Detailed report** | The complete **REGION WISE** and **BLEND WISE** tables: previous months, every day, month performance, FG/stock/warehouse, YTD, remarks, channels, TOTAL, Over last Year, Export, GRAND TOTAL and the LMT / Key AC / HORECA breakdown. Column groups can be switched on/off |

Numbers are displayed exactly as the sheet formats them (e.g. `155%`, `2,767`). Negative *Remaining Vol* and *Achievement* cells are highlighted like the sheet's conditional formatting.

## It updates itself from the sheet

Nothing is tied to a cell address. The dashboard finds things by their labels, so you can:

- add a **new day** (a new date column fills in, the report date in `B1` moves forward),
- add a **new region or blend row**,
- add a **new column** under any group,
- start a **new month** (month columns, targets and group titles are read from the headers)

and the dashboard shows it after you press **Refresh data**, with no code change.

Keep these conventions so it can find its way around:

- A table header cell contains **"… WISE"** (e.g. `G.T Primary Sales REGION WISE`, `... BLEND WISE`).
- The row **two above** the header holds the report date (cell `B1` / `B26`); the row **just above** holds group names (`FG`, `July 2026 Todate`); the row **just below** holds units (`Kg`, `%`).
- Month columns are headed `Primary Sales MTD <Month> <Year>`; daily columns hold real dates (a weekday name such as `Sunday` is fine, it is placed by position).
- Totals are labelled `National …`, `TOTAL`, `Over last Year Month`, `Export`, `GRAND TOTAL`.

## 1. Run locally

```bash
npm install
npm run dev
```

Open http://localhost:3000. With no Google settings it shows the built-in sample (`lib/sample-data.json`, taken from your Dashboard.xlsx).

## 2. Put the workbook in Google Sheets

1. Upload `Dashboard.xlsx` to Google Drive, open it, then **File → Save as Google Sheets**.
   (An `.xlsx` that is only opened in "Office editing mode" cannot be read by the API.)
2. **Fix the external-file formulas.** Some cells (the *YTD RSF* column, `BA`) use `=SUM([1]RSF!D4:G4)` which points to another Excel file called `RSF`. Google Sheets cannot follow that link, so those cells become errors (`#REF!`) and show as "—" on the dashboard, and the Over/Under and Achieve columns that depend on them break too. Fix once: in Excel, select those cells, **Copy → Paste Special → Values**, then upload; or bring the RSF sheet into the same Google Sheet and point the formulas at it; or use `IMPORTRANGE`.
3. Keep working in the sheet as you do today.

## 3. Connect Google Sheets privately (service account)

1. In Google Cloud Console create/select a project and enable **Google Sheets API**.
2. Create a **service account** and a **JSON key**. Keep the key private.
3. Share the Google Sheet with the service account email as **Viewer** (do not use "Anyone with the link").
4. Copy the spreadsheet ID from the URL: `https://docs.google.com/spreadsheets/d/SPREADSHEET_ID/edit`.

The connection is read-only and the key stays on the server.

## 4. Environment variables

Copy `.env.example` to `.env.local`:

```env
GOOGLE_SHEETS_ID=your_spreadsheet_id
GOOGLE_SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com
GOOGLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nYOUR_PRIVATE_KEY_CONTENT\n-----END PRIVATE KEY-----\n"
GOOGLE_SHEET_TAB=13 Oct
```

- `GOOGLE_PRIVATE_KEY`: the `private_key` from the JSON key, with newlines written as `\n` on one line.
- `GOOGLE_SHEET_TAB`: the tab to read, spelled exactly as in Google Sheets (your tabs are named by date, e.g. `13 Oct`). Leave empty to read the **first** tab, so if you keep the newest tab first you never need to change it.

Restart `npm run dev` after changing variables. If anything fails (wrong tab name, sheet not shared, layout unreadable) the dashboard falls back to the sample data and shows a notice; the real error is in the server logs (Vercel → Logs).

## 5. Deploy to Vercel

Import the project, add the four environment variables, deploy. See `VERCEL_DEPLOY.md`.

## Customising

- **Colors**: CSS variables at the top of `app/globals.css`; chart colors in `components/dashboard.tsx` (`C`).
- **Logo**: put a file in `public/` and set `LOGO_SRC` in `components/dashboard.tsx`.
- **Friendly group names**: `GROUP_LABELS` in `lib/parse-workbook.ts`.
- **Which KPI cards appear**: `buildKpiSections` in `lib/dashboard-model.ts`.

## Project layout

```
app/api/dashboard/route.ts   reads the Google Sheet (raw values + display text)
lib/parse-workbook.ts        turns the sheet into generic tables (columns, groups, rows)
lib/dashboard-model.ts       KPI cards, chart series, helpers
components/dashboard.tsx     page, filters, trend chart
components/kpi-sections.tsx  KPI cards
components/performance-list.tsx  region / blend performance bars
components/detail-table.tsx  full report table with column-group toggles
```
# sales_dashboard
# dashboard_sales
