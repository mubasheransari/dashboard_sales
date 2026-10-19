-- Mezan Sales Dashboard - schema for Oracle 11gR2 (11.2.0.4). No identity columns / JSON features used.
-- Run as the REST-enabled (APEX workspace) schema.

CREATE SEQUENCE dash_report_seq START WITH 1 NOCACHE;
CREATE SEQUENCE dash_table_seq  START WITH 1 NOCACHE;
CREATE SEQUENCE dash_group_seq  START WITH 1 NOCACHE;
CREATE SEQUENCE dash_column_seq START WITH 1 NOCACHE;
CREATE SEQUENCE dash_row_seq    START WITH 1 NOCACHE;
CREATE SEQUENCE dash_cell_seq   START WITH 1 NOCACHE;

CREATE TABLE dash_report (
  report_id    NUMBER              CONSTRAINT dash_report_pk PRIMARY KEY,
  report_name  VARCHAR2(200 CHAR)  NOT NULL,
  report_date  DATE                NOT NULL,
  source_label VARCHAR2(200 CHAR)  DEFAULT 'Oracle ORDS' NOT NULL,
  is_active    CHAR(1)             DEFAULT 'Y' NOT NULL,
  created_at   TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
  updated_at   TIMESTAMP           DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT dash_report_act_ck CHECK (is_active IN ('Y','N'))
);

CREATE TABLE dash_table (
  table_id      NUMBER             CONSTRAINT dash_table_pk PRIMARY KEY,
  report_id     NUMBER             NOT NULL CONSTRAINT dash_table_rpt_fk REFERENCES dash_report (report_id) ON DELETE CASCADE,
  table_code    VARCHAR2(60 CHAR)  NOT NULL,
  title         VARCHAR2(300 CHAR) NOT NULL,
  report_date   DATE,
  current_month VARCHAR2(7),
  sort_order    NUMBER DEFAULT 0   NOT NULL,
  CONSTRAINT dash_table_uk UNIQUE (report_id, table_code)
);

CREATE TABLE dash_group (
  group_id   NUMBER              CONSTRAINT dash_group_pk PRIMARY KEY,
  table_id   NUMBER              NOT NULL CONSTRAINT dash_group_tbl_fk REFERENCES dash_table (table_id) ON DELETE CASCADE,
  group_code VARCHAR2(100 CHAR)  NOT NULL,
  label      VARCHAR2(300 CHAR)  NOT NULL,
  sort_order NUMBER DEFAULT 0    NOT NULL,
  CONSTRAINT dash_group_uk UNIQUE (table_id, group_code)
);

CREATE TABLE dash_column (
  column_id   NUMBER             CONSTRAINT dash_column_pk PRIMARY KEY,
  table_id    NUMBER             NOT NULL CONSTRAINT dash_col_tbl_fk REFERENCES dash_table (table_id) ON DELETE CASCADE,
  group_id    NUMBER             NOT NULL CONSTRAINT dash_col_grp_fk REFERENCES dash_group (group_id),
  kind        VARCHAR2(10)       NOT NULL,
  label       VARCHAR2(400 CHAR),
  short_label VARCHAR2(200 CHAR),
  unit        VARCHAR2(20 CHAR),
  col_date    DATE,
  col_month   VARCHAR2(7),
  is_current  CHAR(1) DEFAULT 'N' NOT NULL,
  sort_order  NUMBER  DEFAULT 0   NOT NULL,
  CONSTRAINT dash_col_kind_ck CHECK (kind IN ('day','month','metric')),
  CONSTRAINT dash_col_cur_ck  CHECK (is_current IN ('Y','N')),
  CONSTRAINT dash_col_day_ck  CHECK (kind <> 'day'   OR col_date  IS NOT NULL),
  CONSTRAINT dash_col_mon_ck  CHECK (kind <> 'month' OR col_month IS NOT NULL)
);
CREATE UNIQUE INDEX dash_col_day_uk ON dash_column (CASE WHEN kind = 'day'   THEN TO_CHAR(table_id) || '|' || TO_CHAR(col_date, 'YYYY-MM-DD') END);
CREATE UNIQUE INDEX dash_col_mon_uk ON dash_column (CASE WHEN kind = 'month' THEN TO_CHAR(table_id) || '|' || col_month END);
CREATE INDEX dash_col_tbl_ix ON dash_column (table_id, group_id);
CREATE INDEX dash_col_grp_ix ON dash_column (group_id);

