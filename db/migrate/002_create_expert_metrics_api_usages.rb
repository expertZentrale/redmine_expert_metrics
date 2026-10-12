# Daily API usage per user: Redmine core keeps no record of API-key use, so
# every request authenticated by API credentials adds to one row per user, day,
# HTTP verb, auth method and client (User-Agent). Rows older than
# ExpertMetricsApiUsage::RETENTION_DAYS are purged.
class CreateExpertMetricsApiUsages < ActiveRecord::Migration[6.1]
  def change
    create_table :expert_metrics_api_usages do |t|
      t.integer  :user_id,         :null => false
      t.date     :day,             :null => false
      t.string   :http_method,     :null => false, :limit => 10
      t.string   :auth_method,     :null => false, :limit => 10
      t.string   :user_agent,      :null => false, :default => ''
      # SHA1 of user_agent - keeps the unique index short.
      t.string   :client_digest,   :null => false, :limit => 40
      t.bigint   :requests,        :null => false, :default => 0
      t.datetime :first_at
      t.datetime :last_at
      t.string   :last_ip,         :limit => 45
      t.string   :last_path
      t.integer  :last_as_user_id
    end
    add_index :expert_metrics_api_usages,
              [:user_id, :day, :http_method, :auth_method, :client_digest],
              :unique => true, :name => 'index_expert_metrics_api_usages_unique'
    add_index :expert_metrics_api_usages, :day
  end
end
