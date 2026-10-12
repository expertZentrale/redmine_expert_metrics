# Records every request authenticated by API credentials (see
# ExpertMetricsApiUsage). Redmine core keeps no trace of API-key use, so
# without this an admin cannot tell which users run scripts against Redmine.
#
# Prepended to ApplicationController; wraps core's find_current_user, which runs
# once per request. Core ignores the browser session for API formats (.json,
# .xml), so a logged-in user on an API request was always authenticated by key,
# HTTP Basic or OAuth. Recording never breaks the request: any error is logged
# and swallowed.
module RedmineExpertMetrics
  module ApiUsagePatch
    def find_current_user
      user = super
      expert_metrics_record_api_usage(user)
      user
    end

    private

    def expert_metrics_record_api_usage(user)
      return if user.nil? || performed?
      return unless api_request? && Setting.rest_api_enabled? && accept_api_auth?
      return unless ExpertMetricsApiUsage.available?

      auth, owner = expert_metrics_api_auth(user)
      return if owner.nil?

      verb = request.request_method.to_s
      ExpertMetricsApiUsage.record!(
        :user_id     => owner.id,
        :http_method => verb,
        :auth_method => auth,
        :user_agent  => request.user_agent,
        :ip          => request.remote_ip,
        # Path only: the query string may carry the API key (?key=...).
        :path        => request.path,
        :as_user_id  => (owner.id == user.id ? nil : user.id)
      )
      ExpertMetricsCounter.increment!(ExpertMetricsApiUsage::COUNTER, "#{verb}:#{auth}")
      ExpertMetricsApiUsage.purge_if_due
    rescue StandardError => e
      Rails.logger.warn("redmine_expert_metrics: API usage not recorded (#{e.class}: #{e.message})")
    end

    # [auth method, key owner]. The owner differs from +user+ only when an admin
    # switched user via X-Redmine-Switch-User - usage is booked on whoever's
    # credentials were presented.
    #   key      - X-Redmine-API-Key header or ?key=
    #   basic    - API key as HTTP Basic user name
    #   password - login and password via HTTP Basic
    #   oauth    - OAuth access token (Redmine 6.1+)
    def expert_metrics_api_auth(user)
      switched = expert_metrics_switched?(user)
      if (key = api_key_from_request)
        ['key', switched ? User.find_by_api_key(key) : user]
      elsif /\ABasic /i.match?(request.authorization.to_s)
        username = ActionController::HttpAuthentication::Basic.user_name_and_password(request).first.to_s
        if switched
          key_owner = User.find_by_api_key(username)
          key_owner ? ['basic', key_owner] : ['password', User.find_by_login(username)]
        elsif user.login.to_s.casecmp?(username)
          ['password', user]
        else
          ['basic', user]
        end
      else
        ['oauth', user]
      end
    end

    # Core only replaces the user when the header names an active user and the
    # credentials belong to an admin; then the current user is the one named.
    def expert_metrics_switched?(user)
      login = api_switch_user_from_request
      login.present? && user.login.to_s.casecmp?(login)
    end
  end
end
