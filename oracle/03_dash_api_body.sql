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
