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
