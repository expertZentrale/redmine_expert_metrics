require 'digest/sha1'

# Daily API usage rows (see db/migrate/002). Written by
# RedmineExpertMetrics::ApiUsagePatch on every request authenticated by API
# credentials; read by the admin page. Same atomic UPDATE-then-INSERT pattern as
# ExpertMetricsCounter, so concurrent pods never lose a request.
class ExpertMetricsApiUsage < ActiveRecord::Base
  RETENTION_DAYS = 90
  # Counter name in expert_metrics_counters, label "<VERB>:<auth>".
  COUNTER = 'api_requests'.freeze
  # What the admin page counts as "writing" - anything else (GET, HEAD,
  # OPTIONS, ...) is not.
  WRITE_METHODS = %w(POST PUT PATCH DELETE).freeze

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
    return if bump(key, now, last) > 0
    begin
      create!(key.merge(last).merge(:user_agent => user_agent, :requests => 1, :first_at => now))
    rescue ActiveRecord::RecordNotUnique
      # Another process created the row in between - just add to it.
      bump(key, now, last)
    end
  end

  # Drops rows past the retention period. Runs at most once an hour per cache
  # store (shared Redis in production), so it can be called on every request.
  # Called from API requests, every /metrics collection and the admin page, so
  # it also runs while nobody uses the API. Never raises: a broken cache store
  # must not take /metrics down with it, and the next healthy call purges.
  def self.purge_if_due
    # unless_exist makes the claim atomic (Redis SET NX, Memcache add): of
    # several requests or pods arriving after the hour, only one purges.
    return unless Rails.cache.write(PURGE_CACHE_KEY, true, :expires_in => 1.hour, :unless_exist => true)
    purge!
  rescue StandardError => e
    Rails.logger.warn("redmine_expert_metrics: API usage purge skipped (#{e.class}: #{e.message})")
    nil
  end

  # Days are server-local (Time.now.to_date / Date.today) on both the write and
  # the read side, so they always agree.
  def self.purge!(today = Date.today)
    where('day < ?', today - RETENTION_DAYS).delete_all
  end

  # Counts atomically, but only a request at least as recent as the stored
  # one replaces the last_* details (and an older one may move first_at back):
  # a request that lost the insert race to a later one must not overwrite it.
  # last_at is assigned last, because MySQL evaluates SET left to right and
  # the CASEs above it must still see the old value.
  def self.bump(key, now, last)
    sets = ['requests = requests + 1',
            'first_at = CASE WHEN first_at IS NULL OR first_at > ? THEN ? ELSE first_at END']
    binds = [now, now]
    last.except(:last_at).each do |column, value|
      sets << "#{column} = CASE WHEN last_at IS NULL OR last_at <= ? THEN ? ELSE #{column} END"
      binds.push(now, value)
    end
    sets << 'last_at = CASE WHEN last_at IS NULL OR last_at <= ? THEN ? ELSE last_at END'
    binds.push(now, now)
    where(key).update_all([sets.join(', ')] + binds)
  end
  private_class_method :bump
end
