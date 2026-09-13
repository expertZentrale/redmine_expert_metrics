# Seeds the synthetic installation used to generate this plugin's screenshots.
#
#   bundle exec rails runner plugins/redmine_expert_metrics/scripts/seed_screenshot_demo.rb
#
# UNLIKE the helpdesk and agile seeds this one cannot hide inside a demo project,
# because the plugin has no per-project :surface => the admin page lists every user
# active ANYWHERE in the installation, and /metrics reports installation-wide
# totals. So the numbers on a screenshot are whatever the whole database holds.
#
# That is why this must only ever be pointed at an empty, disposable database —
# use docker-compose.screenshots.yml from the parent repo, never the dev stack,
# whose MariaDB is a restore of production. The script refuses to run if it finds
# data it did not create.
#
# Names are the ones a real installation would have, NOT prefixed with anything
# — project identifiers end up as Prometheus label values on /metrics, and
# `project="metrics-demo-customer-support"` in a published screenshot advertises
# that the numbers are fake. So instead of a prefix, every id this script creates
# is recorded in a `settings` row named `expert_metrics_screenshot_backup`, and
# scripts/teardown_screenshot_demo.rb deletes exactly those rows and nothing
# else. Same approach the agile plugin's seed uses.
#
# All data is :synthetic => invented names and @example.com addresses.
#
# Modes:
#   DEMO_PASSWORD=   password for the capture user (random and printed if unset)
#   FORCE=1          seed even though the database holds rows this did not create

require 'json'
require 'securerandom'

# Deliberately an ordinary-looking :account => it is the one signed in while the
# screenshot is taken, so it appears in its own "active users" table.
LOGIN      = 's.weiss'.freeze
BACKUP_KEY = 'expert_metrics_screenshot_backup'.freeze
SEED       = 20_260_913
NOW        = Time.current

srand(SEED)
ActionMailer::Base.perform_deliveries = false

def say(msg)
  puts("[seed] #{msg}")
end

# The ids of everything created, parked in a settings row so teardown can be
# exact. Setting.new/save(:validate => false) because this is not a registered
# setting and Redmine would refuse it otherwise.
def raw_setting(name)
  Setting.where(:name => name).pick(:value)
end

def write_raw_setting!(name, value)
  unless Setting.where(:name => name).exists?
    row = Setting.new
    row.name = name
    row.save(:validate => false)
  end
  Setting.where(:name => name).update_all(:value => value, :updated_on => Time.current)
end

def load_backup
  raw = raw_setting(BACKUP_KEY)
  raw.blank? ? {} : JSON.parse(raw)
end

def save_backup!(backup)
  write_raw_setting!(BACKUP_KEY, backup.to_json)
end

# --- refuse to run against anything that is not a scratch database -----------

# The numbers this plugin shows are installation-wide, so seeding on top of real
# data would put that real data into a published screenshot. Anonymous + admin is
# what a freshly migrated Redmine has.
previous = load_backup
mine_users    = Array(previous['user_ids'])
mine_projects = Array(previous['project_ids'])

# The capture account from a previous run counts as ours too — it is recorded
# separately from user_ids, and renaming LOGIN between runs would otherwise make
# the guard trip on the account this very script created.
mine = mine_users + [previous['capture_user_id']].compact
foreign_users = User.where(:type => 'User').where.not(:id => mine)
                    .where.not(:login => ['admin', LOGIN, '']).count
foreign_projects = Project.where.not(:id => mine_projects).count

if (foreign_users > 0 || foreign_projects > 0) && ENV['FORCE'] != '1'
  abort <<~MSG
    [seed] REFUSING TO RUN: this database already holds #{foreign_users} user(s) and
    [seed] #{foreign_projects} project(s) that this script did not create.

    [seed] The admin page and /metrics report installation-wide numbers, so a
    [seed] screenshot taken here would publish them. Point this at the empty
    [seed] screenshots stack instead:

    [seed]   docker-compose -f docker-compose.screenshots.yml up --build -d

    [seed] Set FORCE=1 only if you are certain the existing data is disposable.
  MSG
end

# --- Redmine default data ----------------------------------------------------

# A database that has only been migrated has no trackers, issue statuses,
# priorities or workflow — `rake db:migrate` does not load them, and the dev
# stack only has them because its dump came from production. Without them there
# is nothing to hang an issue on, so the seed bootstraps them itself rather than
# depending on somebody having remembered a separate rake task.
if Redmine::DefaultData::Loader.no_data?
  say 'loading Redmine default data (trackers, statuses, priorities, roles)'
  Redmine::DefaultData::Loader.load('en')
end

# --- capture user ------------------------------------------------------------

password = ENV['DEMO_PASSWORD'].presence || SecureRandom.alphanumeric(20)

# Only ever touch an account this script :created => adopting an existing login
# would elevate a real user to admin, reset their password, and delete them on
# teardown.
existing = User.find_by(:login => LOGIN)
if existing && existing.id != previous['capture_user_id']
  abort "[seed] A user '#{LOGIN}' already exists and was not created by this script. " \
        "Refusing to take it over."
