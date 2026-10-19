/**
 * Data model for the dashboard.
 *
 * Every table in the Google Sheet (REGION WISE, BLEND WISE, ...) is delivered as a
 * generic grid: a list of columns (with their group, label, unit) and a list of rows
 * (with their kind) so the UI can show *every* column and row without hard-coding them.
 */

/** One cell: `v` is the raw value, `t` is the text exactly as the sheet displays it. */
export type Cell = { v: number | string | null; t: string };

export type ColumnKind =
  | 'day'      // one date column (daily sales)
  | 'month'    // "Primary Sales MTD <Month> <Year>"
  | 'metric';  // everything else (targets, stock, YTD, remarks ...)

export type TableColumn = {
  index: number;        // position inside TableRow.cells
  group: string;        // TableGroup.id
  kind: ColumnKind;
  label: string;        // header text from the sheet, on one line
  short: string;        // compact header for tables (e.g. "Jul 2026")
  unit: string;         // "Kg", "%", or ""
  date?: string;        // ISO date for day columns
  month?: string;       // "YYYY-MM" for month columns
  isCurrentMonth?: boolean;
};

export type TableGroup = {
  id: string;
  label: string;        // heading shown above the columns of the group
  columns: number[];    // TableColumn.index values
};

export type RowKind =
  | 'item'      // a region / blend
  | 'subtotal'  // "National G.T Primary Sales"
  | 'channel'   // Other Channels, Institutions, Ecommerce
  | 'total'     // TOTAL
  | 'growth'    // Over last Year Month (a % row)
  | 'export'    // Export
  | 'grand'     // GRAND TOTAL
  | 'detail';   // helper breakdown rows under GRAND TOTAL (LMT, Key AC, HORECA)

export type TableRow = {
  label: string;
  kind: RowKind;
  cells: (Cell | null)[];   // aligned with SheetTable.columns
};

export type SheetTable = {
  id: string;               // "region" | "blend" | slug of the sheet heading
  title: string;            // e.g. "G.T Primary Sales REGION WISE"
  reportDate: string;       // ISO date from the top of the table (cell B1 / B26)
  currentMonth: string;     // "YYYY-MM" of the daily columns
  groups: TableGroup[];
  columns: TableColumn[];
  rows: TableRow[];
};

export type DashboardData = {
  reportDate: string;
  tables: SheetTable[];
  updatedAt: string;
  source: string;
};
