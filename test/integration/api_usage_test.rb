require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

# Real requests through core's find_current_user, so the patch is exercised
# exactly as in production.
class RedmineExpertMetricsApiUsageTest < Redmine::ApiTest::Base
  fixtures :users, :email_addresses, :tokens, :members, :member_roles, :roles,
           :projects, :projects_trackers, :enabled_modules, :trackers,
           :issue_statuses, :issues, :enumerations, :workflows

  def setup
    super
    ExpertMetricsApiUsage.delete_all
    ExpertMetricsCounter.delete_all
  end

  def test_api_key_header_is_recorded
    get '/issues.json', :headers => {
      'X-Redmine-API-Key' => User.find(2).api_key, 'HTTP_USER_AGENT' => 'ai-script/1.0'
    }
    assert_response :success

    row = ExpertMetricsApiUsage.sole
    assert_equal 2, row.user_id
    assert_equal 'GET', row.http_method
    assert_equal 'key', row.auth_method
    assert_equal 'ai-script/1.0', row.user_agent
    assert_equal 1, row.requests
    assert_equal '/issues.json', row.last_path
    assert_equal Date.today, row.day
    assert_nil row.last_as_user_id
    assert_equal({ 'GET:key' => 1 }, ExpertMetricsCounter.values(ExpertMetricsApiUsage::COUNTER))
  end

  def test_repeated_requests_add_up_and_key_param_is_not_stored
    key = User.find(2).api_key
    get "/issues.json?key=#{key}"
    get "/issues.json?key=#{key}"

    row = ExpertMetricsApiUsage.sole
    assert_equal 2, row.requests
    assert_equal '/issues.json', row.last_path
    assert_not_includes row.last_path, key
  end

  def test_write_request_is_recorded_with_its_verb
    put '/issues/1.json', :params => { :issue => { :subject => 'Changed by a script' } },
                          :headers => { 'X-Redmine-API-Key' => User.find(2).api_key }
    assert_response :no_content

    assert_equal ['PUT'], ExpertMetricsApiUsage.pluck(:http_method)
  end

  def test_basic_auth_distinguishes_password_from_api_key
    get '/issues.json', :headers => credentials('jsmith')
    get '/issues.json', :headers => credentials(User.find(2).api_key, 'x')

    assert_equal({ 'basic' => 1, 'password' => 1 },
                 ExpertMetricsApiUsage.where(:user_id => 2).group(:auth_method).sum(:requests))
  end

  def test_switch_user_is_booked_on_the_key_owner
    get '/issues.json', :headers => {
      'X-Redmine-API-Key' => User.find(1).api_key, 'X-Redmine-Switch-User' => 'jsmith'
    }
    assert_response :success

    row = ExpertMetricsApiUsage.sole
    assert_equal 1, row.user_id
    assert_equal 2, row.last_as_user_id
  end

  def test_denied_request_is_still_recorded
    # dlopper (3) is no member of the private project 2.
    get '/projects/2.json', :headers => { 'X-Redmine-API-Key' => User.find(3).api_key }
    assert_response :forbidden

    assert_equal [3], ExpertMetricsApiUsage.pluck(:user_id)
  end

  def test_invalid_key_and_anonymous_requests_are_not_recorded
    get '/issues.json', :headers => { 'X-Redmine-API-Key' => 'not-a-key' }
    get '/issues.json'

    assert_equal 0, ExpertMetricsApiUsage.count
  end

  def test_browser_session_is_not_recorded
    log_user('jsmith', 'jsmith')
    get '/issues'
    get '/my/page'

    assert_equal 0, ExpertMetricsApiUsage.count
  end

  def test_nothing_recorded_with_rest_api_disabled
    Setting.rest_api_enabled = '0'
    get '/issues.json', :headers => { 'X-Redmine-API-Key' => User.find(2).api_key }

    assert_equal 0, ExpertMetricsApiUsage.count
  end
end
