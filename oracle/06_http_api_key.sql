-- =====================================================================================
-- OPTIONAL - only if ORDS is served over plain HTTP (http://tapex.mezangrp.com/ords).
-- ORDS issues OAuth2 tokens over HTTPS only, so on HTTP the endpoints are protected with an
-- API key sent in the "X-API-Key" header instead. Run AFTER scripts 01-04 (and 05 if loading data).
-- If you already ran the OAuth block of 04_ords_module.sql, this script removes its privilege
-- mappings (otherwise ORDS would still demand an OAuth token).
--
-- NOTE: on plain HTTP the key travels unencrypted. Use only on a trusted network, or put HTTPS
-- (e.g. an nginx reverse proxy) in front of ORDS and use OAuth instead.
-- =====================================================================================

CREATE TABLE dash_api_key (
  scope      VARCHAR2(10) CONSTRAINT dash_api_key_pk PRIMARY KEY
                          CONSTRAINT dash_api_key_ck CHECK (scope IN ('read', 'write')),
  key_value  VARCHAR2(100) NOT NULL,
  created_at TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL
);

-- one random key per scope: "read" can call GET /dash/dashboard/*, "write" can call everything
INSERT INTO dash_api_key (scope, key_value) VALUES ('read',  LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID())));
INSERT INTO dash_api_key (scope, key_value) VALUES ('write', LOWER(RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID())));
COMMIT;

CREATE OR REPLACE PACKAGE dash_auth AS
  PROCEDURE check_key (p_scope VARCHAR2, p_key VARCHAR2);   -- raises -20401 when the key is missing / wrong
END dash_auth;
/
CREATE OR REPLACE PACKAGE BODY dash_auth AS
  PROCEDURE check_key (p_scope VARCHAR2, p_key VARCHAR2) IS
    l_n NUMBER;
  BEGIN
    IF p_key IS NULL THEN
      raise_application_error(-20401, 'Missing or invalid API key');
    END IF;
    SELECT COUNT(*) INTO l_n FROM dash_api_key
     WHERE key_value = p_key AND (scope = p_scope OR scope = 'write');
    IF l_n = 0 THEN
      raise_application_error(-20401, 'Missing or invalid API key');
    END IF;
  END;
END dash_auth;
/

-- remove OAuth protection if the security block of 04 was already run (ignore "not found" errors)
BEGIN
  BEGIN ORDS.DELETE_PRIVILEGE_MAPPING(p_privilege_name => 'dash.read',  p_pattern => '/dash/dashboard/*'); EXCEPTION WHEN OTHERS THEN NULL; END;
  BEGIN ORDS.DELETE_PRIVILEGE_MAPPING(p_privilege_name => 'dash.write', p_pattern => '/dash/manage/*');    EXCEPTION WHEN OTHERS THEN NULL; END;
  COMMIT;
END;
/

-- re-define the handlers so each one checks the X-API-Key header first
DECLARE
  c_mod CONSTANT VARCHAR2(30) := 'dash';

  PROCEDURE secure (p_pattern VARCHAR2, p_method VARCHAR2, p_scope VARCHAR2, p_call VARCHAR2, p_status NUMBER DEFAULT 200) IS
    l_src VARCHAR2(4000);
  BEGIN
    l_src := 'DECLARE l_out CLOB; BEGIN dash_auth.check_key(''' || p_scope || ''', :api_key); ' || p_call ||
             ' :status_code := ' || p_status || ';' ||
             ' owa_util.mime_header(''application/json'', TRUE, ''utf-8'');' ||
             ' dash_api.print_clob(l_out);' ||
             ' EXCEPTION WHEN OTHERS THEN' ||
             ' :status_code := CASE WHEN SQLCODE = -20401 THEN 401 ELSE dash_api.http_status(SQLCODE) END;' ||
             ' dash_api.print_error(SQLCODE, SQLERRM);' ||
             ' END;';
    ORDS.DEFINE_HANDLER(p_module_name => c_mod, p_pattern => p_pattern, p_method => p_method,
                        p_source_type => ORDS.source_type_plsql, p_items_per_page => 0, p_source => l_src);
    ORDS.DEFINE_PARAMETER(p_module_name => c_mod, p_pattern => p_pattern, p_method => p_method,
                          p_name => 'X-API-Key', p_bind_variable_name => 'api_key',
                          p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  END;
BEGIN
  secure('dashboard/',              'GET',    'read',  'l_out := dash_api.dashboard_json(NULL);');
  secure('dashboard/:report_id',    'GET',    'read',  'l_out := dash_api.dashboard_json(TO_NUMBER(:report_id));');
  secure('manage/dashboard',        'POST',   'write', 'l_out := dash_api.post_dashboard(dash_api.blob_to_clob(:body));');
  secure('manage/reports/',         'GET',    'write', 'l_out := dash_api.list_reports;');
  secure('manage/import',           'POST',   'write', 'l_out := dash_api.import_dashboard(dash_api.blob_to_clob(:body), :name);', 201);
  secure('manage/columns/:column_id','DELETE','write', 'l_out := dash_api.delete_column(TO_NUMBER(:column_id));');
  secure('manage/rows/:row_id',     'DELETE', 'write', 'l_out := dash_api.delete_row(TO_NUMBER(:row_id));');
  COMMIT;
END;
/

-- Your keys: the READ key goes into the Next.js .env as ORDS_API_KEY; keep the WRITE key for data entry.
SELECT scope, key_value FROM dash_api_key ORDER BY scope;