end

capture = existing ||
          User.new(:login => LOGIN, :firstname => 'Sandra', :lastname => 'Weiss',
                   :mail => 'sandra.weiss@example.com')
capture.admin    = true
capture.language = 'en'
capture.password = password
capture.password_confirmation = password
capture.status = User::STATUS_ACTIVE
capture.save!
say "capture user #{LOGIN} / #{password}"

# --- wipe anything a previous run left behind --------------------------------

old_users = User.where(:id => mine).where.not(:id => capture.id)
Token.where(:user_id => old_users.select(:id)).delete_all
old_users.destroy_all
Project.where(:id => mine_projects).destroy_all

# Counters are installation-wide and keyed only by name and label, so there is no
# "our rows" to delete - wiping the table would take real notification history
# with it. Record whatever is there before touching it, and restore that on
# teardown. A previous run's own snapshot is carried forward, so re-running does
# not record its own numbers as the baseline.
counters_before = previous['counters_before']
if counters_before.nil? && ExpertMetricsCounter.available?
  counters_before = ExpertMetricsCounter.all.map do |row|
    { 'name' => row.name, 'label' => row.label, 'value' => row.value }
  end
end
say 'cleared previous demo rows'

# --- people ------------------------------------------------------------------

# Sorted by how recently they were active, because that is the order the admin
# page shows and it makes the "last activity" column read top to bottom.
# minutes_ago is the last request; sessions is how many browsers they hold.
PEOPLE = [
  { :first => 'Anna',    :last => 'Berger',     :minutes_ago => 1,   :sessions => 2, :status => :active },
  { :first => 'Tobias',  :last => 'Lindner',    :minutes_ago => 3,   :sessions => 1, :status => :active },
  { :first => 'Miriam',  :last => 'Kowalski',   :minutes_ago => 4,   :sessions => 1, :status => :active },
  { :first => 'Jonas',   :last => 'Reinhardt',  :minutes_ago => 9,   :sessions => 1, :status => :active },
  { :first => 'Sarah',   :last => 'Vogt',       :minutes_ago => 12,  :sessions => 2, :status => :active },
  { :first => 'Daniel',  :last => 'Hofmann',    :minutes_ago => 22,  :sessions => 1, :status => :active },
  { :first => 'Elena',   :last => 'Brandt',     :minutes_ago => 31,  :sessions => 1, :status => :active },
  { :first => 'Philipp', :last => 'Neumann',    :minutes_ago => 48,  :sessions => 1, :status => :active },
  # Logged in today but idle for longer than the widest :window => counts towards
  # "logins in the last 24 h" and towards sessions, but not towards active users.
  { :first => 'Katrin',  :last => 'Siebert',    :minutes_ago => 190, :sessions => 1, :status => :active },
  { :first => 'Markus',  :last => 'Engel',      :minutes_ago => 420, :sessions => 1, :status => :active },
  # No session at all — there to give redmine_users_total something per status.
  { :first => 'Lena',    :last => 'Petzold',    :minutes_ago => nil, :sessions => 0, :status => :registered },
  { :first => 'Oliver',  :last => 'Krause',     :minutes_ago => nil, :sessions => 0, :status => :locked },
  { :first => 'Nadine',  :last => 'Schuster',   :minutes_ago => nil, :sessions => 0, :status => :active },
  { :first => 'Stefan',  :last => 'Aumann',     :minutes_ago => nil, :sessions => 0, :status => :active }
].freeze

STATUSES = {
  :active     => User::STATUS_ACTIVE,
  :registered => User::STATUS_REGISTERED,
  :locked     => User::STATUS_LOCKED
}.freeze

def backdate!(record, attrs)
  record.class.where(:id => record.id).update_all(attrs)
end

created = PEOPLE.each_with_index.map do |person, i|
  login = "#{person[:first][0].downcase}.#{person[:last].downcase}"
  user = User.new(:login => login,
                  :firstname => person[:first],
                  :lastname => person[:last],
                  :mail => "#{person[:first].downcase}.#{person[:last].downcase}@example.com",
                  :language => 'en')
  user.status = STATUSES.fetch(person[:status])
  user.password = SecureRandom.alphanumeric(24)
  user.save!

  # last_login_on drives redmine_recent_logins_users{window="24h"} and the
  # "logged in since" reading, so it has to predate the session.
  if person[:minutes_ago]
    login_at = NOW - (person[:minutes_ago] + 45 + i * 7).minutes
    backdate!(user, :last_login_on => login_at)
  end

  [user, person]
end

say "created #{created.size} users"

# --- sessions ----------------------------------------------------------------

