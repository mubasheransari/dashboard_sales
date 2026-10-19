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
