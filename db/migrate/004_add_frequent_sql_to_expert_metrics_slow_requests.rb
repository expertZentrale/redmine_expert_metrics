# The statement shapes a slow request ran most often (JSON, literals replaced
# like top_sql): an N+1 query is thousands of fast statements of one shape,
# which the slowest statements alone never show. Written by
# RedmineExpertMetrics::Performance#record_slow once this column exists.
class AddFrequentSqlToExpertMetricsSlowRequests < ActiveRecord::Migration[6.1]
  def change
    add_column :expert_metrics_slow_requests, :frequent_sql, :text
  end
end
