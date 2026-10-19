-- ======== 01_schema.sql ========
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

-- ======== 02_dash_api_spec.sql ========
CREATE OR REPLACE PACKAGE dash_api AS
  c_invalid  CONSTANT PLS_INTEGER := -20001;   -- HTTP 400
  c_notfound CONSTANT PLS_INTEGER := -20404;   -- HTTP 404
  c_conflict CONSTANT PLS_INTEGER := -20409;   -- HTTP 409

  FUNCTION  fmt_value       (p_value NUMBER, p_unit VARCHAR2) RETURN VARCHAR2;
  FUNCTION  dashboard_json  (p_report_id NUMBER DEFAULT NULL) RETURN CLOB;   -- NULL = latest active report
  FUNCTION  list_reports    RETURN CLOB;
  FUNCTION  import_dashboard(p_json CLOB, p_name VARCHAR2 DEFAULT NULL) RETURN CLOB;
  FUNCTION  post_dashboard  (p_body CLOB) RETURN CLOB;                        -- the dynamic POST
  FUNCTION  delete_column   (p_column_id NUMBER) RETURN CLOB;
  FUNCTION  delete_row      (p_row_id NUMBER)    RETURN CLOB;

  FUNCTION  blob_to_clob    (p_blob BLOB) RETURN CLOB;
  PROCEDURE print_clob      (p_clob CLOB);
  FUNCTION  http_status     (p_sqlcode NUMBER) RETURN NUMBER;
  PROCEDURE print_error     (p_sqlcode NUMBER, p_sqlerrm VARCHAR2);
END dash_api;
/

