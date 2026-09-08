# Gathers everything the plugin exposes. Kept free of controller concerns so it
# can be unit-tested and reused (Prometheus text, admin page, JSON).
#
# "Active" is derived from Redmine's own session tokens: every browser session
# owns a row in `tokens` (action = "session") and core's
# User.verify_session_token bumps its updated_on on every request, at most once
# per minute. That is written regardless of the session store (cookie, Redis, DB)
# and is global for the whole installation, so every pod reports the same numbers.
# API-key requests never create a session token and therefore do not count.
module RedmineExpertMetrics
  module Collector
    # Label => minutes. Order is the order in the exposition and on the admin page.
    WINDOWS = { '5m' => 5, '15m' => 15, '60m' => 60 }.freeze

    # A scrape from every pod every 15-30 s would otherwise hit the database
    # each time. Production uses a Redis cache shared by all pods (see
    # additional_environment.rb), so one collection serves the whole deployment.
    CACHE_KEY = 'redmine_expert_metrics/snapshot'.freeze
    CACHE_TTL = 15.seconds

    USER_STATUS_LABELS = {
      User::STATUS_ACTIVE     => 'active',
      User::STATUS_REGISTERED => 'registered',
      User::STATUS_LOCKED     => 'locked'
    }.freeze

    module_function

    # Cached snapshot. Falls back to an uncached collection if the cache store
    # misbehaves (the Redis store already swallows errors, other stores may not).
    def snapshot
      Rails.cache.fetch(CACHE_KEY, :expires_in => CACHE_TTL) { collect } || collect
    rescue StandardError => e
      Rails.logger.warn("redmine_expert_metrics: cache unavailable (#{e.class}: #{e.message}), collecting uncached")
      collect
    end

    # Uncached collection. Plain hash with string keys so it survives any cache
    # serializer and can be rendered as JSON as-is.
    def collect
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      now = Time.now

      active_users = WINDOWS.each_with_object({}) do |(label, minutes), h|
        h[label] = session_scope.where('updated_on > ?', now - minutes.minutes).distinct.count(:user_id)
      end

      users_by_status = User.where(:type => 'User').group(:status).count
      users = USER_STATUS_LABELS.each_with_object({}) do |(status, label), h|
        h[label] = users_by_status[status].to_i
      end

      {
        'collected_at'      => now.utc.iso8601,
        'active_users'      => active_users,
        'sessions'          => valid_session_scope(now).count,
        'recent_logins_24h' => User.where(:type => 'User').where('last_login_on > ?', now - 24.hours).count,
        'users'             => users,
        'projects_active'   => Project.active.count,
        'issues_open'       => Issue.open.count,
        'issues_closed'     => Issue.open(false).count,
        'collect_seconds'   => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(4)
      }
    end

    # One row per user with a session request in the last +minutes+ minutes,
    # most recent activity first. Admin page and JSON only - never on /metrics.
    def active_user_details(minutes)
      since = Time.now - minutes.minutes
      rows = session_scope.where('tokens.updated_on > ?', since).group(:user_id)
                          .pluck(:user_id,
                                 Arel.sql('MAX(tokens.updated_on)'),
                                 Arel.sql('MIN(tokens.created_on)'),
                                 Arel.sql('COUNT(*)'))
      users = User.where(:id => rows.map(&:first)).index_by(&:id)
      rows.map do |user_id, last_activity, session_since, sessions|
        user = users[user_id]
        next if user.nil?
        {
          :user          => user,
          :last_activity => to_time(last_activity),
          :session_since => to_time(session_since),
          :sessions      => sessions.to_i
        }
      end.compact.sort_by { |row| -row[:last_activity].to_f }
    end

    def session_scope
      Token.where(:action => 'session')
    end

    # Session tokens core would still accept, using the same lifetime/timeout
    # rules as User.verify_session_token. With both settings at 0 every token
    # counts, which is what core does as well.
    def valid_session_scope(now = Time.now)
      scope = session_scope
      if Setting.session_lifetime?
        scope = scope.where('created_on > ?', now - Setting.session_lifetime.to_i.minutes)
      end
      if Setting.session_timeout?
        scope = scope.where('updated_on > ?', now - Setting.session_timeout.to_i.minutes)
      end
      scope
    end

    # Aggregates in pluck come back as Time on mysql2 but as String on some
    # adapters; normalise so callers can rely on Time.
    def to_time(value)
      value.is_a?(String) ? Time.zone.parse(value) : value
    end
  end
end
