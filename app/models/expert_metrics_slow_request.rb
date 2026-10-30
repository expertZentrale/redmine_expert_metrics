require 'json'

# One request slower than the configured threshold (see db/migrate/003 and
# RedmineExpertMetrics::Performance#record_slow). Read by the admin page
# "Slow requests".
class ExpertMetricsSlowRequest < ActiveRecord::Base
  # purge_if_due: called after every stored row and from the admin page.
  extend RedmineExpertMetrics::Purgeable

  RETENTION_DAYS = 14
  PURGE_CACHE_KEY = 'redmine_expert_metrics/slow_requests_purged'.freeze

  belongs_to :user, :optional => true

  # False until db/migrate/003 has run. Schema-cache lookup, no query per call.
  def self.available?
    table_exists?
  rescue StandardError
    false
  end

  def self.purge!(now = Time.now)
    where('created_at < ?', now - RETENTION_DAYS.days).delete_all
  end

  # Rows per controller#action since +since+, most frequent first:
  # [{ :controller, :action, :requests, :avg_ms, :max_ms, :avg_db_ms, :avg_sql }]
  def self.summary(since, limit = 20)
    where('created_at >= ?', since)
      .group(:controller_name, :action_name)
      .order(Arel.sql('COUNT(*) DESC'), :controller_name, :action_name)
      .limit(limit)
      .pluck(:controller_name, :action_name, Arel.sql('COUNT(*)'), Arel.sql('AVG(duration_ms)'),
             Arel.sql('MAX(duration_ms)'), Arel.sql('AVG(db_ms)'), Arel.sql('AVG(sql_count)'))
      .map do |controller, action, requests, avg_ms, max_ms, avg_db_ms, avg_sql|
        { :controller => controller, :action => action, :requests => requests.to_i,
          :avg_ms => avg_ms.to_f.round, :max_ms => max_ms.to_i,
          :avg_db_ms => avg_db_ms.to_f.round, :avg_sql => avg_sql.to_f.round }
      end
  end

  def top_sql_list
    parse_list(top_sql)
  end

  def hook_list
    parse_list(hooks)
  end

  private

  def parse_list(text)
    list = JSON.parse(text.to_s)
    list.is_a?(Array) ? list : []
  rescue JSON::ParserError
    []
  end
end
