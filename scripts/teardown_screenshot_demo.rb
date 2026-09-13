# Removes everything scripts/seed_screenshot_demo.rb created.
#
#   bundle exec rails runner plugins/redmine_expert_metrics/scripts/teardown_screenshot_demo.rb
#
# The seed does NOT prefix what it creates — project identifiers become
# Prometheus label values, and a visible "metrics-demo-" in a published
# screenshot advertises that the numbers are fake. So instead of matching on a
# name, this reads the ids the seed recorded in the `expert_metrics_screenshot_backup`
# settings row and deletes exactly those. Without that row it deletes nothing,
# deliberately: guessing would risk taking real data with it.
#
# The plugin has no settings of its own, so there is nothing to restore.

require 'json'

BACKUP_KEY = 'expert_metrics_screenshot_backup'.freeze
LOGIN      = 'screenshot-metrics'.freeze

def say(msg)
  puts("[teardown] #{msg}")
end

raw = Setting.where(:name => BACKUP_KEY).pick(:value)
if raw.blank?
  abort "[teardown] No #{BACKUP_KEY} row - nothing to undo, and guessing would " \
        "risk deleting rows the seed did not create."
end

backup      = JSON.parse(raw)
user_ids    = Array(backup['user_ids'])
project_ids = Array(backup['project_ids'])
capture_id  = backup['capture_user_id']

if RedmineExpertMetrics::Collector.helpdesk_available?
  messages = HelpdeskMessage.joins(:issue).where(issues: { project_id: project_ids })
  say "removing #{messages.count} helpdesk message(s)"
  messages.delete_all
end

projects = Project.where(id: project_ids)
say "removing #{projects.count} project(s) and " \
    "#{Issue.where(project_id: project_ids).count} issue(s)"
projects.destroy_all

users = User.where(id: user_ids + [capture_id].compact)
say "removing #{users.count} user(s) and " \
    "#{Token.where(user_id: users.select(:id)).count} session token(s)"
Token.where(user_id: users.select(:id)).delete_all
users.destroy_all

if ExpertMetricsCounter.available?
  say "removing #{ExpertMetricsCounter.count} counter row(s)"
  ExpertMetricsCounter.delete_all
end

Setting.where(:name => BACKUP_KEY).delete_all
Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)

say "done. users=#{User.where(type: 'User').count} " \
    "projects=#{Project.count} issues=#{Issue.count}"
