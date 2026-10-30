require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# A listener on a hook every HTML page calls, so a real request shows up in the
# hook series.
class ExpertMetricsPerformanceIntegrationHook < Redmine::Hook::ViewListener
  def view_layouts_base_html_head(_context = {})
    ''
  end
end

# Real requests through ApplicationController, so the timing patch, the
# notification subscribers and the hook patch run as in production.
class RedmineExpertMetricsPerformanceIntegrationTest < Redmine::IntegrationTest
  fixtures :users, :email_addresses, :members, :member_roles, :roles,
           :projects, :projects_trackers, :enabled_modules, :trackers,
           :issue_statuses, :issues, :enumerations, :workflows

  Performance = RedmineExpertMetrics::Performance

  def setup
    super
    Performance::REGISTRY.reset!
    Performance.reset_slow_limit!
    ExpertMetricsSlowRequest.delete_all
    enable(:threshold => 100_000)
  end

  def teardown
    Setting.plugin_redmine_expert_metrics = { 'api_usage_enabled' => '0' }
    super
  end

  def test_request_is_booked_per_controller_and_action
    get '/projects'
    assert_response :success

    snapshot = Performance::REGISTRY.snapshot
    labels = { 'controller' => 'projects', 'action' => 'index', 'format' => 'html' }
    data = snapshot[:histograms]['redmine_http_request_duration_seconds'][:series][labels]
    assert_equal 1, data[:count]
    assert_operator data[:sum], :>, 0
    assert_operator snapshot[:counters]['redmine_http_request_sql_queries_total'][labels], :>, 0
    assert_equal 0, ExpertMetricsSlowRequest.count
  end

  def test_hook_listeners_are_booked
    get '/projects'

    calls = Performance::REGISTRY.snapshot[:counters]['redmine_hook_calls_total']
    key = { 'hook' => 'view_layouts_base_html_head', 'listener' => 'ExpertMetricsPerformanceIntegrationHook' }
    assert_equal 1, calls[key]
  end

  def test_nothing_recorded_while_switched_off
    Setting.plugin_redmine_expert_metrics = { 'performance_metrics_enabled' => '0', 'slow_request_threshold_ms' => '0' }
    get '/projects'
    assert_response :success

    assert_equal({ :counters => {}, :histograms => {} }, Performance::REGISTRY.snapshot)
    assert_equal 0, ExpertMetricsSlowRequest.count
    assert_nil response.headers['Server-Timing']
  end

  def test_slow_request_is_stored_with_breakdown
    enable(:threshold => 0)
    log_user('jsmith', 'jsmith')
    get '/projects/ecookbook/issues?set_filter=1&subject=secret+term'
    assert_response :success

    row = ExpertMetricsSlowRequest.where(:controller_name => 'issues', :action_name => 'index').last
    assert_not_nil row
    assert_equal 'GET', row.http_method
    assert_equal 'html', row.request_format
    assert_equal '/projects/ecookbook/issues', row.path
    assert_equal 200, row.status
    assert_equal 2, row.user_id
    assert_operator row.sql_count, :>, 0
    assert row.top_sql_list.any?
    assert row.top_sql_list.none? { |entry| entry['sql'].include?('secret term') }
    # Only the slowest listeners are kept, so check the shape, not ours.
    assert row.hook_list.any?
    assert row.hook_list.all? { |entry| entry['listener'].present? && entry['hook'].present? && entry['calls'] > 0 }
  end

  def test_scrape_is_not_timed_and_carries_the_series
    get '/projects'
    get '/metrics'
    assert_response :success

    histograms = Performance::REGISTRY.snapshot[:histograms]['redmine_http_request_duration_seconds'][:series]
    assert histograms.keys.none? { |labels| labels['controller'] == 'expert_metrics' }
    assert_includes response.body,
                    "redmine_http_request_duration_seconds_count{controller=\"projects\",action=\"index\",format=\"html\"} 1\n"
    assert_includes response.body, '# TYPE redmine_process_start_time_seconds gauge'
  end

  def test_scrape_leaves_out_the_series_while_switched_off
    get '/projects'
    Setting.plugin_redmine_expert_metrics = { 'performance_metrics_enabled' => '0' }
    get '/metrics'
    assert_response :success

    assert_not_includes response.body, 'redmine_http_request_duration_seconds'
    assert_not_includes response.body, 'redmine_process_start_time_seconds'
  end

  def test_server_timing_header_for_admins_only
    log_user('jsmith', 'jsmith')
    get '/projects'
    assert_nil response.headers['Server-Timing']

    reset!
    log_user('admin', 'admin')
    get '/projects'
    assert_match(/\Aapp;dur=[\d.]+, db;dur=[\d.]+;desc="\d+ queries, \d+ cached", view;dur=/,
                 response.headers['Server-Timing'])
  end

  private

  def enable(threshold:)
    Setting.plugin_redmine_expert_metrics = {
      'performance_metrics_enabled' => '1', 'slow_request_threshold_ms' => threshold.to_s
    }
  end
end
