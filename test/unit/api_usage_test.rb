require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class RedmineExpertMetricsApiUsageModelTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses, :tokens

  def setup
    Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)
    ExpertMetricsApiUsage.delete_all
    ExpertMetricsCounter.delete_all
  end

  def test_record_creates_then_adds_and_keeps_the_latest_details
    first = Time.now - 2.hours
    ExpertMetricsApiUsage.record!(attrs(:ip => '10.0.0.1', :path => '/issues.json'), first)
    ExpertMetricsApiUsage.record!(attrs(:ip => '10.0.0.2', :path => '/projects.json'))

    row = sole_row
    assert_equal 2, row.requests
    assert_equal '10.0.0.2', row.last_ip
    assert_equal '/projects.json', row.last_path
    assert_equal first.to_i, row.first_at.to_i
    assert_operator row.last_at, :>, row.first_at
  end

  def test_record_splits_by_verb_auth_and_client
    ExpertMetricsApiUsage.record!(attrs)
    ExpertMetricsApiUsage.record!(attrs(:http_method => 'POST'))
    ExpertMetricsApiUsage.record!(attrs(:auth_method => 'password'))
    ExpertMetricsApiUsage.record!(attrs(:user_agent => 'other-client'))

    assert_equal 4, ExpertMetricsApiUsage.count
  end

  def test_record_truncates_long_user_agents
    ExpertMetricsApiUsage.record!(attrs(:user_agent => 'x' * 400))
    ExpertMetricsApiUsage.record!(attrs(:user_agent => 'x' * 500))

    row = sole_row
    assert_equal 255, row.user_agent.size
    assert_equal 2, row.requests
  end

  def test_purge_drops_rows_past_retention
    ExpertMetricsApiUsage.record!(attrs, Time.now - (ExpertMetricsApiUsage::RETENTION_DAYS + 1).days)
    ExpertMetricsApiUsage.record!(attrs, Time.now - (ExpertMetricsApiUsage::RETENTION_DAYS - 1).days)

    ExpertMetricsApiUsage.purge!
    assert_equal 1, ExpertMetricsApiUsage.count
  end

  def test_details_per_user_and_unused_keys
    User.find(2).api_key
    User.find(3).api_key
    ExpertMetricsApiUsage.record!(attrs(:user_agent => 'curl/8'))
    ExpertMetricsApiUsage.record!(attrs(:user_agent => 'curl/8'))
    ExpertMetricsApiUsage.record!(attrs(:http_method => 'PUT', :user_agent => 'python-requests/2'))
    ExpertMetricsApiUsage.record!(attrs(:user_id => 2), Time.now - 10.days)

    details = RedmineExpertMetrics::Collector.api_usage_details(7)
    assert_equal [2], details[:users].map { |row| row[:user].id }
    row = details[:users].first
    assert_equal 3, row[:requests]
    assert_equal 1, row[:writes]
    assert_equal({ 'GET' => 2, 'PUT' => 1 }, row[:methods])
    assert_equal({ 'curl/8' => 2, 'python-requests/2' => 1 }, row[:clients])
    assert_not_nil row[:key_created_on]
    assert_includes details[:unused_keys].map { |r| r[:user].id }, 3
    assert_not_includes details[:unused_keys].map { |r| r[:user].id }, 2

    # 30 days reach the older row as well.
    assert_equal 4, RedmineExpertMetrics::Collector.api_usage_details(30)[:users].first[:requests]
  end

  def test_exposition_carries_api_aggregates_but_no_names
    ExpertMetricsApiUsage.record!(attrs)
    ExpertMetricsApiUsage.record!(attrs(:user_id => 3), Time.now - 3.days)
    ExpertMetricsCounter.increment!(ExpertMetricsApiUsage::COUNTER, 'GET:key', 4)
    ExpertMetricsCounter.increment!(ExpertMetricsApiUsage::COUNTER, 'POST:password')

    data = RedmineExpertMetrics::Collector.collect
    assert_equal({ '1d' => 1, '7d' => 2, '30d' => 2 }, data['api_users'])
    text = RedmineExpertMetrics::Exposition.render(data, '1.3.0')
    assert_includes text, "# TYPE redmine_api_requests_total counter\n"
    assert_includes text, "redmine_api_requests_total{method=\"GET\",auth=\"key\"} 4\n"
    assert_includes text, "redmine_api_requests_total{method=\"POST\",auth=\"password\"} 1\n"
    assert_includes text, "redmine_api_users{window=\"7d\"} 2\n"
    assert_includes text, "redmine_api_keys_total #{RedmineExpertMetrics::Collector.api_key_scope.count}\n"
    assert_not_includes text, User.find(2).login
    assert_not_includes text, 'curl'
  end

  def test_key_holders_skip_locked_and_anonymous_users
    User.find(2).api_key
    Token.create!(:user => User.anonymous, :action => 'api')
    locked = User.find(5) # dlopper2, locked in the fixtures
    Token.create!(:user => locked, :action => 'api')

    holders = RedmineExpertMetrics::Collector.api_key_holders
    assert_includes holders.keys, 2
    assert_not_includes holders.keys, User.anonymous.id
    assert_not_includes holders.keys, locked.id
  end

  private

  # Model.sole needs Rails 7 (Redmine 5.1 runs Rails 6.1).
  def sole_row
    assert_equal 1, ExpertMetricsApiUsage.count
    ExpertMetricsApiUsage.first
  end

  def attrs(overrides = {})
    { :user_id => 2, :http_method => 'GET', :auth_method => 'key', :user_agent => 'curl/8',
      :ip => '127.0.0.1', :path => '/issues.json' }.merge(overrides)
  end
end
