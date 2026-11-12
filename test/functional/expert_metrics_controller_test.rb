require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class ExpertMetricsControllerTest < Redmine::ControllerTest
  fixtures :users, :email_addresses, :tokens, :projects, :trackers, :projects_trackers,
           :issue_statuses, :issues, :enumerations, :issue_categories, :versions

  def setup
    User.current = nil
    Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)
    Token.where(:action => 'session').delete_all
    ExpertMetricsCounter.delete_all
    ExpertMetricsApiUsage.delete_all
    # Recording is opt-in; these tests exercise it switched on.
    Setting.plugin_redmine_expert_metrics = { 'api_usage_enabled' => '1' }
  end

  def teardown
    Setting.plugin_redmine_expert_metrics = { 'api_usage_enabled' => '0' }
  end

  # --- /metrics -----------------------------------------------------------

  def test_prometheus_is_open_without_configured_token
    session_token(2, 2.minutes.ago)

    get :prometheus
    assert_response :success
    assert_match %r{\Atext/plain; version=0\.0\.4}, response.content_type
    assert_includes response.body, "redmine_active_users{window=\"5m\"} 1\n"
    assert_includes response.body, 'redmine_info{'
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  def test_prometheus_never_lists_user_names
    session_token(2, 2.minutes.ago)

    get :prometheus
    assert_response :success
    assert_not_includes response.body, User.find(2).login
    assert_not_includes response.body, User.find(2).name
  end

  def test_prometheus_works_with_login_required
    with_settings :login_required => '1' do
      get :prometheus
      assert_response :success
      assert_includes response.body, 'redmine_active_users'
    end
  end

  def test_prometheus_requires_configured_token
    Redmine::Configuration.with('metrics_token' => 'top-secret') do
      get :prometheus
      assert_response 401
      assert_match(/Bearer/, response.headers['WWW-Authenticate'])

      @request.headers['Authorization'] = 'Bearer wrong'
      get :prometheus
      assert_response 401

      @request.headers['Authorization'] = 'Bearer top-secret'
      get :prometheus
      assert_response :success
    end
  end

  def test_prometheus_accepts_token_as_query_param
    Redmine::Configuration.with('metrics_token' => 'top-secret') do
      get :prometheus, :params => { :token => 'top-secret' }
      assert_response :success
    end
  end

  def test_prometheus_accepts_admin_session_despite_token
    Redmine::Configuration.with('metrics_token' => 'top-secret') do
      @request.session[:user_id] = 1
      get :prometheus
      assert_response :success

      @request.session[:user_id] = 2
      get :prometheus
      assert_response 401
    end
  end

  def test_prometheus_accepts_admin_api_key_despite_token
    Redmine::Configuration.with('metrics_token' => 'top-secret') do
      with_settings :rest_api_enabled => '1' do
        @request.headers['X-Redmine-API-Key'] = User.find(1).api_key
        get :prometheus
        assert_response :success

        @request.headers['X-Redmine-API-Key'] = User.find(2).api_key
        get :prometheus
        assert_response 401
      end
    end
  end

  # --- /admin/active_users ---------------------------------------------------

  def test_active_users_requires_login
    get :active_users
    assert_response :found
    assert_redirected_to %r{/login}
  end

  def test_active_users_denies_non_admin
    @request.session[:user_id] = 2
    get :active_users
    assert_response :forbidden
  end

  def test_active_users_html_lists_users_with_recent_sessions
    session_token(2, 3.minutes.ago)
    session_token(3, 90.minutes.ago)
    @request.session[:user_id] = 1

    get :active_users
    assert_response :success
    assert_select 'table.list.expert-metrics-active-users tbody tr', 1
    assert_select 'table.list td.username a', :text => 'jsmith'
    assert_select 'table.list td.username a', :text => 'dlopper', :count => 0
    assert_select 'div.box li strong', :text => '1'
    assert_select 'meta[http-equiv=refresh]'
  end

  def test_active_users_html_shows_nodata_when_nobody_is_active
    @request.session[:user_id] = 1
    get :active_users
    assert_response :success
    assert_select 'p.nodata'
  end

  def test_active_users_json_via_admin_api_key
    session_token(2, 3.minutes.ago)

    with_settings :rest_api_enabled => '1' do
      get :active_users, :params => { :format => 'json', :key => User.find(1).api_key }
    end
    assert_response :success
    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 60, json['window_minutes']
    assert_equal 1, json['summary']['active_users']['5m']
    assert_equal 1, json['active_users'].size
    assert_equal 'jsmith', json['active_users'].first['login']
    assert_equal 1, json['active_users'].first['sessions']
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, json['active_users'].first['last_activity'])
  end

  def test_active_users_json_denies_non_admin_api_key
    with_settings :rest_api_enabled => '1' do
      get :active_users, :params => { :format => 'json', :key => User.find(2).api_key }
    end
    assert_response :forbidden
  end

  # --- /admin/api_usage --------------------------------------------------

  def test_api_usage_requires_admin
    @request.session[:user_id] = 2
    get :api_usage
    assert_response :forbidden
  end

  def test_api_usage_html_lists_users_and_unused_keys
    User.find(3).api_key
    record_api_use(2, 'GET', 'python-requests/2.32')
    record_api_use(2, 'DELETE', 'python-requests/2.32', 'password')
    @request.session[:user_id] = 1

    get :api_usage
    assert_response :success
    assert_select 'table.expert-metrics-api-usage tbody tr', 1
    assert_select 'table.expert-metrics-api-usage td.username a', :text => 'jsmith'
    assert_select 'table.expert-metrics-api-usage td.clients code', :text => 'python-requests/2.32'
    assert_select 'table.expert-metrics-api-usage .expert-metrics-password'
    assert_select 'table.expert-metrics-unused-keys td.username a', :text => 'dlopper'
  end

  def test_api_usage_page_says_when_recording_is_off
    Setting.plugin_redmine_expert_metrics = { 'api_usage_enabled' => '0' }
    @request.session[:user_id] = 1
    get :api_usage
    assert_response :success
    assert_select 'p.warning a[href=?]', '/settings/plugin/redmine_expert_metrics'
  end

  def test_plugin_settings_page_renders_the_switch
    @request.session[:user_id] = 1
    @controller = SettingsController.new
    get :plugin, :params => { :id => 'redmine_expert_metrics' }
    assert_response :success
    assert_select 'input[type=checkbox][name=?][checked]', 'settings[api_usage_enabled]'
    assert_select '#settings_api_usage_enabled', 1
  end

  def test_api_usage_falls_back_to_default_period
    @request.session[:user_id] = 1
    get :api_usage, :params => { :days => '12345' }
    assert_response :success
    assert_select 'p.expert-metrics-api-days strong', :text => '7 days'
  end

  def test_api_usage_json_via_admin_api_key
    record_api_use(2, 'POST', 'n8n')

    with_settings :rest_api_enabled => '1' do
      get :api_usage, :params => { :format => 'json', :days => '30', :key => User.find(1).api_key }
    end
    assert_response :success
    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 30, json['days']
    assert_equal 90, json['retention_days']
    jsmith = json['users'].detect { |u| u['login'] == 'jsmith' }
    assert_equal 1, jsmith['writes']
    assert_equal({ 'n8n' => 1 }, jsmith['clients'])
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, jsmith['last_used'])
  end

  def test_api_usage_json_denies_non_admin_api_key
    with_settings :rest_api_enabled => '1' do
      get :api_usage, :params => { :format => 'json', :key => User.find(2).api_key }
    end
    assert_response :forbidden
  end

  # --- /admin/slow_requests ---------------------------------------------------

  def test_slow_requests_requires_admin
    @request.session[:user_id] = 2
    get :slow_requests
    assert_response :forbidden
  end

  def test_slow_requests_html_lists_rows_and_summary
    ExpertMetricsSlowRequest.delete_all
    record_slow_request('issues', 'show', 3200, Time.now - 1.hour)
    record_slow_request('issues', 'show', 2100, Time.now - 2.hours, false)
    record_slow_request('issues', 'index', 2500, Time.now - 3.days)
    @request.session[:user_id] = 1

    get :slow_requests
    assert_response :success
    assert_select 'table.expert-metrics-slow-summary tbody tr', 1
    assert_select 'table.expert-metrics-slow-summary td.name code', :text => 'issues#show'
    assert_select 'table.expert-metrics-slow-requests tbody tr', 2
    assert_select 'table.expert-metrics-slow-requests th', :text => 'User'
    assert_select 'table.expert-metrics-slow-requests td.username a', :text => 'jsmith'
    assert_select 'table.expert-metrics-slow-requests details li code', :text => 'SELECT * FROM issues WHERE id = ?'
    # One row was stored by a version without frequent_sql: no list, no error.
    assert_select 'table.expert-metrics-slow-requests ul.expert-metrics-frequent-sql', 1
    assert_select 'ul.expert-metrics-frequent-sql li', :text => /919× from the database, 13× from the query cache/
    assert_select 'ul.expert-metrics-frequent-sql li em', :text => 'Checklist Load'
    assert_select 'p.warning a[href=?]', '/settings/plugin/redmine_expert_metrics'

    get :slow_requests, :params => { :days => '7' }
    assert_select 'table.expert-metrics-slow-requests tbody tr', 3
  end

  def test_slow_requests_json_via_admin_api_key
    ExpertMetricsSlowRequest.delete_all
    record_slow_request('issues', 'show', 3200, Time.now - 1.hour)

    with_settings :rest_api_enabled => '1' do
      get :slow_requests, :params => { :format => 'json', :key => User.find(1).api_key }
    end
    assert_response :success
    json = ActiveSupport::JSON.decode(response.body)
    assert_equal 1, json['days']
    assert_equal ExpertMetricsSlowRequest::RETENTION_DAYS, json['retention_days']
    assert_equal 1, json['summary'].size
    request = json['requests'].first
    assert_equal 'show', request['action']
    assert_equal 3200, request['duration_ms']
    assert_equal 'SELECT * FROM issues WHERE id = ?', request['top_sql'].first['sql']
    assert_equal 919, request['frequent_sql'].first['count']
    assert_equal 'Checklist Load', request['frequent_sql'].first['name']
    assert_equal 'jsmith', request['user']
  end

  SLOW_TOKEN = '0123456789abcdef0123456789abcdef-slow'.freeze

  def test_slow_requests_json_with_token_needs_no_account
    ExpertMetricsSlowRequest.delete_all
    record_slow_request('issues', 'show', 3200, Time.now - 1.hour)
    Setting.plugin_redmine_expert_metrics = { 'slow_requests_token' => SLOW_TOKEN }

    # With "Authentication required" on, whether or not the REST API is: while
    # it is on, core first offers the Bearer token to OAuth (Redmine 6.1+).
    %w(0 1).each do |rest_api|
      with_settings :login_required => '1', :rest_api_enabled => rest_api do
        @request.headers['Authorization'] = "Bearer #{SLOW_TOKEN}"
        get :slow_requests, :params => { :format => 'json', :days => '7' }
      end
      assert_response :success, "REST API #{rest_api}"
      json = ActiveSupport::JSON.decode(response.body)
      assert_equal 7, json['days']
      assert_equal 3200, json['requests'].first['duration_ms']
      assert_equal 'Checklist Load', json['requests'].first['frequent_sql'].first['name']
      assert_nil session[:user_id]
    end
  end

  def test_slow_requests_json_rejects_a_missing_or_wrong_token
    Setting.plugin_redmine_expert_metrics = { 'slow_requests_token' => SLOW_TOKEN }
    # Core answers 401 while the REST API is on, 403 while it is off.
    with_settings :login_required => '1', :rest_api_enabled => '1' do
      get :slow_requests, :params => { :format => 'json' }
      assert_response 401

      # Not as a query parameter: that would end up in proxy and access logs.
      get :slow_requests, :params => { :format => 'json', :token => SLOW_TOKEN }
      assert_response 401

      @request.headers['Authorization'] = "Bearer #{SLOW_TOKEN}x"
      get :slow_requests, :params => { :format => 'json' }
      assert_response 401
    end
  end

  def test_slow_requests_token_shorter_than_the_minimum_is_ignored
    short = 'x' * (ExpertMetricsSlowRequest::TOKEN_MIN_LENGTH - 1)
    Setting.plugin_redmine_expert_metrics = { 'slow_requests_token' => short }
    assert_nil ExpertMetricsSlowRequest.access_token

    @request.headers['Authorization'] = "Bearer #{short}"
    with_settings :rest_api_enabled => '1' do
      get :slow_requests, :params => { :format => 'json' }
    end
    assert_response 401
  end

  def test_slow_requests_token_opens_nothing_but_the_slow_requests_json
    Setting.plugin_redmine_expert_metrics = { 'slow_requests_token' => SLOW_TOKEN }
    @request.headers['Authorization'] = "Bearer #{SLOW_TOKEN}"

    get :slow_requests
    assert_response 302
    assert_match %r{/login}, response.location

    with_settings :rest_api_enabled => '1' do
      get :api_usage, :params => { :format => 'json' }
      assert_response 401

      get :active_users, :params => { :format => 'json' }
      assert_response 401
    end
  end

  def test_plugin_settings_page_warns_about_a_token_that_is_too_short
    Setting.plugin_redmine_expert_metrics = { 'slow_requests_token' => 'test' }
    @request.session[:user_id] = 1
    @controller = SettingsController.new
    get :plugin, :params => { :id => 'redmine_expert_metrics' }
    assert_response :success
    assert_select 'input[name=?][value=?]', 'settings[slow_requests_token]', 'test'
    assert_select 'strong.expert-metrics-token-too-short', 1
  end

  def test_plugin_settings_page_renders_the_performance_settings
    @request.session[:user_id] = 1
    @controller = SettingsController.new
    get :plugin, :params => { :id => 'redmine_expert_metrics' }
    assert_response :success
    assert_select '#settings_performance_metrics_enabled', 1
    assert_select 'input[name=?][value=?]', 'settings[slow_request_threshold_ms]',
                  RedmineExpertMetrics::Performance::DEFAULT_THRESHOLD_MS.to_s
    # Stored settings from before 1.8.0 lack the token: empty field, no warning.
    assert_select 'input[name=?]', 'settings[slow_requests_token]', 1
    assert_select 'strong.expert-metrics-token-too-short', 0
  end

  private

  # frequent: false stores the row as a plugin version before 1.7.0 did.
  def record_slow_request(controller, action, duration_ms, at, frequent = true)
    frequent_sql = [{ 'count' => 919, 'cached' => 13, 'ms' => 412.3, 'name' => 'Checklist Load',
                      'sql' => 'SELECT `checklists`.* FROM `checklists` WHERE `checklists`.`issue_id` = ?' }].to_json
    ExpertMetricsSlowRequest.create!(
      :created_at => at, :host => 'redmine-0', :controller_name => controller, :action_name => action,
      :http_method => 'GET', :request_format => 'html', :path => "/#{controller}/1", :status => 200,
      :duration_ms => duration_ms, :db_ms => duration_ms - 200, :view_ms => 150, :hooks_ms => 40,
      :sql_count => 120, :sql_cached => 30, :user_id => 2,
      :top_sql => [{ 'ms' => 900.5, 'name' => 'Issue Load', 'sql' => 'SELECT * FROM issues WHERE id = ?' }].to_json,
      :hooks => [{ 'hook' => 'view_issues_show_details_bottom', 'listener' => 'Foo::Hooks', 'ms' => 30.0, 'calls' => 1 }].to_json,
      :frequent_sql => (frequent ? frequent_sql : nil)
    )
  end

  def record_api_use(user_id, verb, user_agent, auth = 'key')
    ExpertMetricsApiUsage.record!(:user_id => user_id, :http_method => verb, :auth_method => auth,
                                  :user_agent => user_agent, :ip => '10.1.2.3', :path => '/issues.json')
  end

  def session_token(user_id, last_activity)
    token = Token.create!(:user_id => user_id, :action => 'session')
    token.update_columns(:created_on => last_activity, :updated_on => last_activity)
    token
  end
end