# "Active" is read straight from Redmine's own session tokens: core bumps
# tokens.updated_on on every request (at most once a minute), so the windows are
# a comparison against that column. Rails would stamp both timestamps as now, so
# they are forced afterwards with update_all.
session_rows = 0
created.each do |user, person|
  next unless person[:minutes_ago]

  last_seen = NOW - person[:minutes_ago].minutes
  started   = user.last_login_on || (last_seen - 2.hours)

  person[:sessions].times do |n|
    token = Token.create!(:user => user, :action => 'session', :value => SecureRandom.hex(20))
    # A second browser is usually a little staler than the first.
    backdate!(token,
              :created_on => started + (n * 9).minutes,
              :updated_on => last_seen - (n * 4).minutes)
    session_rows += 1
  end
end
say "created #{session_rows} session tokens"

# --- projects and issues -----------------------------------------------------

PROJECTS = [
  { :name => 'Customer Support',   :issues_open => 34, :issues_closed => 186 },
  { :name => 'Warehouse Software', :issues_open => 21, :issues_closed => 97  },
  { :name => 'Website Relaunch',   :issues_open => 12, :issues_closed => 41  },
  { :name => 'Internal IT',        :issues_open => 9,  :issues_closed => 63  }
].freeze

tracker = Tracker.first || Tracker.create!(:name => 'Task', :default_status => IssueStatus.first)
open_status   = IssueStatus.where(:is_closed => false).order(:position).first
closed_status = IssueStatus.where(:is_closed => true).order(:position).first
priority      = IssuePriority.default || IssuePriority.first
author        = created.first.first

projects = PROJECTS.each_with_index.map do |spec, i|
  project = Project.create!(:name => spec[:name],
                            :identifier => spec[:name].parameterize,
                            :is_public => false)
  project.trackers = [tracker]
  project.save!

  [[spec[:issues_open], open_status], [spec[:issues_closed], closed_status]].each do |count, status|
    next if status.nil?
    count.times do |n|
      issue = Issue.new(:project => project, :tracker => tracker, :author => author,
                        :subject => "#{spec[:name]} item #{n + 1}",
                        :status => status, :priority => priority)
      issue.save!(:validate => false)
    end
  end
  backdate!(project, :created_on => NOW - (120 - i * 20).days)
  project
end

say "created #{projects.size} projects, #{Issue.count} issues"

# --- notification counters ---------------------------------------------------

# Written by the plugin's own Mail observer in normal operation; seeded directly
# here because nothing is actually sending mail on a screenshots stack.
if ExpertMetricsCounter.available?
  # Reset to the recorded baseline :first => increment! on top of a previous run's
  # numbers would stack them, and the screenshot would drift upwards every time.
  ExpertMetricsCounter.where(:name => ExpertMetricsCounter::NOTIFICATIONS_SENT).delete_all
  Array(counters_before).each do |row|
    next unless row['name'] == ExpertMetricsCounter::NOTIFICATIONS_SENT
    ExpertMetricsCounter.create!(:name => row['name'], :label => row['label'],
                                 :value => row['value'], :updated_on => Time.current)
  end

  projects.zip([412, 268, 143, 86]).each do |project, value|
    ExpertMetricsCounter.increment!(ExpertMetricsCounter::NOTIFICATIONS_SENT,
                                    project.identifier, value)
  end
  # Account and security mail carries no project header.
  ExpertMetricsCounter.increment!(ExpertMetricsCounter::NOTIFICATIONS_SENT, '', 57)
  say 'seeded notification counters'
else
  say 'expert_metrics_counters missing - run the plugin migration first'
end

# --- helpdesk mail ------------------------------------------------------------

# redmine_helpdesk_mails_total is one of the plugin's selling points, and the
# collector reads it straight from helpdesk_messages. Without a few rows the
# metric renders as a HELP block with no samples under it. Guarded, because the
# helpdesk plugin is optional.
if RedmineExpertMetrics::Collector.helpdesk_available?
  volumes = { 'in' => [148, 92, 21, 44], 'out' => [131, 80, 17, 39], 'init' => [12, 6, 3, 5] }
  total = 0
  projects.each_with_index do |project, i|
    issue = Issue.where(:project_id => project.id).first
    next if issue.nil?
    volumes.each do |direction, per_project|
      per_project[i].times do |n|
        HelpdeskMessage.create!(:issue => issue, :direction => direction,
                                :subject => "Demo message #{n + 1}",
                                :sent_at => NOW - (n + 1).hours)
        total += 1
      end
    end
  end
  say "created #{total} helpdesk messages"
else
  say 'helpdesk plugin not installed - skipping mail metrics'
end

# --- record what was created --------------------------------------------------

save_backup!('capture_user_id'  => capture.id,
             'user_ids'         => created.map { |user, _| user.id },
             'project_ids'      => projects.map(&:id),
             'counters_before'  => counters_before,
             'seeded_at'        => NOW.utc.iso8601)
say 'recorded ids in the settings backup row'

# The collector caches its snapshot for 15 s; drop it so the very next page load
# shows what was just seeded rather than a pre-seed reading.
Rails.cache.delete(RedmineExpertMetrics::Collector::CACHE_KEY)

say ''
say "done. Sign in at /login as #{LOGIN} / #{password}"
say 'then open /admin/active_users, /admin/active_users.json and /metrics'
