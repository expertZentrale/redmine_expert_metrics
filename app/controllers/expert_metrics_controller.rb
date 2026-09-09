# Two faces of the same data (see RedmineExpertMetrics::Collector):
#
# * GET /metrics            - Prometheus text exposition, aggregate numbers only.
#                             Open unless a `metrics_token` is set in
#                             configuration.yml; admins always get through.
# * GET /admin/active_users - who is working right now, HTML for admins and JSON
#                             for scripts (admin session or admin API key).
class ExpertMetricsController < ApplicationController
  layout 'admin'
  self.main_menu = false
  # Highlights our entry in the admin sidebar.
  menu_item :redmine_expert_metrics

  # The scrape must work with "Authentication required" enabled and must not be
  # bounced by the password-change / 2FA interstitials of a stale admin session.
  # `raise: false` keeps this loadable on versions that lack one of the filters.
  skip_before_action :check_if_login_required, :check_password_change, :check_twofa_activation,
                     :only => :prometheus, :raise => false

  before_action :authorize_prometheus, :only => :prometheus
  before_action :require_admin, :only => :active_users
  accept_api_auth :active_users

  # Minutes the admin page looks back for the per-user list.
  DETAILS_WINDOW = 60

  def prometheus
    body = RedmineExpertMetrics::Exposition.render(
      RedmineExpertMetrics::Collector.snapshot,
      Redmine::Plugin.find(:redmine_expert_metrics).version
    )
    response.headers['Cache-Control'] = 'no-store'
    render :plain => body, :content_type => RedmineExpertMetrics::Exposition::CONTENT_TYPE
  end

  def active_users
    @window   = DETAILS_WINDOW
    @snapshot = RedmineExpertMetrics::Collector.snapshot
    @users    = RedmineExpertMetrics::Collector.active_user_details(@window)

    respond_to do |format|
      format.html
      format.json do
        render :json => {
          'collected_at' => @snapshot['collected_at'],
          'window_minutes' => @window,
          'summary' => @snapshot.except('collected_at', 'collect_seconds'),
          'active_users' => @users.map do |row|
            {
              'id'            => row[:user].id,
              'login'         => row[:user].login,
              'name'          => row[:user].name,
              'last_activity' => row[:last_activity].utc.iso8601,
              'session_since' => row[:session_since].utc.iso8601,
              'sessions'      => row[:sessions]
            }
          end
        }
      end
    end
  end

  private

  # Admin session or admin API key always pass. Otherwise a configured
  # `metrics_token` (configuration.yml, rendered from Vault in production) must
  # be presented as `Authorization: Bearer <token>` or `?token=<token>`. With no
  # token configured the endpoint is open - it only carries aggregate counts.
  def authorize_prometheus
    return true if User.current.admin?
    return true if admin_api_key?

    expected = Redmine::Configuration['metrics_token'].to_s
    return true if expected.empty?

    presented = bearer_token || params[:token].to_s
    if presented.present? && ActiveSupport::SecurityUtils.secure_compare(presented, expected)
      return true
    end

    response.headers['WWW-Authenticate'] = 'Bearer realm="Redmine metrics"'
    render :plain => "Unauthorized\n", :status => 401
    false
  end

  # /metrics is not an API format, so core's find_current_user ignores the key;
  # resolve it by hand and require an admin behind it.
  def admin_api_key?
    return false unless Setting.rest_api_enabled?
    key = api_key_from_request
    return false if key.blank?
    user = User.find_by_api_key(key)
    user.present? && user.admin?
  end

  def bearer_token
    header = request.authorization.to_s
    return nil unless header.start_with?('Bearer ')
    header.sub('Bearer ', '').strip
  end
end
