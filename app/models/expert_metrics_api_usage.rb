require 'digest/sha1'

# Daily API usage rows (see db/migrate/002). Written by
# RedmineExpertMetrics::ApiUsagePatch on every request authenticated by API
# credentials; read by the admin page. Same atomic UPDATE-then-INSERT pattern as
# ExpertMetricsCounter, so concurrent pods never lose a request.
class ExpertMetricsApiUsage < ActiveRecord::Base
  RETENTION_DAYS = 90
  # Counter name in expert_metrics_counters, label "<VERB>:<auth>".
  COUNTER = 'api_requests'.freeze
  READ_METHODS = %w(GET HEAD).freeze

  PURGE_CACHE_KEY = 'redmine_expert_metrics/api_usage_purged'.freeze

  belongs_to :user
  belongs_to :last_as_user, :class_name => 'User', :optional => true

  # False until db/migrate/002 has run. Schema-cache lookup, no query per call.
  def self.available?
    table_exists?
  rescue StandardError
    false
  end

  # One API request. +attrs+: :user_id, :http_method, :auth_method,
  # :user_agent, :ip, :path, :as_user_id (switched-to user, if any).
  def self.record!(attrs, now = Time.now)
    user_agent = attrs[:user_agent].to_s[0, 255]
    key = {
      :user_id       => attrs[:user_id],
      :day           => now.to_date,
      :http_method   => attrs[:http_method].to_s[0, 10],
      :auth_method   => attrs[:auth_method].to_s[0, 10],
      :client_digest => Digest::SHA1.hexdigest(user_agent)
    }
    last = {
      :last_at         => now,
      :last_ip         => attrs[:ip].to_s[0, 45].presence,
      :last_path       => attrs[:path].to_s[0, 255].presence,
      :last_as_user_id => attrs[:as_user_id]
    }
    return if bump(key, last) > 0
    begin
      create!(key.merge(last).merge(:user_agent => user_agent, :requests => 1, :first_at => now))
    rescue ActiveRecord::RecordNotUnique
      # Another process created the row in between - just add to it.
      bump(key, last)
    end
  end

  # Drops rows past the retention period. Runs at most once an hour per cache
  # store (shared Redis in production), so it can be called on every request.
  def self.purge_if_due
    return if Rails.cache.read(PURGE_CACHE_KEY)
    Rails.cache.write(PURGE_CACHE_KEY, true, :expires_in => 1.hour)
    purge!
  end

  # Days are server-local (Time.now.to_date / Date.today) on both the write and
  # the read side, so they always agree.
  def self.purge!(today = Date.today)
    where('day < ?', today - RETENTION_DAYS).delete_all
  end

  def self.bump(key, last)
    sets = ['requests = requests + 1'] + last.keys.map { |column| "#{column} = ?" }
    where(key).update_all([sets.join(', ')] + last.values)
  end
  private_class_method :bump
end
