require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class RedmineExpertMetricsCollectorTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses, :tokens, :projects, :trackers, :projects_trackers,
           :issue_statuses, :issues, :enumerations, :issue_categories, :versions

  def setup
    Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)
    Token.where(:action => 'session').delete_all
    ExpertMetricsCounter.delete_all
  end

  def test_active_users_counts_distinct_users_per_window
    session_token(2, 2.minutes.ago)
    session_token(2, 10.minutes.ago)   # second session of the same user
    session_token(3, 10.minutes.ago)
    session_token(4, 90.minutes.ago)

    data = RedmineExpertMetrics::Collector.collect
    assert_equal({ '5m' => 1, '15m' => 2, '60m' => 2 }, data['active_users'])
  end

  def test_sessions_honour_session_timeout
    session_token(2, 2.minutes.ago)
    session_token(3, 90.minutes.ago)

    assert_equal 2, RedmineExpertMetrics::Collector.collect['sessions']
    with_settings :session_timeout => '30' do
      assert_equal 1, RedmineExpertMetrics::Collector.collect['sessions']
    end
  end

  def test_sessions_honour_session_lifetime
    old = session_token(2, 2.minutes.ago)
    old.update_columns(:created_on => 3.days.ago)
    session_token(3, 2.minutes.ago)

    with_settings :session_lifetime => (24 * 60).to_s do
      assert_equal 1, RedmineExpertMetrics::Collector.collect['sessions']
    end
  end

  def test_collect_contains_basic_totals
    data = RedmineExpertMetrics::Collector.collect

    assert_equal User.where(:type => 'User', :status => User::STATUS_ACTIVE).count, data['users']['active']
    assert_equal User.where(:type => 'User', :status => User::STATUS_LOCKED).count, data['users']['locked']
    assert_equal Project.active.count, data['projects_active']
    assert_equal Issue.open.count, data['issues_open']
    assert_equal Issue.count - Issue.open.count, data['issues_closed']
    assert_kind_of Numeric, data['collect_seconds']
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, data['collected_at'])
  end

  def test_recent_logins
    User.where(:type => 'User').update_all(:last_login_on => nil)
    User.find(2).update_column(:last_login_on, 1.hour.ago)
    User.find(3).update_column(:last_login_on, 2.days.ago)

    assert_equal 1, RedmineExpertMetrics::Collector.collect['recent_logins_24h']
  end

  def test_active_user_details_aggregates_per_user_most_recent_first
    session_token(2, 20.minutes.ago)
    session_token(2, 3.minutes.ago)
    session_token(3, 8.minutes.ago)
    session_token(4, 90.minutes.ago)

    rows = RedmineExpertMetrics::Collector.active_user_details(60)
    assert_equal [2, 3], rows.map { |r| r[:user].id }
    assert_equal 2, rows.first[:sessions]
    assert_in_delta 3.minutes.ago.to_f, rows.first[:last_activity].to_f, 5
    assert_in_delta 20.minutes.ago.to_f, rows.first[:session_since].to_f, 5
  end

  # The test environment runs on a null cache store, so use a real one here.
  def test_snapshot_is_cached
    with_cache(ActiveSupport::Cache::MemoryStore.new) do
      session_token(2, 2.minutes.ago)
      first = RedmineExpertMetrics::Collector.snapshot
      session_token(3, 2.minutes.ago)
      assert_equal first['active_users'], RedmineExpertMetrics::Collector.snapshot['active_users']

      Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)
      assert_equal 2, RedmineExpertMetrics::Collector.snapshot['active_users']['5m']
    end
  end

  def test_snapshot_survives_a_broken_cache_store
    broken = Object.new
    def broken.fetch(*); raise IOError, 'cache down'; end
    with_cache(broken) do
      session_token(2, 2.minutes.ago)
      assert_equal 1, RedmineExpertMetrics::Collector.snapshot['active_users']['5m']
    end
  end

  def test_exposition_renders_prometheus_text
    session_token(2, 2.minutes.ago)
    text = RedmineExpertMetrics::Exposition.render(RedmineExpertMetrics::Collector.collect, '1.0.0')

    assert_includes text, "# TYPE redmine_active_users gauge\n"
    assert_includes text, "redmine_active_users{window=\"5m\"} 1\n"
    assert_includes text, "redmine_active_users{window=\"60m\"} 1\n"
    assert_includes text, "redmine_sessions_total 1\n"
    assert_includes text, "redmine_users_total{status=\"active\"} "
    assert_includes text, "redmine_issues_total{state=\"open\"} "
    assert_includes text, "redmine_info{redmine_version=\"#{Redmine::VERSION}\",plugin_version=\"1.0.0\"} 1\n"
    assert text.end_with?("\n")
  end

  def test_exposition_escapes_label_values
    assert_equal 'a\\"b\\\\c\\nd', RedmineExpertMetrics::Exposition.escape("a\"b\\c\nd")
  end

  private

  def with_cache(store)
    previous = Rails.cache
    Rails.cache = store
    yield
  ensure
    Rails.cache = previous
  end

  def session_token(user_id, last_activity)
    token = Token.create!(:user_id => user_id, :action => 'session')
    token.update_columns(:created_on => last_activity, :updated_on => last_activity)
    token
  end
end
