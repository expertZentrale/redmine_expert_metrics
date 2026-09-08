# Persistent counters for events Redmine does not record anywhere else (sent
# notification mails). One row per counter name and label, incremented atomically
# so several pods can share it; Prometheus reads it as a counter.
class CreateExpertMetricsCounters < ActiveRecord::Migration[6.1]
  def change
    create_table :expert_metrics_counters do |t|
      t.string   :name,  :null => false
      t.string   :label, :null => false, :default => ''
      t.bigint   :value, :null => false, :default => 0
      t.datetime :updated_on
    end
    add_index :expert_metrics_counters, [:name, :label], :unique => true
  end
end
