# Vercel deployment checklist

- [ ] Save Dashboard.xlsx as a Google Sheet (File -> Save as Google Sheets).
- [ ] Replace the `[1]RSF!` external-file formulas with values (see README, section 2).
- [ ] Enable the Google Sheets API and create a service account + JSON key.
- [ ] Share the sheet with the service account email as Viewer.
- [ ] In Vercel, add the four server-side environment variables:
      `GOOGLE_SHEETS_ID`, `GOOGLE_SERVICE_ACCOUNT_EMAIL`, `GOOGLE_PRIVATE_KEY`, `GOOGLE_SHEET_TAB`.
- [ ] Deploy, open the dashboard and click **Refresh data**.
- [ ] If you change `GOOGLE_SHEET_TAB` (new tab name), redeploy.
