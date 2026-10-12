# Gathers everything the plugin exposes. Kept free of controller concerns so it
# can be unit-tested and reused (Prometheus text, admin page, JSON).
#
# "Active" is derived from Redmine's own session tokens: every browser session
# owns a row in `tokens` (action = "session") and core's
# User.verify_session_token bumps its updated_on on every request, at most once
# per minute. That is written regardless of the session store (cookie, Redis, DB)
# and is global for the whole installation, so every pod reports the same numbers.
# API-key requests never create a session token and therefore do not count;
# they are recorded separately (ExpertMetricsApiUsage, see api_usage_details).
module RedmineExpertMetrics
  module Collector
    # Label => minutes. Order is the order in the exposition and on the admin page.
    WINDOWS = { '5m' => 5, '15m' => 15, '60m' => 60 }.freeze

    # Label => calendar days (today included) for distinct API users.
    API_WINDOWS = { '1d' => 1, '7d' => 7, '30d' => 30 }.freeze

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
        'notifications_sent' => notification_counts,
        'helpdesk_mails'    => helpdesk_mail_counts,
        'api_requests'      => api_request_counts,
        'api_users'         => api_user_counts,
        'api_keys'          => api_key_scope.count,
        'collect_seconds'   => (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(4)
      }
    end

    # Mails recorded by redmine_expert_helpdesk, per project identifier and
    # direction ("in" = received from customers, "out" = sent to customers,
    # "init" = initial mail of a ticket opened in Redmine). Cumulative counts
    # straight from helpdesk_messages, so Prometheus can treat them as counters.
    # nil when the helpdesk plugin is not installed.
    def helpdesk_mail_counts
      return nil unless helpdesk_available?
      rows = ::HelpdeskMessage.joins(:issue => :project)
                              .group('projects.identifier', 'helpdesk_messages.direction').count
      rows.each_with_object({}) do |((identifier, direction), count), h|
        (h[identifier] ||= {})[direction] = count
      end.sort.to_h
    end

    def helpdesk_available?
      defined?(::HelpdeskMessage) && ::HelpdeskMessage.table_exists?
    rescue StandardError
      false
    end

    # Delivered core notifications per project identifier. Empty until the
    # plugin migration has created the counter table, so /metrics keeps working
    # on a freshly installed plugin.
    def notification_counts
      return {} unless ExpertMetricsCounter.available?
      ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT)
    end

    # API requests since the plugin recorded them, by HTTP verb and auth method:
    # { 'GET' => { 'key' => 12 }, ... }. Counter semantics, survives the purge
    # of the daily usage rows.
    def api_request_counts
      return {} unless ExpertMetricsCounter.available?
      ExpertMetricsCounter.values(ExpertMetricsApiUsage::COUNTER).each_with_object({}) do |(label, count), h|
        verb, auth = label.split(':', 2)
        (h[verb] ||= {})[auth.to_s] = count
      end
    end

    # Distinct users with API traffic in the last n calendar days (today
    # included). Day granularity - that is what the usage table records.
    def api_user_counts
      return {} unless ExpertMetricsApiUsage.available?
      today = Date.today
      API_WINDOWS.each_with_object({}) do |(label, days), h|
        h[label] = ExpertMetricsApiUsage.where('day > ?', today - days).distinct.count(:user_id)
      end
    end

    # Per-user API usage over the last +days+ calendar days, most recent use
    # first, plus the users holding an API key without any use in that period.
    # Admin page and JSON only - never on /metrics.
    def api_usage_details(days)
      empty = { :users => [], :unused_keys => api_key_holders.values }
      return empty unless ExpertMetricsApiUsage.available?

      rows = ExpertMetricsApiUsage.where('day > ?', Date.today - days).to_a
      key_holders = api_key_holders
      users = User.where(:id => rows.map(&:user_id).uniq).index_by(&:id)
      as_users = User.where(:id => rows.map(&:last_as_user_id).compact.uniq).index_by(&:id)

      details = rows.group_by(&:user_id).map do |user_id, user_rows|
        user = users[user_id]
        next if user.nil?
        latest = user_rows.max_by { |row| row.last_at.to_f }
        clients = Hash.new(0)
        user_rows.each { |row| clients[row.user_agent] += row.requests }
        {
          :user           => user,
          :key_created_on => key_holders[user_id] && key_holders[user_id][:key_created_on],
          :requests       => user_rows.sum(&:requests),
          :writes         => user_rows.reject { |row| ExpertMetricsApiUsage::READ_METHODS.include?(row.http_method) }.sum(&:requests),
          :methods        => sum_by(user_rows, &:http_method),
          :auth_methods   => sum_by(user_rows, &:auth_method),
          :days_active    => user_rows.map(&:day).uniq.size,
          :clients        => clients.sort_by { |ua, count| [-count, ua] }.to_h,
          :last_used      => latest.last_at,
          :last_ip        => latest.last_ip,
          :last_path      => latest.last_path,
          :last_as_user   => as_users[latest.last_as_user_id]
        }
      end.compact.sort_by { |row| -row[:last_used].to_f }

      used = details.map { |row| row[:user].id }
      { :users => details, :unused_keys => key_holders.except(*used).values }
    end

    # API keys core would accept: User.find_by_api_key only resolves active
    # users, and the anonymous user (or a group) may own a stray token.
    def api_key_scope
      Token.where(:action => 'api').joins(:user)
           .where(:users => { :type => 'User', :status => User::STATUS_ACTIVE })
    end

    # { user_id => { :user, :key_created_on } } for every user with a usable API
    # key, ordered by login.
    def api_key_holders
      tokens = api_key_scope.pluck(:user_id, :created_on).to_h
      User.where(:id => tokens.keys).sort_by { |user| user.login.to_s.downcase }.each_with_object({}) do |user, h|
        h[user.id] = { :user => user, :key_created_on => tokens[user.id] }
      end
    end

    def sum_by(rows)
      rows.each_with_object(Hash.new(0)) { |row, h| h[yield(row)] += row.requests }.sort.to_h
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
