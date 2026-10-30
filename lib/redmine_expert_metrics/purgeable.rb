# Retention for the plugin's own tables. A model extends this and defines
# PURGE_CACHE_KEY and purge!; purge_if_due can then be called on every request.
module RedmineExpertMetrics
  module Purgeable
    # Runs purge! at most once an hour per cache store (shared Redis in
    # production). Never raises: a broken cache store must not take a request or
    # /metrics down with it, and the next healthy call purges.
    def purge_if_due
      # unless_exist makes the claim atomic (Redis SET NX, Memcache add): of
      # several requests or pods arriving after the hour, only one purges.
      return unless Rails.cache.write(self::PURGE_CACHE_KEY, true, :expires_in => 1.hour, :unless_exist => true)
      purge!
    rescue StandardError => e
      Rails.logger.warn("redmine_expert_metrics: #{name} purge skipped (#{e.class}: #{e.message})")
      nil
    end
  end
end
