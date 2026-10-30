# Requests slower than the plugin setting "Slow request threshold", with the
# breakdown /metrics can only give as sums: database, view, hooks, GC, the
# slowest SQL statements (literals replaced) and the slowest hook listeners.
# Written by RedmineExpertMetrics::Performance; rows older than
# ExpertMetricsSlowRequest::RETENTION_DAYS are purged.
class CreateExpertMetricsSlowRequests < ActiveRecord::Migration[6.1]
  def change
    create_table :expert_metrics_slow_requests do |t|
      t.datetime :created_at,      :null => false
      # Pod / host name: which process served it.
      t.string   :host,            :null => false, :default => '', :limit => 64
      t.string   :controller_name, :null => false, :limit => 100
      t.string   :action_name,     :null => false, :limit => 100
      t.string   :http_method,     :null => false, :limit => 10
      t.string   :request_format,  :null => false, :limit => 16
      # Without query string, like the API usage path.
      t.string   :path,            :null => false, :default => ''
      t.integer  :status,          :null => false, :default => 0
      t.integer  :duration_ms,     :null => false, :default => 0
      t.integer  :db_ms,           :null => false, :default => 0
      t.integer  :view_ms,         :null => false, :default => 0
      t.integer  :hooks_ms,        :null => false, :default => 0
      t.integer  :gc_ms
      t.integer  :sql_count,       :null => false, :default => 0
      t.integer  :sql_cached,      :null => false, :default => 0
      # JSON arrays, see Performance#record_slow.
      t.text     :top_sql
      t.text     :hooks
      t.integer  :user_id
      t.string   :request_id,      :limit => 64
    end
    add_index :expert_metrics_slow_requests, :created_at
  end
end
