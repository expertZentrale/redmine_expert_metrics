# Monotonic counter rows (see db/migrate/001). Incremented with a single
# UPDATE ... value = value + n so concurrent pods never lose an increment; the
# row is created on first use. Never decremented - Prometheus counter semantics.
class ExpertMetricsCounter < ActiveRecord::Base
  NOTIFICATIONS_SENT = 'notifications_sent'.freeze

  validates :name, :presence => true

  def self.increment!(name, label = '', by = 1)
    label = label.to_s
    return if bump(name, label, by) > 0
    begin
      create!(:name => name, :label => label, :value => by, :updated_on => Time.now)
    rescue ActiveRecord::RecordNotUnique
      # Another process created the row in between - just add to it.
      bump(name, label, by)
    end
  end

  # { label => value } for one counter name, labels sorted.
  def self.values(name)
    where(:name => name).order(:label).pluck(:label, :value).to_h
  end

  def self.bump(name, label, by)
    where(:name => name, :label => label)
      .update_all(['value = value + ?, updated_on = ?', by, Time.now])
  end
  private_class_method :bump
end
