require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# A listener on a hook every HTML page calls, so a real request shows up in the
# hook series. With sql_seconds set, it also sends a statement of that length
# while the layout renders, as a template running a slow query would.
class ExpertMetricsPerformanceIntegrationHook < Redmine::Hook::ViewListener
  class << self
    attr_accessor :sql_seconds
  end

  def view_layouts_base_html_head(_context = {})
    seconds = self.class.sql_seconds
    if seconds
      ActiveSupport::Notifications.instrument('sql.active_record', :sql => 'SELECT 1', :name => 'Simulated') do
        sleep seconds
      end
    end
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
    Performance.detach!
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
    assert_not Performance.attached?
  end

  def test_switching_on_attaches_the_subscribers_on_the_next_request
    Setting.plugin_redmine_expert_metrics = { 'performance_metrics_enabled' => '0' }
    get '/projects'
    assert_not Performance.attached?

    enable(:threshold => 100_000)
    get '/projects'
    assert Performance.attached?
    assert_operator Performance::REGISTRY.snapshot[:counters]['redmine_http_request_sql_queries_total'].values.sum, :>, 0
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

  # The rate limit caps stored rows, not the warn line every slow request gets.
  def test_rate_limited_slow_requests_are_still_logged
    enable(:threshold => 0)
    Performance::MAX_SLOW_WRITES_PER_MINUTE.times { Performance.slow_write_allowed? }
    lines = []
    Rails.logger.stubs(:warn).with { |message = nil| lines << message.to_s; true }
    get '/projects'

    assert_response :success
    assert_equal 0, ExpertMetricsSlowRequest.count
    assert lines.any? { |line| line.include?('slow request projects#index') }, lines.inspect
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

  # Rails takes the SQL out of its own view time only while the logger is at
  # info or below; production runs at warn, where a slow query in a template
  # or hook was counted as database and view time both.
  def test_view_time_leaves_out_sql_run_while_rendering_at_any_log_level
    logger = ActionController::Base.logger
    level = logger.level
    ExpertMetricsPerformanceIntegrationHook.sql_seconds = 0.2
    log_user('admin', 'admin')

    [Logger::WARN, Logger::DEBUG].each do |log_level|
      logger.level = log_level
      get '/projects'
      assert_response :success

      timing = server_timing
      assert_operator timing['db'], :>=, 200, "log level #{log_level}"
      # Rendering /projects takes more than its SQL; zero would mean the render
      # was never timed (e.g. Rails no longer calls cleanup_view_runtime).
      assert_operator timing['view'], :>, 0, "log level #{log_level}: #{response.headers['Server-Timing']}"
      assert_operator timing['view'] + timing['db'], :<=, timing['app'] + 1,
                      "log level #{log_level}: #{response.headers['Server-Timing']}"
    end
  ensure
    ExpertMetricsPerformanceIntegrationHook.sql_seconds = nil
    logger.level = level if logger
  end

  private

  # {"app" => ms, "db" => ms, ...} from the Server-Timing header.
  def server_timing
    response.headers['Server-Timing'].to_s.scan(/(\w+);dur=([\d.]+)/).to_h { |name, ms| [name, ms.to_f] }
  end

  def enable(threshold:)
    Setting.plugin_redmine_expert_metrics = {
      'performance_metrics_enabled' => '1', 'slow_request_threshold_ms' => threshold.to_s
    }
  end
end