CREATE TABLE dash_row (
  row_id     NUMBER             CONSTRAINT dash_row_pk PRIMARY KEY,
  table_id   NUMBER             NOT NULL CONSTRAINT dash_row_tbl_fk REFERENCES dash_table (table_id) ON DELETE CASCADE,
  label      VARCHAR2(300 CHAR) NOT NULL,
  kind       VARCHAR2(10) DEFAULT 'item' NOT NULL,
  sort_order NUMBER       DEFAULT 0      NOT NULL,
  CONSTRAINT dash_row_kind_ck CHECK (kind IN ('item','subtotal','channel','total','growth','export','grand','detail')),
  CONSTRAINT dash_row_uk UNIQUE (table_id, label)
);

CREATE TABLE dash_cell (
  cell_id      NUMBER              CONSTRAINT dash_cell_pk PRIMARY KEY,
  row_id       NUMBER              NOT NULL CONSTRAINT dash_cell_row_fk REFERENCES dash_row (row_id)       ON DELETE CASCADE,
  column_id    NUMBER              NOT NULL CONSTRAINT dash_cell_col_fk REFERENCES dash_column (column_id) ON DELETE CASCADE,
  num_value    NUMBER,
  text_value   VARCHAR2(4000 CHAR),
  display_text VARCHAR2(200 CHAR),
  updated_at   TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  CONSTRAINT dash_cell_uk UNIQUE (row_id, column_id)
);
CREATE INDEX dash_cell_col_ix ON dash_cell (column_id);

-- primary keys from sequences (replaces 12c identity columns)
CREATE OR REPLACE TRIGGER dash_report_bi BEFORE INSERT ON dash_report FOR EACH ROW WHEN (NEW.report_id IS NULL)
BEGIN :NEW.report_id := dash_report_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER dash_table_bi BEFORE INSERT ON dash_table FOR EACH ROW WHEN (NEW.table_id IS NULL)
BEGIN :NEW.table_id := dash_table_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER dash_group_bi BEFORE INSERT ON dash_group FOR EACH ROW WHEN (NEW.group_id IS NULL)
BEGIN :NEW.group_id := dash_group_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER dash_column_bi BEFORE INSERT ON dash_column FOR EACH ROW WHEN (NEW.column_id IS NULL)
BEGIN :NEW.column_id := dash_column_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER dash_row_bi BEFORE INSERT ON dash_row FOR EACH ROW WHEN (NEW.row_id IS NULL)
BEGIN :NEW.row_id := dash_row_seq.NEXTVAL; END;
/
CREATE OR REPLACE TRIGGER dash_cell_bi BEFORE INSERT ON dash_cell FOR EACH ROW WHEN (NEW.cell_id IS NULL)
BEGIN :NEW.cell_id := dash_cell_seq.NEXTVAL; END;
/

-- Columns in display order (group order, then column order); pos = the index the dashboard uses.
CREATE OR REPLACE VIEW dash_v_cols AS
SELECT c.column_id, c.table_id, c.group_id, g.group_code, c.kind, c.label, c.short_label,
       c.unit, c.col_date, c.col_month, c.is_current,
       ROW_NUMBER() OVER (PARTITION BY c.table_id
                          ORDER BY g.sort_order, g.group_id, c.sort_order, c.column_id) - 1 AS pos
FROM   dash_column c
JOIN   dash_group  g ON g.group_id = c.group_id;