-- ======== 03_dash_api_body.sql ========
CREATE OR REPLACE PACKAGE BODY dash_api AS
  -- Oracle 11.2.0.4. JSON is written by hand (no JSON_* SQL functions) and parsed with APEX_JSON (APEX 5.0+).

  c_dot  CONSTANT VARCHAR2(1 CHAR) := UNISTR('\00B7');
  NLS_EN CONSTANT VARCHAR2(40)     := 'NLS_DATE_LANGUAGE=ENGLISH';

  TYPE t_num_tab IS TABLE OF NUMBER INDEX BY PLS_INTEGER;

  ------------------------------------------------------------------ errors / misc
  PROCEDURE fail (p_code PLS_INTEGER, p_msg VARCHAR2) IS
  BEGIN
    raise_application_error(p_code, p_msg);
  END;

  FUNCTION utc_now RETURN TIMESTAMP IS
  BEGIN
    RETURN SYS_EXTRACT_UTC(SYSTIMESTAMP);
  END;

  ------------------------------------------------------------------ JSON writing (hand-built)
  g_clob CLOB;
  g_buf  VARCHAR2(32767);

  PROCEDURE flush_buf IS
  BEGIN
    IF g_buf IS NOT NULL THEN
      DBMS_LOB.WRITEAPPEND(g_clob, LENGTH(g_buf), g_buf);
      g_buf := NULL;
    END IF;
  END;

  PROCEDURE out_init IS
  BEGIN
    g_buf := NULL;
    DBMS_LOB.CREATETEMPORARY(g_clob, TRUE);
  END;

  PROCEDURE put (p_text VARCHAR2) IS
  BEGIN
    IF p_text IS NULL THEN RETURN; END IF;
    IF NVL(LENGTH(g_buf), 0) + LENGTH(p_text) > 30000 THEN flush_buf; END IF;
    g_buf := g_buf || p_text;
  END;

  FUNCTION out_get RETURN CLOB IS
  BEGIN
    flush_buf;
    RETURN g_clob;
  END;

  -- JSON string literal (non-ASCII characters become \uXXXX, so the output is always safe)
  FUNCTION jstr (p_text VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_text IS NULL THEN RETURN 'null'; END IF;
    RETURN '"' || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
             ASCIISTR(p_text), '\', '\u'), '"', '\"'), CHR(10), '\n'), CHR(13), '\r'), CHR(9), '\t') || '"';
  END;

  FUNCTION jnum (p_num NUMBER) RETURN VARCHAR2 IS
    l_s VARCHAR2(80);
  BEGIN
    IF p_num IS NULL THEN RETURN 'null'; END IF;
    l_s := TO_CHAR(p_num, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
    IF SUBSTR(l_s, 1, 1) = '.'  THEN l_s := '0' || l_s;           -- .5  -> 0.5
    ELSIF SUBSTR(l_s, 1, 2) = '-.' THEN l_s := '-0' || SUBSTR(l_s, 2); END IF;
    RETURN l_s;
  END;

  ------------------------------------------------------------------ JSON reading (APEX_JSON, 1-based arrays)
  PROCEDURE parse_body (p_body CLOB) IS
  BEGIN
    IF p_body IS NULL OR DBMS_LOB.GETLENGTH(p_body) = 0 THEN
      fail(c_invalid, 'A JSON request body is required.');
    END IF;
    BEGIN
      apex_json.parse(p_body);
    EXCEPTION WHEN OTHERS THEN
      fail(c_invalid, 'The request body is not valid JSON.');
    END;
  END;

  FUNCTION jhas (p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL, p2 NUMBER DEFAULT NULL) RETURN BOOLEAN IS
  BEGIN
    RETURN apex_json.does_exist(p_path => p_path, p0 => p0, p1 => p1, p2 => p2);
  END;

  FUNCTION jcount (p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL) RETURN NUMBER IS
  BEGIN
    RETURN NVL(apex_json.get_count(p_path => p_path, p0 => p0, p1 => p1), 0);
  END;

  FUNCTION js (p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL, p2 NUMBER DEFAULT NULL) RETURN VARCHAR2 IS
  BEGIN
    RETURN apex_json.get_varchar2(p_path => p_path, p0 => p0, p1 => p1, p2 => p2);
  END;

  FUNCTION jn (p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL, p2 NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_s VARCHAR2(200);
  BEGIN
    RETURN apex_json.get_number(p_path => p_path, p0 => p0, p1 => p1, p2 => p2);
  EXCEPTION WHEN OTHERS THEN
    l_s := REPLACE(TRIM(js(p_path, p0, p1, p2)), ',', '');          -- number sent as text, e.g. "1,250"
    BEGIN
      RETURN TO_NUMBER(REPLACE(l_s, '.', SUBSTR(SYS_CONTEXT('USERENV', 'NLS_NUMERIC_CHARACTERS'), 1, 1)));
    EXCEPTION WHEN OTHERS THEN
      fail(c_invalid, '"' || p_path || '" must be a number.');
    END;
    RETURN NULL;
  END;

  FUNCTION jd (p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL, p2 NUMBER DEFAULT NULL) RETURN DATE IS
    l_s VARCHAR2(100) := js(p_path, p0, p1, p2);
  BEGIN
    IF l_s IS NULL THEN RETURN NULL; END IF;
    BEGIN
      RETURN TO_DATE(SUBSTR(TRIM(l_s), 1, 10), 'YYYY-MM-DD');
    EXCEPTION WHEN OTHERS THEN
      fail(c_invalid, '"' || p_path || '" must be a date as YYYY-MM-DD.');
    END;
    RETURN NULL;
  END;

  FUNCTION jf (p_default BOOLEAN, p_path VARCHAR2, p0 NUMBER DEFAULT NULL, p1 NUMBER DEFAULT NULL, p2 NUMBER DEFAULT NULL) RETURN BOOLEAN IS
    l_s VARCHAR2(20);
  BEGIN
    l_s := UPPER(js(p_path, p0, p1, p2));
    IF l_s IS NULL THEN RETURN p_default; END IF;
    RETURN l_s IN ('Y', 'YES', 'TRUE', '1');
  EXCEPTION WHEN OTHERS THEN
    RETURN p_default;
  END;

  FUNCTION ok_json (p_extra VARCHAR2 DEFAULT NULL) RETURN CLOB IS
  BEGIN
    RETURN TO_CLOB('{"status":"ok"' || CASE WHEN p_extra IS NOT NULL THEN ',' || p_extra END || '}');
  END;

  FUNCTION slug (p_text VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN NVL(TRIM(BOTH '-' FROM LOWER(REGEXP_REPLACE(p_text, '[^A-Za-z0-9]+', '-'))), 'group');
  END;

  FUNCTION month_short (p_month VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN TO_CHAR(TO_DATE(p_month || '-01', 'YYYY-MM-DD'), 'Mon YYYY', NLS_EN);
  END;

  PROCEDURE touch_table (p_table_id NUMBER) IS
  BEGIN
    UPDATE dash_report SET updated_at = utc_now
     WHERE report_id = (SELECT report_id FROM dash_table WHERE table_id = p_table_id);
  END;

  ------------------------------------------------------------------ display text
  FUNCTION fmt_value (p_value NUMBER, p_unit VARCHAR2) RETURN VARCHAR2 IS
    l_pct NUMBER;
    c_nls CONSTANT VARCHAR2(40) := 'NLS_NUMERIC_CHARACTERS=''.,''';
  BEGIN
    IF p_value IS NULL THEN RETURN NULL; END IF;
    IF p_unit = '%' THEN
      l_pct := p_value * 100;
      IF ABS(l_pct) < 10 AND p_value <> 0 THEN
        RETURN TRIM(TO_CHAR(ROUND(l_pct, 1), 'FM999999990.0', c_nls)) || '%';
      END IF;
      RETURN TRIM(TO_CHAR(ROUND(l_pct, 0), 'FM999999990', c_nls)) || '%';
    END IF;
    IF p_value = 0 THEN RETURN '-'; END IF;
    RETURN TRIM(TO_CHAR(ROUND(p_value, 0), 'FM999G999G999G990', c_nls));
  END;

  ------------------------------------------------------------------ READ: the exact JSON the dashboard expects
  PROCEDURE write_table (p_table_id NUMBER, p_code VARCHAR2, p_title VARCHAR2, p_report_date DATE, p_month VARCHAR2) IS
    l_first BOOLEAN;
    l_first2 BOOLEAN;
  BEGIN
    put('{"id":' || jstr(p_code) || ',"title":' || jstr(p_title) ||
        ',"reportDate":' || jstr(TO_CHAR(p_report_date, 'YYYY-MM-DD')) ||
        ',"currentMonth":' || jstr(NVL(p_month, '')) || ',"groups":[');

    l_first := TRUE;
    FOR g IN (SELECT g.group_id, g.group_code, g.label
                FROM dash_group g
               WHERE g.table_id = p_table_id
                 AND EXISTS (SELECT 1 FROM dash_column c WHERE c.group_id = g.group_id)
               ORDER BY g.sort_order, g.group_id) LOOP
      IF NOT l_first THEN put(','); END IF;
      l_first := FALSE;
      put('{"id":' || jstr(g.group_code) || ',"label":' || jstr(g.label) || ',"columns":[');
      l_first2 := TRUE;
      FOR v IN (SELECT pos FROM dash_v_cols WHERE table_id = p_table_id AND group_id = g.group_id ORDER BY pos) LOOP
        IF NOT l_first2 THEN put(','); END IF;
        l_first2 := FALSE;
        put(TO_CHAR(v.pos));
      END LOOP;
      put(']}');
    END LOOP;

    put('],"columns":[');
    l_first := TRUE;
    FOR v IN (SELECT * FROM dash_v_cols WHERE table_id = p_table_id ORDER BY pos) LOOP
      IF NOT l_first THEN put(','); END IF;
      l_first := FALSE;
      put('{"index":' || v.pos || ',"group":' || jstr(v.group_code) || ',"kind":' || jstr(v.kind) ||
          ',"label":' || jstr(NVL(v.label, '')) || ',"short":' || jstr(NVL(v.short_label, NVL(v.label, ''))) ||
          ',"unit":' || jstr(NVL(v.unit, '')));
      IF v.col_date  IS NOT NULL THEN put(',"date":'  || jstr(TO_CHAR(v.col_date, 'YYYY-MM-DD'))); END IF;
      IF v.col_month IS NOT NULL THEN put(',"month":' || jstr(v.col_month)); END IF;
      IF v.is_current = 'Y'      THEN put(',"isCurrentMonth":true'); END IF;
      put('}');
    END LOOP;

    put('],"rows":[');
    l_first := TRUE;
    FOR rw IN (SELECT row_id, label, kind FROM dash_row WHERE table_id = p_table_id ORDER BY sort_order, row_id) LOOP
      IF NOT l_first THEN put(','); END IF;
      l_first := FALSE;
      put('{"label":' || jstr(rw.label) || ',"kind":' || jstr(rw.kind) || ',"cells":[');
      l_first2 := TRUE;
      FOR ce IN (SELECT v.column_id, v.unit, c.cell_id, c.num_value, c.text_value, c.display_text
                   FROM dash_v_cols v
                   LEFT JOIN dash_cell c ON c.column_id = v.column_id AND c.row_id = rw.row_id
                  WHERE v.table_id = p_table_id
                  ORDER BY v.pos) LOOP
        IF NOT l_first2 THEN put(','); END IF;
        l_first2 := FALSE;
        IF ce.cell_id IS NULL THEN
          put('null');
        ELSIF ce.num_value IS NOT NULL THEN
          put('{"v":' || jnum(ce.num_value) || ',"t":' || jstr(NVL(ce.display_text, fmt_value(ce.num_value, ce.unit))) || '}');
        ELSIF ce.text_value IS NOT NULL THEN
          put('{"v":' || jstr(ce.text_value) || ',"t":' || jstr(NVL(ce.display_text, ce.text_value)) || '}');
        ELSE
          put('{"v":null,"t":' || jstr(NVL(ce.display_text, UNISTR('\2014'))) || '}');
        END IF;
      END LOOP;
      put(']}');
    END LOOP;
    put(']}');
  END;

  FUNCTION dashboard_json (p_report_id NUMBER DEFAULT NULL) RETURN CLOB IS
    l_id    NUMBER := p_report_id;
    l_rep   dash_report%ROWTYPE;
    l_first BOOLEAN := TRUE;
  BEGIN
    IF l_id IS NULL THEN
      BEGIN
        SELECT report_id INTO l_id
          FROM (SELECT report_id FROM dash_report WHERE is_active = 'Y'
                 ORDER BY report_date DESC, report_id DESC)
         WHERE ROWNUM = 1;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        fail(c_notfound, 'No active report found. Import or create one first.');
      END;
    END IF;
    BEGIN
      SELECT * INTO l_rep FROM dash_report WHERE report_id = l_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      fail(c_notfound, 'Report ' || l_id || ' not found.');
    END;

    out_init;
    put('{"reportDate":' || jstr(TO_CHAR(l_rep.report_date, 'YYYY-MM-DD')) || ',"tables":[');
    FOR t IN (SELECT table_id, table_code, title, NVL(report_date, l_rep.report_date) AS rdate, current_month
                FROM dash_table WHERE report_id = l_id ORDER BY sort_order, table_id) LOOP
      IF NOT l_first THEN put(','); END IF;
      l_first := FALSE;
      write_table(t.table_id, t.table_code, t.title, t.rdate, t.current_month);
    END LOOP;
    put('],"updatedAt":' || jstr(TO_CHAR(l_rep.updated_at, 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')) ||
        ',"source":' || jstr(l_rep.source_label) || '}');
    RETURN out_get;
  END;

  FUNCTION list_reports RETURN CLOB IS
    l_first BOOLEAN := TRUE;
  BEGIN
    out_init;
    put('{"items":[');
    FOR r IN (SELECT * FROM dash_report ORDER BY report_date DESC, report_id DESC) LOOP
      IF NOT l_first THEN put(','); END IF;
      l_first := FALSE;
      put('{"report_id":' || r.report_id || ',"name":' || jstr(r.report_name) ||
          ',"report_date":' || jstr(TO_CHAR(r.report_date, 'YYYY-MM-DD')) ||
          ',"source":' || jstr(r.source_label) || ',"is_active":' || jstr(r.is_active) || '}');
    END LOOP;
    put(']}');
    RETURN out_get;
  END;

  ------------------------------------------------------------------ structure helpers
  FUNCTION next_row_sort (p_table_id NUMBER, p_kind VARCHAR2) RETURN NUMBER IS
    l_prev NUMBER;
    l_next NUMBER;
  BEGIN
    SELECT MAX(sort_order) INTO l_prev FROM dash_row WHERE table_id = p_table_id AND kind = p_kind;
    IF l_prev IS NULL THEN
      SELECT NVL(MAX(sort_order), 0) + 1 INTO l_prev FROM dash_row WHERE table_id = p_table_id;
      RETURN l_prev;
    END IF;
    SELECT MIN(sort_order) INTO l_next FROM dash_row WHERE table_id = p_table_id AND sort_order > l_prev;
    IF l_next IS NULL THEN RETURN l_prev + 1; END IF;
    RETURN (l_prev + l_next) / 2;           -- slot in right after the last row of the same kind
  END;

  FUNCTION next_col_sort (p_table_id NUMBER, p_group_id NUMBER, p_kind VARCHAR2, p_date DATE) RETURN NUMBER IS
    l_prev NUMBER;
    l_next NUMBER;
  BEGIN
    IF p_kind = 'day' AND p_date IS NOT NULL THEN
      SELECT MAX(sort_order) INTO l_prev FROM dash_column
       WHERE table_id = p_table_id AND group_id = p_group_id AND kind = 'day' AND col_date < p_date;
      SELECT MIN(sort_order) INTO l_next FROM dash_column
       WHERE table_id = p_table_id AND group_id = p_group_id AND kind = 'day' AND col_date > p_date;
      IF l_prev IS NOT NULL AND l_next IS NOT NULL THEN RETURN (l_prev + l_next) / 2; END IF;
      IF l_prev IS NOT NULL THEN RETURN l_prev + 1; END IF;
      IF l_next IS NOT NULL THEN RETURN l_next - 1; END IF;
    END IF;
    SELECT NVL(MAX(sort_order), 0) + 1 INTO l_prev FROM dash_column
     WHERE table_id = p_table_id AND group_id = p_group_id;
    RETURN l_prev;
  END;

  FUNCTION get_group (p_table_id NUMBER, p_code VARCHAR2, p_label VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT group_id INTO l_id FROM dash_group WHERE table_id = p_table_id AND group_code = p_code;
    RETURN l_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    INSERT INTO dash_group (table_id, group_code, label, sort_order)
    VALUES (p_table_id, p_code, NVL(p_label, p_code),
            (SELECT NVL(MAX(sort_order), 0) + 1 FROM dash_group WHERE table_id = p_table_id))
    RETURNING group_id INTO l_id;
    RETURN l_id;
  END;

  PROCEDURE set_cell (p_row NUMBER, p_col NUMBER, p_num NUMBER, p_txt VARCHAR2, p_disp VARCHAR2) IS
  BEGIN
    UPDATE dash_cell SET num_value = p_num, text_value = p_txt, display_text = p_disp, updated_at = utc_now
     WHERE row_id = p_row AND column_id = p_col;
    IF SQL%ROWCOUNT = 0 THEN
      INSERT INTO dash_cell (row_id, column_id, num_value, text_value, display_text, updated_at)
      VALUES (p_row, p_col, p_num, p_txt, p_disp, utc_now);
    END IF;
  END;

  FUNCTION add_column (p_table_id NUMBER, p_kind VARCHAR2, p_group_code VARCHAR2, p_group_label VARCHAR2,
                       p_label VARCHAR2, p_short VARCHAR2, p_unit VARCHAR2, p_date DATE,
                       p_month VARCHAR2, p_current BOOLEAN, p_sort NUMBER) RETURN NUMBER IS
    l_cur_month VARCHAR2(7);
    l_group     NUMBER;
    l_label     VARCHAR2(400 CHAR) := TRIM(p_label);
    l_short     VARCHAR2(200 CHAR) := TRIM(p_short);
    l_unit      VARCHAR2(20 CHAR)  := TRIM(p_unit);
    l_month     VARCHAR2(7)        := p_month;
    l_code      VARCHAR2(100 CHAR) := p_group_code;
    l_current   CHAR(1)            := 'N';
    l_id        NUMBER;
    l_sort      NUMBER             := p_sort;
  BEGIN
    BEGIN
      SELECT current_month INTO l_cur_month FROM dash_table WHERE table_id = p_table_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      fail(c_notfound, 'Table ' || p_table_id || ' not found.');
    END;
    IF p_kind NOT IN ('day', 'month', 'metric') THEN
      fail(c_invalid, 'kind must be one of: day, month, metric.');
    END IF;

    IF p_kind = 'day' THEN
      IF p_date IS NULL THEN fail(c_invalid, 'A day column needs a "date" (YYYY-MM-DD).'); END IF;
      l_code  := NVL(l_code, 'daily');
      l_label := TO_CHAR(p_date, 'YYYY-MM-DD');
      l_short := l_label;
      IF l_unit IS NULL THEN
        SELECT MAX(unit) KEEP (DENSE_RANK LAST ORDER BY col_date) INTO l_unit
          FROM dash_column WHERE table_id = p_table_id AND kind = 'day';
      END IF;
      l_group := get_group(p_table_id, l_code,
                           NVL(p_group_label, 'Daily sales ' || c_dot || ' ' || TO_CHAR(p_date, 'FMMonth YYYY', NLS_EN)));
    ELSIF p_kind = 'month' THEN
      l_month := NVL(l_month, TO_CHAR(p_date, 'YYYY-MM'));
      IF l_month IS NULL OR NOT REGEXP_LIKE(l_month, '^[0-9]{4}-(0[1-9]|1[0-2])$') THEN
        fail(c_invalid, 'A month column needs "month" as YYYY-MM.');
      END IF;
      IF l_label IS NULL THEN l_label := 'Primary Sales MTD ' || month_short(l_month); END IF;
      IF l_short IS NULL THEN l_short := month_short(l_month); END IF;
      IF l_unit  IS NULL THEN l_unit := 'Kg'; END IF;
      IF l_month = l_cur_month OR p_current THEN l_current := 'Y'; END IF;
      IF l_code IS NULL THEN l_code := CASE WHEN l_month = l_cur_month THEN 'month' ELSE 'history' END; END IF;
      l_group := get_group(p_table_id, l_code,
                           CASE l_code WHEN 'history' THEN 'Previous months' WHEN 'month' THEN 'Month performance' ELSE p_group_label END);
    ELSE
      IF l_code  IS NULL THEN fail(c_invalid, 'A metric column needs a "group" (group code).'); END IF;
      IF l_label IS NULL THEN fail(c_invalid, 'A metric column needs a "label".'); END IF;
      l_group := get_group(p_table_id, l_code, p_group_label);
    END IF;

    IF l_sort IS NULL THEN l_sort := next_col_sort(p_table_id, l_group, p_kind, p_date); END IF;

    INSERT INTO dash_column (table_id, group_id, kind, label, short_label, unit, col_date, col_month, is_current, sort_order)
    VALUES (p_table_id, l_group, p_kind, l_label, NVL(l_short, l_label), l_unit,
            CASE WHEN p_kind = 'day'   THEN p_date END,
            CASE WHEN p_kind = 'month' THEN l_month END,
            l_current, l_sort)
    RETURNING column_id INTO l_id;
    RETURN l_id;
  END;

  FUNCTION add_row (p_table_id NUMBER, p_label VARCHAR2, p_kind VARCHAR2, p_sort NUMBER) RETURN NUMBER IS
    l_kind VARCHAR2(10) := LOWER(NVL(p_kind, 'item'));
    l_id   NUMBER;
    l_sort NUMBER;
  BEGIN
    IF TRIM(p_label) IS NULL THEN fail(c_invalid, 'A row needs a "label".'); END IF;
    IF l_kind NOT IN ('item','subtotal','channel','total','growth','export','grand','detail') THEN
      fail(c_invalid, 'kind must be one of: item, subtotal, channel, total, growth, export, grand, detail.');
    END IF;
    l_sort := NVL(p_sort, next_row_sort(p_table_id, l_kind));
    INSERT INTO dash_row (table_id, label, kind, sort_order)
    VALUES (p_table_id, TRIM(p_label), l_kind, l_sort)
    RETURNING row_id INTO l_id;
    RETURN l_id;
  END;

  FUNCTION delete_column (p_column_id NUMBER) RETURN CLOB IS
    l_tbl NUMBER;
  BEGIN
    SELECT table_id INTO l_tbl FROM dash_column WHERE column_id = p_column_id;
    DELETE FROM dash_column WHERE column_id = p_column_id;       -- its cells are removed by ON DELETE CASCADE
    touch_table(l_tbl);
    RETURN ok_json('"deleted_column_id":' || p_column_id);
  EXCEPTION WHEN NO_DATA_FOUND THEN
    fail(c_notfound, 'Column ' || p_column_id || ' not found.');
    RETURN NULL;
  END;

  FUNCTION delete_row (p_row_id NUMBER) RETURN CLOB IS
    l_tbl NUMBER;
  BEGIN
    SELECT table_id INTO l_tbl FROM dash_row WHERE row_id = p_row_id;
    DELETE FROM dash_row WHERE row_id = p_row_id;
    touch_table(l_tbl);
    RETURN ok_json('"deleted_row_id":' || p_row_id);
  EXCEPTION WHEN NO_DATA_FOUND THEN
    fail(c_notfound, 'Row ' || p_row_id || ' not found.');
    RETURN NULL;
  END;

  ------------------------------------------------------------------ IMPORT a complete dashboard JSON (same shape the UI uses)
  FUNCTION import_dashboard (p_json CLOB, p_name VARCHAR2 DEFAULT NULL) RETURN CLOB IS
    l_date   DATE;
    l_report NUMBER;
    l_tid    NUMBER;
    l_gid    NUMBER;
    l_rid    NUMBER;
    l_nt     NUMBER;
    l_nc     NUMBER;
    l_num    NUMBER;
    l_txt    VARCHAR2(4000 CHAR);
    l_disp   VARCHAR2(200 CHAR);
    l_colids t_num_tab;
    l_code   VARCHAR2(200 CHAR);
    l_title  VARCHAR2(400 CHAR);
    l_label  VARCHAR2(400 CHAR);
    l_short  VARCHAR2(400 CHAR);
    l_unit   VARCHAR2(40 CHAR);
    l_kind   VARCHAR2(20);
    l_month  VARCHAR2(20);
    l_cur    CHAR(1);
    l_d      DATE;
  BEGIN
    parse_body(p_json);
    l_date := NVL(jd('reportDate'), TRUNC(SYSDATE));
    l_nt   := jcount('tables');
    IF l_nt = 0 THEN fail(c_invalid, 'The payload has no "tables".'); END IF;

    INSERT INTO dash_report (report_name, report_date, source_label, is_active, created_at, updated_at)
    VALUES (NVL(p_name, 'Report ' || TO_CHAR(l_date, 'YYYY-MM-DD')), l_date, 'Oracle ORDS', 'Y', utc_now, utc_now)
    RETURNING report_id INTO l_report;

    FOR ti IN 1 .. l_nt LOOP
      l_code  := js('tables[%d].id', ti);
      l_title := NVL(js('tables[%d].title', ti), l_code);
      l_d     := jd('tables[%d].reportDate', ti);
      l_month := js('tables[%d].currentMonth', ti);
      INSERT INTO dash_table (report_id, table_code, title, report_date, current_month, sort_order)
      VALUES (l_report, l_code, l_title, l_d, l_month, ti)
      RETURNING table_id INTO l_tid;

      FOR gi IN 1 .. jcount('tables[%d].groups', ti) LOOP
        l_code  := js('tables[%d].groups[%d].id', ti, gi);
        l_title := NVL(js('tables[%d].groups[%d].label', ti, gi), l_code);
        INSERT INTO dash_group (table_id, group_code, label, sort_order)
        VALUES (l_tid, l_code, l_title, gi);
      END LOOP;

      l_colids.DELETE;
      l_nc := jcount('tables[%d].columns', ti);
      FOR ci IN 1 .. l_nc LOOP
        l_code := js('tables[%d].columns[%d].group', ti, ci);
        BEGIN
          SELECT group_id INTO l_gid FROM dash_group WHERE table_id = l_tid AND group_code = l_code;
        EXCEPTION WHEN NO_DATA_FOUND THEN
          fail(c_invalid, 'Column ' || ci || ' refers to an unknown group.');
        END;
        l_kind  := NVL(js('tables[%d].columns[%d].kind', ti, ci), 'metric');
        l_label := js('tables[%d].columns[%d].label', ti, ci);
        l_short := js('tables[%d].columns[%d].short', ti, ci);
        l_unit  := js('tables[%d].columns[%d].unit', ti, ci);
        l_d     := jd('tables[%d].columns[%d].date', ti, ci);
        l_month := js('tables[%d].columns[%d].month', ti, ci);
        l_cur   := CASE WHEN jf(FALSE, 'tables[%d].columns[%d].isCurrentMonth', ti, ci) THEN 'Y' ELSE 'N' END;
        INSERT INTO dash_column (table_id, group_id, kind, label, short_label, unit, col_date, col_month, is_current, sort_order)
        VALUES (l_tid, l_gid, l_kind, l_label, l_short, l_unit, l_d, l_month, l_cur, ci)
        RETURNING column_id INTO l_colids(ci);
      END LOOP;

      FOR ri IN 1 .. jcount('tables[%d].rows', ti) LOOP
        l_label := js('tables[%d].rows[%d].label', ti, ri);
        l_kind  := NVL(js('tables[%d].rows[%d].kind', ti, ri), 'item');
        INSERT INTO dash_row (table_id, label, kind, sort_order)
        VALUES (l_tid, l_label, l_kind, ri)
        RETURNING row_id INTO l_rid;

        FOR ci IN 1 .. l_nc LOOP                               -- cells[i] belongs to columns[i]; null = empty
          l_num  := NULL;
          l_txt  := NULL;
          l_disp := js('tables[%d].rows[%d].cells[%d].t', ti, ri, ci);
          BEGIN
            l_num := apex_json.get_number(p_path => 'tables[%d].rows[%d].cells[%d].v', p0 => ti, p1 => ri, p2 => ci);
          EXCEPTION WHEN OTHERS THEN
            l_num := NULL;
            l_txt := js('tables[%d].rows[%d].cells[%d].v', ti, ri, ci);      -- text cell (e.g. Remarks)
          END;
          IF l_num IS NOT NULL OR l_txt IS NOT NULL OR l_disp IS NOT NULL THEN
            INSERT INTO dash_cell (row_id, column_id, num_value, text_value, display_text, updated_at)
            VALUES (l_rid, l_colids(ci), l_num, l_txt, l_disp, utc_now);
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;

    RETURN ok_json('"report_id":' || l_report);
  END;

  ------------------------------------------------------------------ totals (rules verified against the current sheet)
  FUNCTION first_row (p_table_id NUMBER, p_kind VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT MIN(row_id) KEEP (DENSE_RANK FIRST ORDER BY sort_order) INTO l_id
      FROM dash_row WHERE table_id = p_table_id AND kind = p_kind;
    RETURN l_id;
  END;

  FUNCTION sum_kind (p_table_id NUMBER, p_col NUMBER, p_kind VARCHAR2) RETURN NUMBER IS
    l_sum NUMBER;
  BEGIN
    SELECT SUM(ce.num_value) INTO l_sum
      FROM dash_row r JOIN dash_cell ce ON ce.row_id = r.row_id AND ce.column_id = p_col
     WHERE r.table_id = p_table_id AND r.kind = p_kind;
    RETURN l_sum;
  END;

  PROCEDURE recalc (p_table_id NUMBER) IS
    l_sub   NUMBER := first_row(p_table_id, 'subtotal');
    l_tot   NUMBER := first_row(p_table_id, 'total');
    l_grand NUMBER := first_row(p_table_id, 'grand');
    l_cur   VARCHAR2(7);
    l_items NUMBER;
    l_chan  NUMBER;
    l_total NUMBER;
    l_sum   NUMBER;
  BEGIN
    SELECT current_month INTO l_cur FROM dash_table WHERE table_id = p_table_id;

    -- 1) current-month MTD = sum of that month's daily columns (item + channel rows)
    FOR m IN (SELECT column_id, unit FROM dash_column
               WHERE table_id = p_table_id AND kind = 'month' AND is_current = 'Y') LOOP
      FOR r IN (SELECT row_id FROM dash_row WHERE table_id = p_table_id AND kind IN ('item', 'channel')) LOOP
        SELECT SUM(ce.num_value) INTO l_sum
          FROM dash_cell ce JOIN dash_column c ON c.column_id = ce.column_id
         WHERE ce.row_id = r.row_id AND c.table_id = p_table_id AND c.kind = 'day'
           AND TO_CHAR(c.col_date, 'YYYY-MM') = l_cur;
        IF l_sum IS NOT NULL THEN set_cell(r.row_id, m.column_id, l_sum, NULL, fmt_value(l_sum, m.unit)); END IF;
      END LOOP;
    END LOOP;

    -- 2) subtotal / TOTAL / GRAND TOTAL for every day column and the current-month column
    FOR c IN (SELECT column_id, kind, unit FROM dash_column
               WHERE table_id = p_table_id AND (kind = 'day' OR (kind = 'month' AND is_current = 'Y'))) LOOP
      l_items := sum_kind(p_table_id, c.column_id, 'item');
      l_chan  := sum_kind(p_table_id, c.column_id, 'channel');
      IF l_sub IS NOT NULL AND l_items IS NOT NULL THEN
        set_cell(l_sub, c.column_id, l_items, NULL, fmt_value(l_items, c.unit));
      END IF;
      IF l_tot IS NOT NULL AND (l_items IS NOT NULL OR l_chan IS NOT NULL) THEN
        l_total := NVL(l_items, 0) + NVL(l_chan, 0);
        set_cell(l_tot, c.column_id, l_total, NULL, fmt_value(l_total, c.unit));
        IF l_grand IS NOT NULL AND c.kind = 'day' THEN
          l_total := l_total + NVL(sum_kind(p_table_id, c.column_id, 'export'), 0);
          set_cell(l_grand, c.column_id, l_total, NULL, fmt_value(l_total, c.unit));
        END IF;
      END IF;
    END LOOP;
  END;

  ------------------------------------------------------------------ THE dynamic POST
  /*  Body (only "table" is required):
      { "report_id": 1,                           -- omit = latest active report
        "table": "region",                        -- table code
        "columns": [ {"kind":"day","date":"2026-10-14"},
                     {"kind":"metric","group":"fg","label":"Open Orders","unit":"Kg"} ],  -- created only if missing
        "rows":    [ {"label":"Peshawar","kind":"item"} ],                                -- created only if missing
        "cells":   [ {"row":"Karachi","column":"2026-10-14","value":1250},
                     {"row":"AWAZ","column":"Remarks","text":"Out of stock"},
                     {"row":"Lahore","column":"2026-10-13","clear":true} ],
        "recalc": true, "auto_create_rows": true, "auto_create_columns": true }          */
  FUNCTION post_dashboard (p_body CLOB) RETURN CLOB IS
    l_report   NUMBER;
    l_code     VARCHAR2(60 CHAR);
    l_tid      NUMBER;
    l_auto_c   BOOLEAN;
    l_auto_r   BOOLEAN;
    l_recalc   BOOLEAN;
    l_kind     VARCHAR2(10);
    l_date     DATE;
    l_label    VARCHAR2(400 CHAR);
    l_group    VARCHAR2(100 CHAR);
    l_unit     VARCHAR2(20 CHAR);
    l_month    VARCHAR2(7);
    l_ref      VARCHAR2(400 CHAR);
    l_n        NUMBER;
    l_cur      BOOLEAN;
    l_row      NUMBER;
    l_col      NUMBER;
    l_num      NUMBER;
    l_txt      VARCHAR2(4000 CHAR);
    l_disp     VARCHAR2(200 CHAR);
    l_cunit    VARCHAR2(20 CHAR);
    l_ckind    VARCHAR2(10);
    l_cdate    DATE;
    l_maxdate  DATE;
    l_ids      t_num_tab;
    l_cols_new NUMBER := 0;
    l_rows_new NUMBER := 0;
    l_written  NUMBER := 0;
    l_cleared  NUMBER := 0;
    l_new_cols VARCHAR2(3000);
    l_new_rows VARCHAR2(3000);
    l_has_cells BOOLEAN;
    l_clear    BOOLEAN;
  BEGIN
    parse_body(p_body);
    l_code   := js('table');
    l_report := jn('report_id');
    l_auto_c := jf(TRUE, 'auto_create_columns');
    l_auto_r := jf(TRUE, 'auto_create_rows');
    l_recalc := jf(TRUE, 'recalc');
    IF l_code IS NULL THEN fail(c_invalid, '"table" (table code, e.g. "region") is required.'); END IF;

    IF l_report IS NULL THEN
      BEGIN
        SELECT report_id INTO l_report
          FROM (SELECT report_id FROM dash_report WHERE is_active = 'Y' ORDER BY report_date DESC, report_id DESC)
         WHERE ROWNUM = 1;
      EXCEPTION WHEN NO_DATA_FOUND THEN
        fail(c_notfound, 'No active report found.');
      END;
    END IF;
    BEGIN
      SELECT table_id INTO l_tid FROM dash_table WHERE report_id = l_report AND table_code = l_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      fail(c_notfound, 'Table "' || l_code || '" not found in report ' || l_report || '.');
    END;

    ---------------------------------------------------------- 1) columns that do not exist yet
    FOR i IN 1 .. jcount('columns') LOOP
      l_kind  := LOWER(NVL(js('columns[%d].kind', i), 'metric'));
      l_date  := jd('columns[%d].date', i);
      l_label := TRIM(js('columns[%d].label', i));
      l_group := js('columns[%d].group', i);
      l_unit  := js('columns[%d].unit', i);
      l_month := NVL(js('columns[%d].month', i), TO_CHAR(l_date, 'YYYY-MM'));
      l_cur   := jf(FALSE, 'columns[%d].is_current', i);
      IF l_kind = 'day' THEN
        SELECT COUNT(*) INTO l_n FROM dash_column WHERE table_id = l_tid AND kind = 'day' AND col_date = l_date;
      ELSIF l_kind = 'month' THEN
        SELECT COUNT(*) INTO l_n FROM dash_column WHERE table_id = l_tid AND kind = 'month' AND col_month = l_month;
      ELSE
        SELECT COUNT(*) INTO l_n FROM dash_v_cols v
         WHERE v.table_id = l_tid AND UPPER(v.label) = UPPER(l_label)
           AND (l_group IS NULL OR v.group_code = l_group)
           AND (l_unit  IS NULL OR v.unit = l_unit);
      END IF;
      IF l_n = 0 THEN
        l_col := add_column(l_tid, l_kind, l_group, js('columns[%d].group_label', i), l_label,
                            js('columns[%d].short', i), l_unit, l_date, js('columns[%d].month', i), l_cur,
                            jn('columns[%d].sort_order', i));
        l_cols_new := l_cols_new + 1;
      END IF;
    END LOOP;

    ---------------------------------------------------------- 2) rows that do not exist yet
    FOR i IN 1 .. jcount('rows') LOOP
      l_label := TRIM(js('rows[%d].label', i));
      SELECT COUNT(*) INTO l_n FROM dash_row WHERE table_id = l_tid AND UPPER(label) = UPPER(l_label);
      IF l_n = 0 THEN
        l_row := add_row(l_tid, l_label, js('rows[%d].kind', i), jn('rows[%d].sort_order', i));
        l_rows_new := l_rows_new + 1;
      END IF;
    END LOOP;

    ---------------------------------------------------------- 3) cell values
    FOR i IN 1 .. jcount('cells') LOOP
      -- row
      l_row := jn('cells[%d].row_id', i);
      IF l_row IS NOT NULL THEN
        SELECT COUNT(*) INTO l_n FROM dash_row WHERE row_id = l_row AND table_id = l_tid;
        IF l_n = 0 THEN fail(c_notfound, 'cells[' || i || ']: row_id ' || l_row || ' is not in table "' || l_code || '".'); END IF;
      ELSE
        l_label := TRIM(js('cells[%d].row', i));
        IF l_label IS NULL THEN fail(c_invalid, 'cells[' || i || '] needs "row" (label) or "row_id".'); END IF;
        BEGIN
          SELECT row_id INTO l_row FROM dash_row WHERE table_id = l_tid AND UPPER(label) = UPPER(l_label);
        EXCEPTION WHEN NO_DATA_FOUND THEN
          IF l_auto_r THEN
            l_row := add_row(l_tid, l_label, js('cells[%d].row_kind', i), NULL);
            l_rows_new := l_rows_new + 1;
          ELSE
            fail(c_notfound, 'Row "' || l_label || '" not found (set "auto_create_rows": true to create it).');
          END IF;
        END;
      END IF;

      -- column
      l_col := jn('cells[%d].column_id', i);
      IF l_col IS NOT NULL THEN
        SELECT COUNT(*) INTO l_n FROM dash_column WHERE column_id = l_col AND table_id = l_tid;
        IF l_n = 0 THEN fail(c_notfound, 'cells[' || i || ']: column_id ' || l_col || ' is not in table "' || l_code || '".'); END IF;
      ELSE
        l_ref   := TRIM(js('cells[%d].column', i));
        l_group := js('cells[%d].group', i);
        l_unit  := js('cells[%d].unit', i);
        IF l_ref IS NULL THEN fail(c_invalid, 'cells[' || i || '] needs "column" (date or label) or "column_id".'); END IF;
        IF REGEXP_LIKE(l_ref, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN
          l_date := jd('cells[%d].column', i);
          BEGIN
            SELECT column_id INTO l_col FROM dash_column WHERE table_id = l_tid AND kind = 'day' AND col_date = l_date;
          EXCEPTION WHEN NO_DATA_FOUND THEN
            IF l_auto_c THEN
              l_col := add_column(l_tid, 'day', NULL, NULL, NULL, NULL, l_unit, l_date, NULL, FALSE, NULL);
              l_cols_new := l_cols_new + 1;
              IF LENGTH(l_new_cols) IS NULL OR LENGTH(l_new_cols) < 2500 THEN
                l_new_cols := l_new_cols || CASE WHEN l_new_cols IS NOT NULL THEN ',' END || jstr(l_ref);
              END IF;
            ELSE
              fail(c_notfound, 'No daily column for ' || l_ref || ' (set "auto_create_columns": true to create it).');
            END IF;
          END;
        ELSE
          l_ids.DELETE;
          l_n := 0;
          FOR v IN (SELECT column_id FROM dash_v_cols
                     WHERE table_id = l_tid
                       AND (UPPER(label) = UPPER(l_ref) OR UPPER(short_label) = UPPER(l_ref))
                       AND (l_group IS NULL OR group_code = l_group)
                       AND (l_unit  IS NULL OR unit = l_unit)) LOOP
            l_n := l_n + 1;
            l_ids(l_n) := v.column_id;
          END LOOP;
          IF l_n = 0 THEN fail(c_notfound, 'Column "' || l_ref || '" not found.'); END IF;
          IF l_n > 1 THEN
            fail(c_conflict, 'Column "' || l_ref || '" is ambiguous (' || l_n || ' matches). Add "group" and/or "unit", or use "column_id".');
          END IF;
          l_col := l_ids(1);
        END IF;
      END IF;

      SELECT unit, kind, col_date INTO l_cunit, l_ckind, l_cdate FROM dash_column WHERE column_id = l_col;

      -- value
      l_clear := jf(FALSE, 'cells[%d].clear', i);
      IF l_clear THEN
        DELETE FROM dash_cell WHERE row_id = l_row AND column_id = l_col;
        l_cleared := l_cleared + 1;
      ELSE
        IF NOT (jhas('cells[%d].value', i) OR jhas('cells[%d].text', i)) THEN
          fail(c_invalid, 'cells[' || i || '] needs "value", "text" or "clear": true.');
        END IF;
        l_num  := jn('cells[%d].value', i);
        l_txt  := js('cells[%d].text', i);
        l_disp := js('cells[%d].display', i);
        IF l_num IS NULL AND l_txt IS NULL THEN
          DELETE FROM dash_cell WHERE row_id = l_row AND column_id = l_col;     -- null = empty the cell
          l_cleared := l_cleared + 1;
        ELSE
          IF l_disp IS NULL AND l_num IS NOT NULL THEN l_disp := fmt_value(l_num, l_cunit); END IF;
          set_cell(l_row, l_col, l_num, l_txt, l_disp);
          l_written := l_written + 1;
          IF l_ckind = 'day' AND l_num IS NOT NULL AND (l_maxdate IS NULL OR l_cdate > l_maxdate) THEN
            l_maxdate := l_cdate;
          END IF;
        END IF;
      END IF;
    END LOOP;

    -- data for a later day moves the report date forward
    IF l_maxdate IS NOT NULL THEN
      UPDATE dash_table  SET report_date = GREATEST(NVL(report_date, l_maxdate), l_maxdate) WHERE table_id = l_tid;
      UPDATE dash_report SET report_date = GREATEST(report_date, l_maxdate)                 WHERE report_id = l_report;
    END IF;

    IF l_recalc THEN recalc(l_tid); END IF;
    touch_table(l_tid);

    RETURN ok_json('"report_id":' || l_report || ',"table_id":' || l_tid ||
                   ',"columns_created":' || l_cols_new || ',"rows_created":' || l_rows_new ||
                   ',"written":' || l_written || ',"cleared":' || l_cleared ||
                   ',"created_date_columns":[' || l_new_cols || ']' ||
                   ',"recalculated":' || CASE WHEN l_recalc THEN 'true' ELSE 'false' END);
  END;

  ------------------------------------------------------------------ ORDS helpers
  FUNCTION blob_to_clob (p_blob BLOB) RETURN CLOB IS
    l_clob CLOB;
    l_dest PLS_INTEGER := 1;
    l_src  PLS_INTEGER := 1;
    l_ctx  PLS_INTEGER := DBMS_LOB.DEFAULT_LANG_CTX;
    l_warn PLS_INTEGER;
  BEGIN
    IF p_blob IS NULL OR DBMS_LOB.GETLENGTH(p_blob) = 0 THEN RETURN NULL; END IF;
    DBMS_LOB.CREATETEMPORARY(l_clob, TRUE);
    DBMS_LOB.CONVERTTOCLOB(l_clob, p_blob, DBMS_LOB.LOBMAXSIZE, l_dest, l_src, 873, l_ctx, l_warn);   -- 873 = AL32UTF8
    RETURN l_clob;
  END;

  PROCEDURE print_clob (p_clob CLOB) IS
    l_len PLS_INTEGER;
    l_pos PLS_INTEGER := 1;
    c_amt CONSTANT PLS_INTEGER := 8000;
  BEGIN
    IF p_clob IS NULL THEN RETURN; END IF;
    l_len := DBMS_LOB.GETLENGTH(p_clob);
    WHILE l_pos <= l_len LOOP
      htp.prn(DBMS_LOB.SUBSTR(p_clob, c_amt, l_pos));
      l_pos := l_pos + c_amt;
    END LOOP;
  END;

  FUNCTION http_status (p_sqlcode NUMBER) RETURN NUMBER IS
  BEGIN
    IF p_sqlcode = c_notfound THEN RETURN 404; END IF;
    IF p_sqlcode = c_conflict OR p_sqlcode IN (-1, -2292) THEN RETURN 409; END IF;
    IF p_sqlcode = c_invalid  OR p_sqlcode IN (-2290, -2291, -1400, -1722, -1830, -1843, -1861, -6502, -12899) THEN RETURN 400; END IF;
    RETURN 500;
  END;

  PROCEDURE print_error (p_sqlcode NUMBER, p_sqlerrm VARCHAR2) IS
  BEGIN
    owa_util.mime_header('application/json', TRUE, 'utf-8');
    htp.prn('{"error":' || jstr(REGEXP_REPLACE(SUBSTR(p_sqlerrm, 1, 2000), '^ORA-[0-9]+: ?', '')) ||
            ',"code":' || p_sqlcode || '}');
  END;

END dash_api;
/

-- ======== 04_ords_module.sql ========
-- ORDS module "dash"  ->  https://<host>/ords/<schema-alias>/dash/...
-- Needs ORDS 3.0+ (implicit :body and :status_code). Run as the REST-enabled schema.

-- Skip this block if the schema is already REST-enabled in APEX (keep your existing alias).
BEGIN
  ORDS.ENABLE_SCHEMA(p_enabled             => TRUE,
                     p_schema              => USER,
                     p_url_mapping_type    => 'BASE_PATH',
                     p_url_mapping_pattern => 'mezan',
                     p_auto_rest_auth      => FALSE);
  COMMIT;
END;
/

BEGIN
  ORDS.DEFINE_MODULE(p_module_name    => 'dash',
                     p_base_path      => '/dash/',
                     p_items_per_page => 0,
                     p_status         => 'PUBLISHED',
                     p_comments       => 'Mezan sales dashboard data API');
END;
/

DECLARE
  c_mod CONSTANT VARCHAR2(30) := 'dash';

  -- every handler: run the call, set the HTTP status, print JSON; errors become {"error":..,"code":..}
  PROCEDURE handler (p_pattern VARCHAR2, p_method VARCHAR2, p_call VARCHAR2, p_status NUMBER DEFAULT 200) IS
    l_src VARCHAR2(4000);
  BEGIN
    l_src := 'DECLARE l_out CLOB; BEGIN ' || p_call ||
             ' :status_code := ' || p_status || ';' ||
             ' owa_util.mime_header(''application/json'', TRUE, ''utf-8'');' ||
             ' dash_api.print_clob(l_out);' ||
             ' EXCEPTION WHEN OTHERS THEN' ||
             ' :status_code := dash_api.http_status(SQLCODE);' ||
             ' dash_api.print_error(SQLCODE, SQLERRM);' ||
             ' END;';
    ORDS.DEFINE_HANDLER(p_module_name => c_mod, p_pattern => p_pattern, p_method => p_method,
                        p_source_type => ORDS.source_type_plsql, p_items_per_page => 0, p_source => l_src);
  END;

  PROCEDURE tmpl (p_pattern VARCHAR2) IS
  BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => c_mod, p_pattern => p_pattern);
  END;
BEGIN
  -- GET: what the Next.js dashboard reads
  tmpl('dashboard/');
  handler('dashboard/', 'GET', 'l_out := dash_api.dashboard_json(NULL);');
  tmpl('dashboard/:report_id');
  handler('dashboard/:report_id', 'GET', 'l_out := dash_api.dashboard_json(TO_NUMBER(:report_id));');

  -- POST: the one dynamic endpoint (creates missing columns / rows, writes values)
  tmpl('manage/dashboard');
  handler('manage/dashboard', 'POST', 'l_out := dash_api.post_dashboard(dash_api.blob_to_clob(:body));');

  -- helpers
  tmpl('manage/reports/');
  handler('manage/reports/', 'GET', 'l_out := dash_api.list_reports;');
  tmpl('manage/import');
  handler('manage/import', 'POST', 'l_out := dash_api.import_dashboard(dash_api.blob_to_clob(:body), :name);', 201);
  tmpl('manage/columns/:column_id');
  handler('manage/columns/:column_id', 'DELETE', 'l_out := dash_api.delete_column(TO_NUMBER(:column_id));');
  tmpl('manage/rows/:row_id');
  handler('manage/rows/:row_id', 'DELETE', 'l_out := dash_api.delete_row(TO_NUMBER(:row_id));');

  COMMIT;
END;
/

-- Security (OAuth2 client credentials). Run this block ONCE.
BEGIN
  ORDS.CREATE_ROLE(p_role_name => 'dash_reader');
  ORDS.CREATE_ROLE(p_role_name => 'dash_writer');
  ORDS.CREATE_PRIVILEGE(p_name => 'dash.read',  p_role_name => 'dash_reader',
                        p_label => 'Dashboard read',  p_description => 'Read the sales dashboard JSON');
  ORDS.CREATE_PRIVILEGE(p_name => 'dash.write', p_role_name => 'dash_writer',
                        p_label => 'Dashboard write', p_description => 'Add / edit / delete dashboard data');
  ORDS.CREATE_PRIVILEGE_MAPPING(p_privilege_name => 'dash.read',  p_pattern => '/dash/dashboard/*');
  ORDS.CREATE_PRIVILEGE_MAPPING(p_privilege_name => 'dash.write', p_pattern => '/dash/manage/*');

  OAUTH.CREATE_CLIENT(p_name => 'mezan_dashboard_web', p_grant_type => 'client_credentials',
                      p_owner => 'Mezan IT', p_description => 'Next.js dashboard (server side)',
                      p_support_email => 'it@example.com',                -- << change
                      p_privilege_names => 'dash.read');
  OAUTH.GRANT_CLIENT_ROLE(p_client_name => 'mezan_dashboard_web', p_role_name => 'dash_reader');

  OAUTH.CREATE_CLIENT(p_name => 'mezan_dashboard_editor', p_grant_type => 'client_credentials',
                      p_owner => 'Mezan IT', p_description => 'Data entry / integration client',
                      p_support_email => 'it@example.com',                -- << change
                      p_privilege_names => 'dash.write');
  OAUTH.GRANT_CLIENT_ROLE(p_client_name => 'mezan_dashboard_editor', p_role_name => 'dash_writer');
  COMMIT;
END;
/

SELECT name, client_id, client_secret FROM user_ords_clients WHERE name LIKE 'mezan_dashboard%';

-- ======== 05_seed_current_data.sql ========
-- Loads the current dashboard data (taken from Dashboard.xlsx) into the DASH_* tables. Run ONCE, last.
DECLARE
  l_json CLOB;
  l_res  CLOB;
BEGIN
  DBMS_LOB.CREATETEMPORARY(l_json, TRUE);
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~{"reportDate":"2026-10-13","tables":[{"id":"region","title":"G.T Primary Sales REGION WISE","reportDate":"2026-10-13","currentMonth":"2026-10","groups":[{"id":"history","label":"Previous months","columns":[0,1,2]},{"id":"daily","label":"Daily sales \u00b7 October 2026","columns":[3,4,5,6,7,8,9,10,11,12,13,14,15]},{"id":"month","label":"October 2026 performance","columns":[16,17,18,19,20]},{"id":"fg","label":"FG stock & warehouse","columns":[21,22,23,24,25,26,27,28,29]},{"id":"july-2026-todate","label":"YTD \u00b7 July 2026 Todate","columns":[30,31,32,33]}],"columns":[{"index":0,"group":"history","kind":"month","label":"Primary Sales MTD July 2026","short":"Jul 2026","unit":"Kg","month":"2026-07"},{"index":1,"group":"history","kind":"month","label":"Primary Sales MTD Aug 2026","short":"Aug 2026","unit":"Kg","month":"2026-08"},{"index":2,"group":"history","kind":"month","label":"Primary Sales MTD 30 SEP 2026","short":"Sep 2026","unit":"Kg","month":"2026-09"},{"index":3,"group":"daily","kind":"day","label":"2026-10-01","short":"2026-10-01","unit":"Kg","date":"2026-10-01"},{"index":4,"group":"daily","kind":"day","label":"2026-10-02","short":"2026-10-02","unit":"Kg","date":"2026-10-02"},{"index":5,"group":"daily","kind":"day","label":"2026-10-03","short":"2026-10-03","unit":"Kg","date":"2026-10-03"},{"index":6,"group":"daily","kind":"day","label":"2026-10-04","short":"2026-10-04","unit":"","date":"2026-10-04"},{"index":7,"group":"daily","kind":"day","label":"2026-10-05","short":"2026-10-05","unit":"Kg","date":"2026-10-05"},{"index":8,"group":"daily","kind":"day","label":"2026-10-06","short":"2026-10-06","unit":"Kg","date":"2026-10-06"},{"index":9,"group":"daily","kind":"day","label":"2026-10-07","short":"2026-10-07","unit":"Kg","date":"2026-10-07"},{"index":10,"group":"daily~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~","kind":"day","label":"2026-10-08","short":"2026-10-08","unit":"Kg","date":"2026-10-08"},{"index":11,"group":"daily","kind":"day","label":"2026-10-09","short":"2026-10-09","unit":"Kg","date":"2026-10-09"},{"index":12,"group":"daily","kind":"day","label":"2026-10-10","short":"2026-10-10","unit":"Kg","date":"2026-10-10"},{"index":13,"group":"daily","kind":"day","label":"2026-10-11","short":"2026-10-11","unit":"Kg","date":"2026-10-11"},{"index":14,"group":"daily","kind":"day","label":"2026-10-12","short":"2026-10-12","unit":"Kg","date":"2026-10-12"},{"index":15,"group":"daily","kind":"day","label":"2026-10-13","short":"2026-10-13","unit":"Kg","date":"2026-10-13"},{"index":16,"group":"month","kind":"metric","label":"Primary Sales Oct 2025","short":"Primary Sales Oct 2025","unit":"Kg"},{"index":17,"group":"month","kind":"metric","label":"RSF Target Oct 2026","short":"RSF Target Oct 2026","unit":"Kg"},{"index":18,"group":"month","kind":"month","label":"Primary Sales MTD Oct 2026","short":"Oct 2026","unit":"Kg","month":"2026-10","isCurrentMonth":true},{"index":19,"group":"month","kind":"metric","label":"Remaining Vol","short":"Remaining Vol","unit":"Kg"},{"index":20,"group":"month","kind":"metric","label":"Achievement Vs Sep 26 RSF","short":"Achievement Vs Sep 26 RSF","unit":"%"},{"index":21,"group":"fg","kind":"metric","label":"FG","short":"FG","unit":"Kg"},{"index":22,"group":"fg","kind":"metric","label":"Transit","short":"Transit","unit":"Kg"},{"index":23,"group":"fg","kind":"metric","label":"Total SC","short":"Total SC","unit":"Kg"},{"index":24,"group":"fg","kind":"metric","label":"RSF Target Oct 2026","short":"RSF Target Oct 2026","unit":"Kg"},{"index":25,"group":"fg","kind":"metric","label":"FG Available against Oct RSF","short":"FG Available against Oct RSF","unit":"Kg~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~"},{"index":26,"group":"fg","kind":"metric","label":"Additional Cover over RSF","short":"Additional Cover over RSF","unit":"Kg"},{"index":27,"group":"fg","kind":"metric","label":"Additional Cover","short":"Additional Cover","unit":"%"},{"index":28,"group":"fg","kind":"metric","label":"WH Capacity","short":"WH Capacity","unit":"Kg"},{"index":29,"group":"fg","kind":"metric","label":"WH Utilized capacity","short":"WH Utilized capacity","unit":"%"},{"index":30,"group":"july-2026-todate","kind":"metric","label":"YTD Primary Sales","short":"YTD Primary Sales","unit":"Kg"},{"index":31,"group":"july-2026-todate","kind":"metric","label":"YTD RSF","short":"YTD RSF","unit":"Kg"},{"index":32,"group":"july-2026-todate","kind":"metric","label":"Over/ Under","short":"Over/ Under","unit":"Kg"},{"index":33,"group":"july-2026-todate","kind":"metric","label":"Achieve","short":"Achieve","unit":"%"}],"rows":[{"label":"Karachi","kind":"item","cells":[{"v":8113,"t":"8,113"},{"v":10229,"t":"10,229"},{"v":9273,"t":"9,273"},{"v":0,"t":"-"},{"v":78,"t":"78"},{"v":210,"t":"210"},{"v":0,"t":"-"},{"v":408,"t":"408"},{"v":85,"t":"85"},{"v":668,"t":"668"},{"v":778,"t":"778"},{"v":0,"t":"-"},{"v":68,"t":"68"},{"v":328,"t":"328"},{"v":144,"t":"144"},null,{"v":16264,"t":"16,264"},{"v":12000,"t":"12,000"},{"v":2767,"t":"2,767"},{"v":-9233,"t":"-9,233"},{"v":0.23058333333333333,"t":"23%"},{"v":90016,"t":"90,016"},{"v":0,"t":"-"},{"v":90016,"t":"90,016"},{"v":58000,"t":"58,000"},{"v":1.552,"t":"155%"},{"v":37989,"t":"37,989"},{"v":0.7301785611317201,"t":"73%"},{"v":120000,"t":"120,000"},{"v":0.7501333333333333,"t":"75%"},{"v":29840,"t":"29,840"},{"v":32347,"t":"32,347"},{"v":-2507,"t":"-2,507"},{"v":-0.07750332333755836,"t":"-8%"}]},{"label":"Hyderabad","kind":"item","cells":[{"v":16170,"t":"16,170"},{"v":1~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~6525,"t":"16,525"},{"v":18503,"t":"18,503"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":58,"t":"58"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":303,"t":"303"},{"v":1053,"t":"1,053"},{"v":0,"t":"-"},null,{"v":26417,"t":"26,417"},{"v":24000,"t":"24,000"},{"v":1414,"t":"1,414"},{"v":-22586,"t":"-22,586"},{"v":0.058916666666666666,"t":"6%"},null,{"v":0,"t":"-"},null,null,null,null,null,null,null,{"v":51256,"t":"51,256"},{"v":74109,"t":"74,109"},{"v":-22853,"t":"-22,853"},{"v":-0.30837010349620153,"t":"-31%"}]},{"label":"Sukkur","kind":"item","cells":[{"v":12001,"t":"12,001"},{"v":11109,"t":"11,109"},{"v":12592,"t":"12,592"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":122,"t":"122"},{"v":1670,"t":"1,670"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,{"v":24432,"t":"24,432"},{"v":22000,"t":"22,000"},{"v":1792,"t":"1,792"},{"v":-20208,"t":"-20,208"},{"v":0.08145454545454546,"t":"8%"},null,{"v":0,"t":"-"},null,null,null,null,null,null,null,{"v":37495,"t":"37,495"},{"v":71609,"t":"71,609"},{"v":-34114,"t":"-34,114"},{"v":-0.47639263221103495,"t":"-48%"}]},{"label":"Multan","kind":"item","cells":[{"v":21078,"t":"21,078"},{"v":23524,"t":"23,524"},{"v":22273,"t":"22,273"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1032,"t":"1,032"},{"v":1209,"t":"1,209"},{"v":1356,"t":"1,356"},{"v":1206,"t":"1,206"},{"v":0,"t":"-"},{"v":353,"t":"353"},{"v":707,"t":"707"},{"v":512,"t":"512"},null,{"v":36342,"t":"36,342"},{"v":32595,"t":"32,595"},{"v":6375,"t":"6,375"},{"v":-26220,"t":"-26,220"},{"v":0.19558214450069028,"t":"20%"},{"v":26256,"t":"26,256"},{"v":0,"t":"-"},{"v":26256,"t":"26,256"},{"v":32595,"t":"32,595"},{"v":0.8055223193741371,"~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~t":"81%"},{"v":36,"t":"36"},{"v":0.0013729977116704805,"t":"0.1%"},{"v":45000,"t":"45,000"},{"v":0.5834666666666667,"t":"58%"},{"v":71679,"t":"71,679"},{"v":82325,"t":"82,325"},{"v":-10646,"t":"-10,646"},{"v":-0.12931673246279987,"t":"-13%"}]},{"label":"Faisalabad","kind":"item","cells":[{"v":6543,"t":"6,543"},{"v":7404,"t":"7,404"},{"v":10693,"t":"10,693"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":"Sunday","t":"Sunday"},{"v":0,"t":"-"},{"v":232,"t":"232"},{"v":167,"t":"167"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":625,"t":"625"},{"v":536,"t":"536"},null,{"v":15152,"t":"15,152"},{"v":16000,"t":"16,000"},{"v":1560,"t":"1,560"},{"v":-14440,"t":"-14,440"},{"v":0.0975,"t":"10%"},{"v":11081,"t":"11,081"},{"v":15647,"t":"15,647"},{"v":26728,"t":"26,728"},{"v":16000,"t":"16,000"},{"v":1.6705,"t":"167%"},{"v":12288,"t":"12,288"},{"v":0.8509695290858725,"t":"85.1%"},{"v":30000,"t":"30,000"},{"v":0.3693666666666667,"t":"37%"},{"v":25038,"t":"25,038"},{"v":41381,"t":"41,381"},{"v":-16343,"t":"-16,343"},{"v":-0.39493970662864597,"t":"-39%"}]},{"label":"Lahore","kind":"item","cells":[{"v":3453,"t":"3,453"},{"v":5185,"t":"5,185"},{"v":8216,"t":"8,216"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":165,"t":"165"},{"v":0,"t":"-"},{"v":992,"t":"992"},{"v":244,"t":"244"},{"v":210,"t":"210"},{"v":0,"t":"-"},{"v":346,"t":"346"},{"v":324,"t":"324"},null,{"v":9313,"t":"9,313"},{"v":10000,"t":"10,000"},{"v":2281,"t":"2,281"},{"v":-7719,"t":"-7,719"},{"v":0.2281,"t":"23%"},{"v":9425,"t":"9,425"},{"v":16541,"t":"16,541"},{"v":25966,"t":"25,966"},{"v":10000,"t":"10,000"},{"v":2.5966,"t":"260%"},{"v":18247,"t":"18,247"},{"v":2.3639072418707086,"t":"236.4%"},{"v":30000,"t":"30,000"},{"v":0.31416666666666665,"t":"31%"},{"v":18465,"t":"18,465"},{"v":263~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~77,"t":"26,377"},{"v":-7912,"t":"-7,912"},{"v":-0.29995829700117527,"t":"-30%"}]},{"label":"Islamabad","kind":"item","cells":[{"v":7823,"t":"7,823"},{"v":7973,"t":"7,973"},{"v":13227,"t":"13,227"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":109,"t":"109"},{"v":120,"t":"120"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":75,"t":"75"},{"v":378,"t":"378"},{"v":68,"t":"68"},{"v":450,"t":"450"},null,{"v":20884,"t":"20,884"},{"v":23000,"t":"23,000"},{"v":1200,"t":"1,200"},{"v":-21800,"t":"-21,800"},{"v":0.05217391304347826,"t":"5%"},{"v":32736,"t":"32,736"},{"v":0,"t":"-"},{"v":32736,"t":"32,736"},{"v":23000,"t":"23,000"},{"v":1.423304347826087,"t":"142%"},{"v":10936,"t":"10,936"},{"v":0.501651376146789,"t":"50.2%"},{"v":40000,"t":"40,000"},{"v":0.8184,"t":"82%"},{"v":29327,"t":"29,327"},{"v":63693,"t":"63,693"},{"v":-34366,"t":"-34,366"},{"v":-0.53955693718305,"t":"-54%"}]},{"label":"National G.T Primary Sales","kind":"subtotal","cells":[{"v":75181,"t":"75,181"},{"v":81949,"t":"81,949"},{"v":94777,"t":"94,777"},{"v":0,"t":"-"},{"v":78,"t":"78"},{"v":210,"t":"210"},{"v":0,"t":"-"},{"v":1714,"t":"1,714"},{"v":1646,"t":"1,646"},{"v":3241,"t":"3,241"},{"v":2350,"t":"2,350"},{"v":1955,"t":"1,955"},{"v":1102,"t":"1,102"},{"v":3127,"t":"3,127"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":148804,"t":"148,804"},{"v":139595,"t":"139,595"},{"v":17389,"t":"17,389"},{"v":-122206,"t":"-122,206"},{"v":0.1245674988359182,"t":"12%"},{"v":169514,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702,"t":"201,702"},{"v":139595,"t":"139,595"},{"v":1.4449084852609335,"t":"144%"},{"v":79496,"t":"79,496"},{"v":0.6505081583555635,"t":"65.1%"},{"v":265000,"t":"265,000"},{"v":0.6396754716981132,"t":"64%"},{"v":263100,"t":"263,100"},{"v":391841,"t":"391,841"},{"v":-128741,"t":"-128,741"},~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~{"v":-0.3285541839674766,"t":"-33%"}]},{"label":"Other Channels (LMT, Key AC)","kind":"channel","cells":[{"v":10906,"t":"10,906"},{"v":11919,"t":"11,919"},{"v":8066,"t":"8,066"},{"v":0,"t":"-"},{"v":1145,"t":"1,145"},{"v":21,"t":"21"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":141,"t":"141"},{"v":267,"t":"267"},{"v":0,"t":"-"},{"v":2707,"t":"2,707"},{"v":0,"t":"-"},null,null,{"v":6647,"t":"6,647"},{"v":20007,"t":"20,007"},{"v":4281,"t":"4,281"},{"v":-15726,"t":"-15,726"},{"v":0.21397510871195083,"t":"21%"},null,null,null,{"v":20007,"t":"20,007"},null,null,null,null,null,{"v":34190,"t":"34,190"},{"v":55999,"t":"55,999"},{"v":-21809,"t":"-21,809"},{"v":-0.3894533830961267,"t":"-39%"}]},{"label":"Instituitons","kind":"channel","cells":[{"v":372,"t":"372"},{"v":607,"t":"607"},{"v":630,"t":"630"},null,null,{"v":22,"t":"22"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":93,"t":"93"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,null,{"v":946,"t":"946"},{"v":1502,"t":"1,502"},{"v":115,"t":"115"},null,null,null,null,null,{"v":1502,"t":"1,502"},null,null,null,null,null,null,null,null,null]},{"label":"Ecommerce","kind":"channel","cells":[null,null,null,null,null,{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,null,null,null,{"v":0,"t":"-"},null,{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"0.0%"},null,null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"TOTAL","kind":"total","cells":[{"v":86459,"t":"86,459"},{"v":94475,"t":"94,475"},{"v":103473,"t":"103,473"},{"v":0,"t":"-"},{"v":1223,"t":"1,223"},{"v":253,"t":"253"},{"v":0,"t":"-"},{"v":1714,"t":"1,714"},{"v":1646,"t":"1,646"},{"v":3382,"t":"3,382"},{"v":2617,"t":"2,617"},{"v":2048,"t":"2,048"},{"v":3809,"t":"3,809"~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~},{"v":3127,"t":"3,127"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":156397,"t":"156,397"},{"v":161104,"t":"161,104"},{"v":21785,"t":"21,785"},{"v":-139319,"t":"-139,319"},{"v":0.13522320985202105,"t":"13.5%"},{"v":169514,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702,"t":"201,702"},{"v":161104,"t":"161,104"},{"v":1.2519987089085312,"t":"125%"},{"v":62383,"t":"62,383"},{"v":0.44777094294389136,"t":"44.8%"},{"v":265000,"t":"265,000"},{"v":0.6396754716981132,"t":"64%"},{"v":297290,"t":"297,290"},{"v":447840,"t":"447,840"},{"v":-150550,"t":"-150,550"},{"v":-0.3361691675598428,"t":"-34%"}]},{"label":"Over last Year Month","kind":"growth","cells":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,{"v":-0.8607070468103608,"t":"-86.1%"},null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"Export","kind":"export","cells":[{"v":12195,"t":"12,195"},{"v":33197,"t":"33,197"},{"v":9937,"t":"9,937"},{"v":9937,"t":"9,937"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,{"v":0,"t":"-"},null,null,null,null,null,null,{"v":3111,"t":"3,111"},null,null,{"v":0,"t":"-"},{"v":0,"t":"0%"},null,null,null,null,null,null,null,null,null,{"v":55329,"t":"55,329"},null,{"v":55329,"t":"55,329"},null]},{"label":"GRAND TOTAL","kind":"grand","cells":[{"v":98654,"t":"98,654"},{"v":127672,"t":"127,672"},{"v":113410,"t":"113,410"},{"v":9937,"t":"9,937"},{"v":1223,"t":"1,223"},{"v":253,"t":"253"},{"v":0,"t":"-"},{"v":1714,"t":"1,714"},{"v":1646,"t":"1,646"},{"v":3382,"t":"3,382"},{"v":2617,"t":"2,617"},{"v":2048,"t":"2,048"},{"v":3809,"t":"3,809"},{"v":3127,"t":"3,127"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":159508,"t":"159,508"},{"v":161104,"t":"161,104"},{"v":21785,"t":"21,785"},{"v":-139319,"t":"-139,3~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~19"},{"v":-0.8647767901479789,"t":"-86%"},{"v":169514,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702,"t":"201,702"},{"v":161104,"t":"161,104"},{"v":1.2519987089085312,"t":"125%"},{"v":62383,"t":"62,383"},{"v":0.44777094294389136,"t":"44.8%"},{"v":265000,"t":"265,000"},{"v":0.6396754716981132,"t":"64%"},{"v":352619,"t":"352,619"},{"v":447840,"t":"447,840"},{"v":-95221,"t":"-95,221"},{"v":-0.2126228117184709,"t":"-21%"}]},{"label":"LMT","kind":"detail","cells":[{"v":188,"t":"188"},{"v":376,"t":"376"},{"v":578,"t":"578"},null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"Key AC","kind":"detail","cells":[{"v":10718,"t":"10718"},{"v":11543,"t":"11543"},{"v":7488,"t":"7488"},null,null,{"v":21,"t":"21"},null,null,null,{"v":141,"t":"141"},null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"HORECA","kind":"detail","cells":[{"v":372,"t":"372"},{"v":607,"t":"607"},{"v":630,"t":"630"},null,null,{"v":22,"t":"22"},null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]}]},{"id":"blend","title":"G.T Primary Sales BLEND WISE","reportDate":"2026-10-13","currentMonth":"2026-10","groups":[{"id":"history","label":"Previous months","columns":[0,1,2]},{"id":"daily","label":"Daily sales \u00b7 October 2026","columns":[3,4,5,6,7,8,9,10,11,12,13,14,15]},{"id":"month","label":"October 2026 performance","columns":[16,17,18,19,20]},{"id":"fg","label":"FG stock & warehouse","columns":[21,22,23,24,25,26,27,28]},{"id":"july-2026-todate","label":"YTD \u00b7 July 2026 Todate","columns":[29,30,31,32]}],"columns":[{"index":~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~0,"group":"history","kind":"month","label":"Primary Sales MTD July 2026","short":"Jul 2026","unit":"Kg","month":"2026-07"},{"index":1,"group":"history","kind":"month","label":"Primary Sales MTD Aug 2026","short":"Aug 2026","unit":"Kg","month":"2026-08"},{"index":2,"group":"history","kind":"month","label":"Primary Sales MTD 30 SEP 2026","short":"Sep 2026","unit":"Kg","month":"2026-09"},{"index":3,"group":"daily","kind":"day","label":"2026-10-01","short":"2026-10-01","unit":"Kg","date":"2026-10-01"},{"index":4,"group":"daily","kind":"day","label":"2026-10-02","short":"2026-10-02","unit":"Kg","date":"2026-10-02"},{"index":5,"group":"daily","kind":"day","label":"2026-10-03","short":"2026-10-03","unit":"Kg","date":"2026-10-03"},{"index":6,"group":"daily","kind":"day","label":"2026-10-04","short":"2026-10-04","unit":"","date":"2026-10-04"},{"index":7,"group":"daily","kind":"day","label":"2026-10-05","short":"2026-10-05","unit":"Kg","date":"2026-10-05"},{"index":8,"group":"daily","kind":"day","label":"2026-10-06","short":"2026-10-06","unit":"Kg","date":"2026-10-06"},{"index":9,"group":"daily","kind":"day","label":"2026-10-07","short":"2026-10-07","unit":"Kg","date":"2026-10-07"},{"index":10,"group":"daily","kind":"day","label":"2026-10-08","short":"2026-10-08","unit":"Kg","date":"2026-10-08"},{"index":11,"group":"daily","kind":"day","label":"2026-10-09","short":"2026-10-09","unit":"Kg","date":"2026-10-09"},{"index":12,"group":"daily","kind":"day","label":"2026-10-10","short":"2026-10-10","unit":"Kg","date":"2026-10-10"},{"index":13,"group":"daily","kind":"day","label":"2026-10-11","short":"2026-10-11","unit":"Kg","date":"2026-10-11"},{"index":14,"group":"daily","kind":"day","label":"2026-10-12","short":"2026-10-12","unit":"Kg","date":"2026-10-12"},{"index":15,"group":"daily","~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~kind":"day","label":"2026-10-13","short":"2026-10-13","unit":"Kg","date":"2026-10-13"},{"index":16,"group":"month","kind":"metric","label":"Primary Sales Oct 2025","short":"Primary Sales Oct 2025","unit":"Kg"},{"index":17,"group":"month","kind":"metric","label":"RSF Target Oct 2026","short":"RSF Target Oct 2026","unit":"Kg"},{"index":18,"group":"month","kind":"month","label":"Primary Sales MTD Oct 2026","short":"Oct 2026","unit":"Kg","month":"2026-10","isCurrentMonth":true},{"index":19,"group":"month","kind":"metric","label":"Remaining Vol","short":"Remaining Vol","unit":"Kg"},{"index":20,"group":"month","kind":"metric","label":"Achievement Vs Sep 26 RSF","short":"Achievement Vs Sep 26 RSF","unit":"%"},{"index":21,"group":"fg","kind":"metric","label":"FG","short":"FG","unit":"Kg"},{"index":22,"group":"fg","kind":"metric","label":"Transit","short":"Transit","unit":"Kg"},{"index":23,"group":"fg","kind":"metric","label":"Total SC","short":"Total SC","unit":"Kg"},{"index":24,"group":"fg","kind":"metric","label":"RSF Target Oct 2026","short":"RSF Target Oct 2026","unit":"Kg"},{"index":25,"group":"fg","kind":"metric","label":"FG Available against Oct RSF","short":"FG Available against Oct RSF","unit":"Kg"},{"index":26,"group":"fg","kind":"metric","label":"Additional Cover","short":"Additional Cover","unit":"Kg"},{"index":27,"group":"fg","kind":"metric","label":"Additional Cover","short":"Additional Cover","unit":"%"},{"index":28,"group":"fg","kind":"metric","label":"Remarks","short":"Remarks","unit":""},{"index":29,"group":"july-2026-todate","kind":"metric","label":"YTD Primary Sales","short":"YTD Primary Sales","unit":"Kg"},{"index":30,"group":"july-2026-todate","kind":"metric","label":"YTD RSF","short":"YTD RSF","unit":"Kg"},{"index":31,"group":"july-2026-todate","kind":"me~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~tric","label":"Over/ Under","short":"Over/ Under","unit":"Kg"},{"index":32,"group":"july-2026-todate","kind":"metric","label":"Achieve","short":"Achieve","unit":"%"}],"rows":[{"label":"AWAZ","kind":"item","cells":[{"v":6079,"t":"6,079"},{"v":992.7,"t":"993"},{"v":1706.7,"t":"1,707"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":10,"t":"10"},{"v":10,"t":"10"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":6972,"t":"6,972"},{"v":6966,"t":"6,966"},{"v":20,"t":"20"},{"v":-6946,"t":"-6,946"},{"v":0.002871088142405972,"t":"0%"},{"v":230,"t":"230"},{"v":0,"t":"-"},{"v":230,"t":"230"},{"v":6966,"t":"6,966"},{"v":0.03301751363766867,"t":"3%"},{"v":-6716,"t":"-6,716"},{"v":-0.9668874172185431,"t":"-97%"},{"v":"Being produced","t":"Being produced"},{"v":8778.899999999998,"t":"8,779"},{"v":22657,"t":"22,657"},{"v":-13878.100000000002,"t":"-13,878"},{"v":-0.6125303438231011,"t":"-61%"}]},{"label":"BAITHAK SACHET","kind":"item","cells":[{"v":1669.8,"t":"1,670"},{"v":1650.3,"t":"1,650"},{"v":676.5,"t":"676"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":3,"t":"3"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":2589,"t":"2,589"},{"v":1629,"t":"1,629"},{"v":3,"t":"3"},{"v":-1626,"t":"-1,626"},{"v":0.001841620626151013,"t":"0%"},{"v":2396,"t":"2,396"},{"v":0,"t":"-"},{"v":2396,"t":"2,396"},{"v":1629,"t":"1,629"},{"v":1.470841006752609,"t":"147%"},{"v":770,"t":"770"},{"v":0.4735547355473555,"t":"47%"},null,{"v":3996.6000000000004,"t":"3,997"},{"v":25405,"t":"25,405"},{"v":-21408.4,"t":"-21,408"},{"v":-0.8426845109230467,"t":"-84%"}]},{"label":"BAITHAK SINDH","kind":"item","cells":[{"v":2048~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~3.58,"t":"20,484"},{"v":27837.48,"t":"27,837"},{"v":28186.8,"t":"28,187"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":345.6,"t":"346"},{"v":77.1,"t":"77"},{"v":42,"t":"42"},{"v":249,"t":"249"},{"v":1530,"t":"1,530"},{"v":350,"t":"350"},{"v":704,"t":"704"},{"v":19,"t":"19"},{"v":0,"t":"-"},{"v":41286,"t":"41,286"},{"v":39344,"t":"39,344"},{"v":3316.7,"t":"3,317"},{"v":-36027.3,"t":"-36,027"},{"v":0.08430002033346888,"t":"8%"},{"v":54126,"t":"54,126"},{"v":0,"t":"-"},{"v":54126,"t":"54,126"},{"v":39344,"t":"39,344"},{"v":1.3757116714111428,"t":"138%"},{"v":18098.699999999997,"t":"18,099"},{"v":0.502360709795072,"t":"50%"},null,{"v":78751.56000000003,"t":"78,752"},{"v":98029,"t":"98,029"},{"v":-19277.439999999973,"t":"-19,277"},{"v":-0.19665037896948834,"t":"-20%"}]},{"label":"GREEN TEA BAG JASMINE.","kind":"item","cells":[{"v":2.25,"t":"2"},{"v":0,"t":"-"},{"v":10.5,"t":"10"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1.5,"t":"2"},{"v":3,"t":"3"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1,"t":"1"},{"v":0,"t":"-"},{"v":11,"t":"11"},{"v":8,"t":"8"},{"v":5.5,"t":"6"},{"v":-2.5,"t":"-2"},{"v":0.6875,"t":"69%"},{"v":119,"t":"119"},{"v":49,"t":"49"},{"v":168,"t":"168"},{"v":8,"t":"8"},{"v":21,"t":"2100%"},{"v":165.5,"t":"166"},{"v":66.2,"t":"6620%"},{"v":"Majority export FG","t":"Majority export FG"},{"v":18,"t":"18"},{"v":17.9600324159109,"t":"18"},{"v":0.03996758408910139,"t":"-"},{"v":0.002225362580843333,"t":"0%"}]},{"label":"GREEN TEA BAG LEMON.","kind":"item","cells":[{"v":30.75,"t":"31"},{"v":18.75,"t":"19"},{"v":36,"t":"36"},{"v":0,"t":"-"},{"v":1,"t":"1"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1.5,"t":"2"},{"v":3,"t":"3"},{"v":0,"t":"-"},{"v":5,"~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~t":"5"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":162,"t":"162"},{"v":85,"t":"85"},{"v":10.5,"t":"10"},{"v":-74.5,"t":"-74"},{"v":0.12352941176470589,"t":"12%"},{"v":136,"t":"136"},{"v":0,"t":"-"},{"v":136,"t":"136"},{"v":85,"t":"85"},{"v":1.6,"t":"160%"},{"v":61.5,"t":"62"},{"v":0.825503355704698,"t":"83%"},{"v":"Majority export FG","t":"Majority export FG"},{"v":90.75,"t":"91"},{"v":120.7333518188046,"t":"121"},{"v":-29.983351818804607,"t":"-30"},{"v":-0.2483435717398397,"t":"-25%"}]},{"label":"GREEN TEA BAG MINT.","kind":"item","cells":[{"v":5.25,"t":"5"},{"v":24,"t":"24"},{"v":4.5,"t":"4"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1.5,"t":"2"},{"v":1.5,"t":"2"},{"v":0,"t":"-"},{"v":2,"t":"2"},{"v":2,"t":"2"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":4,"t":"4"},{"v":8,"t":"8"},{"v":7,"t":"7"},{"v":-1,"t":"-1"},{"v":0.875,"t":"88%"},{"v":95,"t":"95"},{"v":11,"t":"11"},{"v":106,"t":"106"},{"v":8,"t":"8"},{"v":13.25,"t":"1325%"},{"v":105,"t":"105"},{"v":105,"t":"10500%"},{"v":"Majority export FG","t":"Majority export FG"},{"v":36.75,"t":"37"},{"v":11.522436857851822,"t":"12"},{"v":25.227563142148178,"t":"25"},{"v":2.1894294977157687,"t":"219%"}]},{"label":"GREEN TEA BAG PURE.","kind":"item","cells":[{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":6,"t":"6"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1.5,"t":"2"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":90,"t":"90"},{"v":2,"t":"2"},{"v":1.5,"t":"2"},{"v":-0.5,"t":"-"},{"v":0.75,"t":"75%"},{"v":71,"t":"71"},{"v":32,"t":"32"},{"v":103,"t":"103"},{"v":2,"t":"2"},{"v":51.5,"t":"5150%"},{"v":102.5,"t":"102"},{"v":205,"t":"20500%"},{"v":"Majority export FG",~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~"t":"Majority export FG"},{"v":7.5,"t":"8"},{"v":5.522436857851826,"t":"6"},{"v":1.977563142148174,"t":"2"},{"v":0.35809610739803494,"t":"36%"}]},{"label":"GREEN TEA JAR JASMINE.","kind":"item","cells":[{"v":0,"t":"-"},{"v":12,"t":"12"},{"v":9,"t":"9"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":27,"t":"27"},{"v":0,"t":"-"},{"v":-27,"t":"-27"},{"v":0,"t":"0%"},{"v":23,"t":"23"},{"v":0,"t":"-"},{"v":23,"t":"23"},{"v":27,"t":"27"},{"v":0.8518518518518519,"t":"85%"},{"v":-4,"t":"-4"},{"v":-0.14814814814814814,"t":"-15%"},null,{"v":21,"t":"21"},{"v":79.47845858212595,"t":"79"},{"v":-58.47845858212595,"t":"-58"},{"v":-0.7357774625397336,"t":"-74%"}]},{"label":"GREEN TEA JAR LEMON.","kind":"item","cells":[{"v":27,"t":"27"},{"v":0,"t":"-"},{"v":18,"t":"18"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":93,"t":"93"},{"v":0,"t":"-"},{"v":-93,"t":"-93"},{"v":0,"t":"0%"},{"v":51,"t":"51"},{"v":0,"t":"-"},{"v":51,"t":"51"},{"v":93,"t":"93"},{"v":0.5483870967741935,"t":"55%"},{"v":-42,"t":"-42"},{"v":-0.45161290322580644,"t":"-45%"},null,{"v":45,"t":"45"},{"v":179.0720777215098,"t":"179"},{"v":-134.0720777215098,"t":"-134"},{"v":-0.7487045408051649,"t":"-75%"}]},{"label":"HARDAM MIXTURE","kind":"item","cells":[{"v":703.2,"t":"703"},{"v":118.8,"t":"119"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":1611,"t":"1,611"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"0%"},{"v":632,"t":"632"},{"v":0,"t":"-"},{"v":632,"t":"632"},{"v":0,"t":"-"},{"v":0,"t":"0%"},{"v":632,"t":"632"},{"v":0,"t":"0%"},null,{"v":822.0000000000001,"t":"822"},{"v":989,"t":"989"},{"v":-166.9999999999999,"t":"-167"},{"v":-0.16885743174924153,"t":"-17%"}]},{"label":"ULTRA DANEDAR","kind":"item","cells":[{"v":108.6,"t":"109"},{"v":28.8,"t":"29"},{"v":165,"t":"165"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":4951,"t":"4,951"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"0%"},{"v":2681.38,"t":"2,681"},{"v":0,"t":"-"},{"v":2681.38,"t":"2,681"},{"v":0,"t":"-"},{"v":0,"t":"0%"},{"v":2681.38,"t":"2,681"},{"v":0,"t":"0%"},null,{"v":302.4,"t":"302"},{"v":0,"t":"-"},{"v":302.4,"t":"302"},{"v":0,"t":"0%"}]},{"label":"ULTRA RICH MEZAN K Blend","kind":"item","cells":[{"v":2047,"t":"2,047"},{"v":4051.44,"t":"4,051"},{"v":3069.12,"t":"3,069"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":10.32,"t":"10"},{"v":13,"t":"13"},{"v":474.72,"t":"475"},{"v":34.08,"t":"34"},{"v":0,"t":"-"},{"v":10,"t":"10"},{"v":65,"t":"65"},{"v":44,"t":"44"},{"v":0,"t":"-"},{"v":2308,"t":"2,308"},{"v":0,"t":"-"},{"v":651.12,"t":"651"},{"v":651.12,"t":"651"},{"v":0,"t":"0%"},{"v":11399,"t":"11,399"},{"v":0,"t":"-"},{"v":11399,"t":"11,399"},{"v":0,"t":"-"},{"v":null,"t":"\u2014"},{"v":12050.12,"t":"12,050"},{"v":-18.506757586927144,"t":"-1851%"},{"v":"Majority BRC,METRO,Multan","t":"Majority BRC,METRO,Multan"},{"v":9698.148,"t":"9,698"},{"v":10317,"t":"10,317"},{"v"~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~:-618.8520000000008,"t":"-619"},{"v":-0.059983716196568844,"t":"-6%"}]},{"label":"ULTRA RICH PUNJAB","kind":"item","cells":[{"v":28547.71,"t":"28,548"},{"v":31604.54,"t":"31,605"},{"v":42588.06,"t":"42,588"},{"v":0,"t":"-"},{"v":77,"t":"77"},{"v":160.15,"t":"160"},{"v":0,"t":"-"},{"v":537.8,"t":"538"},{"v":1143.94,"t":"1,144"},{"v":2094.35,"t":"2,094"},{"v":1228.66,"t":"1,229"},{"v":182.04,"t":"182"},{"v":605,"t":"605"},{"v":1657,"t":"1,657"},{"v":1182,"t":"1,182"},{"v":0,"t":"-"},{"v":56683,"t":"56,683"},{"v":59365,"t":"59,365"},{"v":8867.939999999999,"t":"8,868"},{"v":-50497.06,"t":"-50,497"},{"v":0.14937993767371344,"t":"15%"},{"v":69022,"t":"69,022"},{"v":23190,"t":"23,190"},{"v":92212,"t":"92,212"},{"v":59365,"t":"59,365"},{"v":1.5533058199275667,"t":"155%"},{"v":41714.94,"t":"41,715"},{"v":0.8260865087987301,"t":"83%"},null,{"v":108164.05010039987,"t":"108,164"},{"v":148204,"t":"148,204"},{"v":-40039.949899600135,"t":"-40,040"},{"v":-0.2701678085584744,"t":"-27%"}]},{"label":"ULTRA RICH SACHET","kind":"item","cells":[{"v":2839.1,"t":"2,839"},{"v":2841.5,"t":"2,842"},{"v":3490.4,"t":"3,490"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":49.5,"t":"50"},{"v":0,"t":"-"},{"v":86.5,"t":"86"},{"v":30.4,"t":"30"},{"v":219.6,"t":"220"},{"v":223.8,"t":"224"},{"v":33,"t":"33"},{"v":0,"t":"-"},{"v":67,"t":"67"},{"v":17,"t":"17"},{"v":0,"t":"-"},{"v":4579,"t":"4,579"},{"v":4991,"t":"4,991"},{"v":726.8,"t":"727"},{"v":-4264.2,"t":"-4,264"},{"v":0.1456221198156682,"t":"15%"},{"v":3573,"t":"3,573"},{"v":367,"t":"367"},{"v":3940,"t":"3,940"},{"v":4991,"t":"4,991"},{"v":0.789420957723903,"t":"79%"},{"v":-324.1999999999998,"t":"-324"},{"v":-0.07602832887763235,"t":"-8%"},null,{"v":9813.9,"t":"9,814"},{"v":15689,"t":"15,689"},{"v":-5875.1,"t":"-5,875"},{"v":-0.3744725603926318,"t":"-37%"}]},{~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~"label":"ULTRA RICH T.B","kind":"item","cells":[{"v":454.6,"t":"455"},{"v":251.2,"t":"251"},{"v":492.8,"t":"493"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":96,"t":"96"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":6,"t":"6"},{"v":54,"t":"54"},{"v":0,"t":"-"},{"v":552,"t":"552"},{"v":282,"t":"282"},{"v":156,"t":"156"},{"v":-126,"t":"-126"},{"v":0.5531914893617021,"t":"55%"},{"v":1198,"t":"1,198"},{"v":166,"t":"166"},{"v":1364,"t":"1,364"},{"v":282,"t":"282"},{"v":4.836879432624113,"t":"484%"},{"v":1238,"t":"1,238"},{"v":9.825396825396826,"t":"983%"},{"v":"Majority export FG","t":"Majority export FG"},{"v":1294.6,"t":"1,295"},{"v":841,"t":"841"},{"v":453.5999999999999,"t":"454"},{"v":0.5393579072532698,"t":"54%"}]},{"label":"UR/HD STRONG","kind":"item","cells":[{"v":12183,"t":"12,183"},{"v":12517.5,"t":"12,518"},{"v":14317.8,"t":"14,318"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":733.2,"t":"733"},{"v":381.9,"t":"382"},{"v":403.8,"t":"404"},{"v":511.2,"t":"511"},{"v":210,"t":"210"},{"v":120,"t":"120"},{"v":614,"t":"614"},{"v":649,"t":"649"},{"v":0,"t":"-"},{"v":27006,"t":"27,006"},{"v":26795,"t":"26,795"},{"v":3623.1,"t":"3,623"},{"v":-23171.9,"t":"-23,172"},{"v":0.135215525284568,"t":"14%"},{"v":23762,"t":"23,762"},{"v":8373,"t":"8,373"},{"v":32135,"t":"32,135"},{"v":26795,"t":"26,795"},{"v":1.1992909124836724,"t":"120%"},{"v":8963.099999999999,"t":"8,963"},{"v":0.38680902299768244,"t":"39%"},null,{"v":41258.40000000002,"t":"41,258"},{"v":69296,"t":"69,296"},{"v":-28037.599999999977,"t":"-28,038"},{"v":-0.40460632648349076,"t":"-40%"}]},{"label":"National G.T Primary Sales","kind":"subtotal","cells":[{"v":75180.84,"t":"75,181"},{"v":81949.01,"t":"81,949"},{"v":94777.18,"t":"94,77~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~7"},{"v":0,"t":"-"},{"v":78,"t":"78"},{"v":209.65,"t":"210"},{"v":0,"t":"-"},{"v":1713.42,"t":"1,713"},{"v":1646.3400000000001,"t":"1,646"},{"v":3240.47,"t":"3,240"},{"v":2350.24,"t":"2,350"},{"v":1955.04,"t":"1,955"},{"v":1102,"t":"1,102"},{"v":3128,"t":"3,128"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":148804,"t":"148,804"},{"v":139595,"t":"139,595"},{"v":17389.159999999996,"t":"17,389"},{"v":-122205.84,"t":"-122,206"},{"v":0.12456864500877536,"t":"12%"},{"v":169514.38,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702.38,"t":"201,702"},{"v":139595,"t":"139,595"},{"v":1.4449112074214694,"t":"144%"},{"v":79496.54000000001,"t":"79,497"},{"v":0.6505134288181319,"t":"65%"},null,{"v":263099.5581003999,"t":"263,100"},{"v":391841.28879425407,"t":"391,841"},{"v":-128741.73069385416,"t":"-128,742"},{"v":-0.32855580658691935,"t":"-33%"}]},{"label":"Other Channels (LMT, Key AC)","kind":"channel","cells":[{"v":10906.1,"t":"10,906"},{"v":11919.29,"t":"11,919"},{"v":8066.21,"t":"8,066"},{"v":0,"t":"-"},{"v":1145,"t":"1,145"},{"v":21.12,"t":"21"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":141,"t":"141"},{"v":267,"t":"267"},{"v":0,"t":"-"},{"v":2707,"t":"2,707"},{"v":0,"t":"-"},null,null,{"v":6647,"t":"6,647"},{"v":20007,"t":"20,007"},{"v":4281.12,"t":"4,281"},{"v":-15725.880000000001,"t":"-15,726"},{"v":0.21398110661268555,"t":"21%"},null,null,null,{"v":20007,"t":"20,007"},null,null,null,null,{"v":34190,"t":"34,190"},{"v":55999,"t":"55,999"},{"v":47497,"t":"47,497"},{"v":0.8481758602832193,"t":"85%"}]},{"label":"Instituitons","kind":"channel","cells":[{"v":372.36,"t":"372"},{"v":607.44,"t":"607"},{"v":629.74,"t":"630"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":21.6,"t":"22"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":92.88,"t":"93"},~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~null,{"v":0,"t":"-"},null,null,{"v":946,"t":"946"},{"v":1502,"t":"1,502"},{"v":114.47999999999999,"t":"114"},null,null,null,null,null,{"v":1502,"t":"1,502"},null,null,null,null,null,null,null,null]},{"label":"Ecommerce","kind":"channel","cells":[null,null,null,null,null,{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,{"v":0,"t":"-"},{"v":0,"t":"-"},null,null,null,null,null,null,null,{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"0%"},null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"TOTAL","kind":"total","cells":[{"v":86459.3,"t":"86,459"},{"v":94475.73999999999,"t":"94,476"},{"v":103473.13,"t":"103,473"},{"v":0,"t":"-"},{"v":1223,"t":"1,223"},{"v":252.37,"t":"252"},{"v":0,"t":"-"},{"v":1713.42,"t":"1,713"},{"v":1646.3400000000001,"t":"1,646"},{"v":3381.47,"t":"3,381"},{"v":2617.24,"t":"2,617"},{"v":2047.92,"t":"2,048"},{"v":3809,"t":"3,809"},{"v":3128,"t":"3,128"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":156397,"t":"156,397"},{"v":161104,"t":"161,104"},{"v":21784.759999999995,"t":"21,785"},{"v":-139319.24,"t":"-139,319"},{"v":0.1352217201310954,"t":"14%"},{"v":169514.38,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702.38,"t":"201,702"},{"v":161104,"t":"161,104"},{"v":1.25200106763333,"t":"125%"},{"v":62383.140000000014,"t":"62,383"},{"v":0.44777117647210835,"t":"45%"},null,{"v":297289.5581003999,"t":"297,290"},{"v":447840.28879425407,"t":"447,840"},{"v":-150550.73069385416,"t":"-150,551"},{"v":-0.3361705823725473,"t":"-34%"}]},{"label":"Over last Year Month","kind":"growth","cells":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,{"v":-0.8607085813666502,"t":"-86.1%"},null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null]},{"label":"Export","kind":"export","cells":[{"v":12195,"t":"1~'));
  DBMS_LOB.APPEND(l_json, TO_CLOB(q'~2,195"},{"v":33197,"t":"33,197"},{"v":9937,"t":"9,937"},{"v":9937,"t":"9,937"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},{"v":0,"t":"-"},null,{"v":0,"t":"-"},null,null,null,null,null,null,{"v":3111,"t":"3,111"},null,null,{"v":0,"t":"-"},{"v":0,"t":"0.0%"},null,null,null,null,null,null,null,null,{"v":55329,"t":"55,329"},null,{"v":55329,"t":"55,329"},null]},{"label":"GRAND TOTAL","kind":"grand","cells":[{"v":98654.3,"t":"98,654"},{"v":127672.73999999999,"t":"127,673"},{"v":113410.13,"t":"113,410"},{"v":9937,"t":"9,937"},{"v":1223,"t":"1,223"},{"v":252.37,"t":"252"},{"v":0,"t":"-"},{"v":1713.42,"t":"1,713"},{"v":1646.3400000000001,"t":"1,646"},{"v":3381.47,"t":"3,381"},{"v":2617.24,"t":"2,617"},{"v":2047.92,"t":"2,048"},{"v":3809,"t":"3,809"},{"v":3128,"t":"3,128"},{"v":1966,"t":"1,966"},{"v":0,"t":"-"},{"v":159508,"t":"159,508"},{"v":161104,"t":"161,104"},{"v":21784.759999999995,"t":"21,785"},{"v":-139319.24,"t":"-139,319"},{"v":-0.8647782798689045,"t":"-86%"},{"v":169514.38,"t":"169,514"},{"v":32188,"t":"32,188"},{"v":201702.38,"t":"201,702"},{"v":161104,"t":"161,104"},{"v":1.25200106763333,"t":"125%"},{"v":62383.140000000014,"t":"62,383"},{"v":0.44777117647210835,"t":"45%"},null,{"v":352618.5581003999,"t":"352,619"},{"v":447840.28879425407,"t":"447,840"},{"v":-95221.73069385416,"t":"-95,222"},{"v":-0.21262430620126888,"t":"-21%"}]}]}],"updatedAt":"2026-10-13T00:00:00.000Z","source":"Sample data extracted from Dashboard.xlsx"}~'));
  l_res := dash_api.import_dashboard(l_json, 'Imported from Dashboard.xlsx');
  DBMS_OUTPUT.PUT_LINE(DBMS_LOB.SUBSTR(l_res, 200, 1));
  COMMIT;
END;
/
