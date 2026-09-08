require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class ExpertMetricsControllerTest < Redmine::ControllerTest
  fixtures :users, :email_addresses, :tokens, :projects, :trackers, :projects_trackers,
           :issue_statuses, :issues, :enumerations, :issue_categories, :versions

  def setup
    User.current = nil
    Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)
    Token.where(:action => 'session').delete_all
    ExpertMetricsCounter.delete_all
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

  private

  def session_token(user_id, last_activity)
    token = Token.create!(:user_id => user_id, :action => 'session')
    token.update_columns(:created_on => last_activity, :updated_on => last_activity)
    token
  end
end
