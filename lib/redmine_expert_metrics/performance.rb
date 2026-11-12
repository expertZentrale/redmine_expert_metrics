require 'json'
require 'socket'

# Performance metrics: how long requests take per controller#action, how much
# of it is database, view and plugin hooks, how many SQL statements they run,
# how long background jobs take, and how the process itself is doing (memory,
# GC, Puma). Opt-in via the plugin setting "Record performance metrics"; while
# it is off, a request costs one setting lookup and nothing else.
#
# Per request, RequestTimingPatch opens a Stats object in a thread-local slot.
# The sql.active_record and process_action subscribers, HookTimingPatch and
# RequestTimingPatch's own render timing add to it while it is open, so
# nothing is recorded for work outside a request.
# The SQL and request subscribers are attached only while the setting is on
# (sync_subscriptions, called by every request): switched off, SQL statements
# run no callback of ours, and a hook call costs HookTimingPatch one
# thread-local check. The job subscriber stays attached (install_job_subscriber!,
# from init.rb): jobs are rare, it checks the setting itself, and a process that
# only runs jobs never passes through a request to attach it.
# When the request ends, finish_request books it into the in-process Registry
# with one lock, sends a Server-Timing header to admins and stores requests
# over the threshold as ExpertMetricsSlowRequest rows, with the slowest
# statements and the most frequent statement shapes (Stats#frequent_sql: an
# N+1 is many fast statements of one shape, invisible among the slowest).
#
# Recording never breaks a request: every error is logged and swallowed.
module RedmineExpertMetrics
  module Performance
    THREAD_KEY = :redmine_expert_metrics_request

    DEFAULT_THRESHOLD_MS = 2000

    # Seconds. Redmine pages take tens of milliseconds to seconds; the upper
    # buckets catch the pathological ones the dashboard is for.
    REQUEST_BUCKETS = [0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0].freeze
    JOB_BUCKETS = [0.1, 0.5, 1.0, 5.0, 15.0, 60.0, 300.0, 1800.0].freeze

    # Formats as labels; anything else (*/*, nil, exotic MIME types) is "other",
    # which keeps the label set bounded.
    FORMATS = %w(html js json xml atom csv pdf ics png text).freeze

    # Slow-request details: the slowest statements and hook listeners kept per
    # request, and how long a statement may be.
    TOP_SQL = 5
    TOP_HOOKS = 10
    SQL_MAX_LENGTH = 1000
    # The most frequent statement shapes kept per slow request. An N+1 query is
    # thousands of fast statements of one shape, none of them among the slowest,
    # so the slowest alone never show it.
    TOP_FREQUENT_SQL = 5
    # Shapes counted per request; statements of further shapes are counted in
    # sql_count but not grouped, which bounds memory for pathological requests.
    MAX_SQL_SHAPES = 200
    # How much of a statement groups it into a shape (see Performance.shape_key).
    SHAPE_KEY_LENGTH = 300
    # Literals masked in a shape key: the ones fingerprint replaces (single-
    # quoted and PostgreSQL dollar-quoted strings, 0x hex, decimal and scientific
    # numbers) as one alternation, so the key costs one pass. Double-quoted
    # strings only where they are strings (double_quoted_strings?). A string the
    # prefix cuts off (no closing quote before its end, \z) is masked to the
    # end, so a long value straddling the cut does not split its statements.
    SHAPE_LITERALS = /'(?:[^'\\]|\\.|'')*(?:'|\z)|\$([A-Za-z_][A-Za-z_0-9]*|)\$.*?(?:\$\1\$|\z)|\b0x[0-9A-Fa-f]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/m
    SHAPE_LITERALS_DOUBLE_QUOTED = /'(?:[^'\\]|\\.|'')*(?:'|\z)|"(?:[^"\\]|\\.|"")*(?:"|\z)|\$([A-Za-z_][A-Za-z_0-9]*|)\$.*?(?:\$\1\$|\z)|\b0x[0-9A-Fa-f]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/m
    # A shape keeps its first statement as it came (fingerprinted only if it
    # makes the stored top five) up to this length; longer ones - big INSERTs,
    # long IN lists - are fingerprinted when first seen, so what a request holds
    # stays bounded at MAX_SQL_SHAPES statements of this size.
    SHAPE_SQL_KEEP = 4000
    # Writes of slow-request rows per process and minute. A slow database makes
    # every request slow; recording each one would add load where there is
    # already too much.
    MAX_SLOW_WRITES_PER_MINUTE = 30

    # Statements that are not the application's work.
    IGNORED_SQL_NAMES = %w(SCHEMA EXPLAIN).freeze

    PROCESS_STARTED_AT = Time.now.to_f

    REGISTRY = Registry.new
    SLOW_LOCK = Mutex.new
    SUBSCRIBE_LOCK = Mutex.new

    # What one request did. Only touched by the thread serving it.
    class Stats
      attr_reader :started, :gc_started, :sql_count, :sql_cached, :sql_ms, :top_sql,
                  :view_ms, :hooks_ms, :hooks
      attr_accessor :status, :format, :hook_depth

      def initialize
        @started = Performance.monotonic
        @gc_started = Performance.gc_time_ms
        @sql_count = 0
        @sql_cached = 0
        @sql_ms = 0.0
        @view_ms = 0.0
        @top_sql = []
        @shapes = {}
        @shapes_by_text = {}
        @hooks_ms = 0.0
        @hooks = {}
        @hook_depth = 0
      end

      def add_sql(name, sql, ms, cached)
        count_shape(name, sql, ms, cached)
        if cached
          @sql_cached += 1
          return
        end
        @sql_count += 1
        @sql_ms += ms
        return if @top_sql.size >= TOP_SQL && ms <= @top_sql.last[:ms]
        @top_sql << { :ms => ms.round(1), :name => name.to_s, :sql => Performance.fingerprint(sql) }
        @top_sql.sort_by! { |entry| -entry[:ms] }
        @top_sql.pop if @top_sql.size > TOP_SQL
      end

      # The statement shapes run most often, most executions (database plus
      # query cache) first: [{ :count, :cached, :ms, :name, :sql }]. Shapes that
      # ran once are left out - a list of one-offs says nothing a slow
      # statement would not. Fingerprints only these few, and only when asked (a
      # slow request is being stored), so counting costs every request just the
      # shape key.
      def frequent_sql
        repeated = @shapes.values.select { |entry| entry[:count] + entry[:cached] > 1 }
        top = repeated.sort_by { |entry| [-(entry[:count] + entry[:cached]), -entry[:ms]] }
        top.first(TOP_FREQUENT_SQL).map do |entry|
          { :count => entry[:count], :cached => entry[:cached], :ms => entry[:ms].round(1),
            :name => entry[:name], :sql => entry[:fingerprint] || Performance.fingerprint(entry[:sql]) }
        end
      end

      # One render, without its SQL (RequestTimingPatch#cleanup_view_runtime).
      # Clock and SQL timings can disagree by a fraction of a millisecond, so
      # a render that was all SQL never goes below zero.
      def add_view(ms)
        @view_ms += ms if ms > 0
      end

      # Listener time is inclusive (a hook that renders a partial calling another
      # hook contains it); the request total counts only the outermost hooks, so
      # nothing is counted twice there.
      def add_hook(hook, listener, ms, outermost)
        entry = (@hooks[[hook.to_s, listener]] ||= [0.0, 0])
        entry[0] += ms
        entry[1] += 1
        @hooks_ms += ms if outermost
      end

      private

      # Keeps the first statement of each shape as it came (a reference, not a
      # copy) for frequent_sql to fingerprint whole: fingerprinting a cut-off
      # statement could leave half a string literal, and a value with it, in the
      # stored text. Statements over SHAPE_SQL_KEEP are fingerprinted right away
      # instead, which is safe (whole statement) and bounds what is kept.
      #
      # Rails before 5.1 names every query-cache hit "CACHE" (later versions keep
      # the statement's name and set :cached); such a hit is booked on the shape
      # with the same masked text, so it counts with the statement it repeats.
      # The statement it repeats has always run before it, so that text names
      # one shape - unless statements of different names share it; then the
      # hit cannot tell which it repeats and stays a CACHE shape of its own.
      def count_shape(name, sql, ms, cached)
        label = Performance.statement_label(name)
        key = Performance.shape_key(label, sql)
        entry = @shapes[key]
        entry ||= @shapes_by_text[key.last] if cached && label == 'CACHE'
        if entry.nil?
          return if @shapes.size >= MAX_SQL_SHAPES
          entry = @shapes[key] = { :name => label, :count => 0, :cached => 0, :ms => 0.0 }
          remember_text(key.last, entry) unless label == 'CACHE'
          text = sql.to_s
          if text.length > SHAPE_SQL_KEEP
            entry[:fingerprint] = Performance.fingerprint(text)
          else
            entry[:sql] = text
          end
        end
        if cached
          entry[:cached] += 1
        else
          entry[:count] += 1
          entry[:ms] += ms
        end
      end

      # nil once a second shape has the same masked text (ambiguous for good).
      def remember_text(text, entry)
        @shapes_by_text[text] = @shapes_by_text.key?(text) ? nil : entry
      end
    end

    module_function

    def enabled?
      Setting.plugin_redmine_expert_metrics['performance_metrics_enabled'].to_s == '1'
    rescue StandardError
      false
    end

    # Milliseconds; a key missing from the stored settings (installs older than
    # 1.4.0, which never saved the form) reads as the default.
    def threshold_ms
      value = Setting.plugin_redmine_expert_metrics['slow_request_threshold_ms'].to_s.strip
      /\A\d+\z/.match?(value) ? value.to_i : DEFAULT_THRESHOLD_MS
    rescue StandardError
      DEFAULT_THRESHOLD_MS
    end

    def current
      Thread.current[THREAD_KEY]
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Total GC time of the process in ms, nil before Ruby 3.1. GC stops every
    # thread, so the difference over a request is the pause that request saw.
    def gc_time_ms
      GC.respond_to?(:total_time) ? GC.total_time / 1_000_000.0 : nil
    end

    # Attaches or detaches the notification subscribers to match the setting.
    # Called on every request with the setting it already read, so a change
    # takes effect in each process on its next request; the common case is one
    # instance-variable check.
    def sync_subscriptions(enabled)
      enabled ? attach! : detach!
    end

    def attached?
      !@subscribers.nil?
    end

    def attach!
      return if @subscribers

      SUBSCRIBE_LOCK.synchronize do
        @subscribers ||= subscribe_all
      end
    end

    def detach!
      return unless @subscribers

      SUBSCRIBE_LOCK.synchronize do
        subscribers = @subscribers
        @subscribers = nil
        Array(subscribers).each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      end
    end

    # Timed subscribers get monotonic seconds (monotonic_subscribe, Rails 6.1+):
    # plain subscribe hands over Time.now, which stands still under a frozen
    # clock (Redmine's tests travel_to a fixed time since 6.1) and jumps when
    # the system clock is adjusted.
    def subscribe_all
      subscribers = []
      subscribers << ActiveSupport::Notifications.monotonic_subscribe('sql.active_record') do |_name, started, finished, _id, payload|
        stats = current
        next if stats.nil? || IGNORED_SQL_NAMES.include?(payload[:name])
        begin
          cached = payload[:cached] || payload[:name] == 'CACHE'
          stats.add_sql(payload[:name], payload[:sql], (finished - started) * 1000.0, cached)
        rescue StandardError => e
          log_error('SQL not counted', e)
        end
      end

      subscribers << ActiveSupport::Notifications.subscribe('process_action.action_controller') do |_name, _started, _finished, _id, payload|
        stats = current
        next if stats.nil?
        stats.status = payload[:status]
        stats.format = payload[:format]
      end

      subscribers
    end

    # Once per process; init.rb runs again on every dev reload.
    def install_job_subscriber!
      return if @job_subscriber

      SUBSCRIBE_LOCK.synchronize do
        @job_subscriber ||= ActiveSupport::Notifications.monotonic_subscribe('perform.active_job') do |_name, started, finished, _id, payload|
          record_job(payload, finished - started)
        end
      end
    end

    def start_request
      Thread.current[THREAD_KEY] = Stats.new
    end

    # +error+: the exception that ends the request, if any.
    def finish_request(controller, stats, error)
      Thread.current[THREAD_KEY] = nil
      duration_ms = (monotonic - stats.started) * 1000.0
      gc_ms = gc_time_ms && stats.gc_started ? gc_time_ms - stats.gc_started : nil
      status = (stats.status || (error ? 500 : controller.response.status)).to_i
      labels = {
        'controller' => controller.controller_path.to_s,
        'action'     => controller.action_name.to_s,
        'format'     => format_label(stats.format)
      }.freeze

      book_request(labels, stats, duration_ms, status)
      server_timing(controller, stats, duration_ms, gc_ms) if error.nil?
      if duration_ms >= threshold_ms
        record_slow(controller, labels, stats, duration_ms, gc_ms, status)
      end
    rescue StandardError => e
      log_error('request not recorded', e)
    end

    def book_request(labels, stats, duration_ms, status)
      REGISTRY.update do |r|
        r.observe('redmine_http_request_duration_seconds', REQUEST_BUCKETS, labels, duration_ms / 1000.0)
        r.increment('redmine_http_request_db_seconds_total', labels, stats.sql_ms / 1000.0)
        r.increment('redmine_http_request_view_seconds_total', labels, stats.view_ms / 1000.0)
        r.increment('redmine_http_request_hook_seconds_total', labels, stats.hooks_ms / 1000.0)
        r.increment('redmine_http_request_sql_queries_total', labels, stats.sql_count)
        if status >= 500
          r.increment('redmine_http_server_errors_total',
                      { 'controller' => labels['controller'], 'action' => labels['action'] }.freeze)
        end
        stats.hooks.each do |(hook, listener), (ms, calls)|
          hook_labels = { 'hook' => hook, 'listener' => listener }.freeze
          r.increment('redmine_hook_seconds_total', hook_labels, ms / 1000.0)
          r.increment('redmine_hook_calls_total', hook_labels, calls)
        end
      end
    end

    # Timing breakdown for the browser's developer tools (Network -> Timing),
    # admins only: it describes the server, not the page.
    def server_timing(controller, stats, duration_ms, gc_ms)
      return unless User.current.admin?
      response = controller.response
      return if response.committed?

      parts = [
        "app;dur=#{duration_ms.round(1)}",
        "db;dur=#{stats.sql_ms.round(1)};desc=\"#{stats.sql_count} queries, #{stats.sql_cached} cached\"",
        "view;dur=#{stats.view_ms.round(1)}",
        "hooks;dur=#{stats.hooks_ms.round(1)}"
      ]
      parts << "gc;dur=#{gc_ms.round(1)}" if gc_ms
      response.headers['Server-Timing'] = parts.join(', ')
    end

    # Every slow request gets its warn line; only the database rows are rate
    # limited, since those are what would add load to a struggling database.
    def record_slow(controller, labels, stats, duration_ms, gc_ms, status)
      request = controller.request
      frequent = stats.frequent_sql
      Rails.logger.warn(
        "redmine_expert_metrics: slow request #{labels['controller']}##{labels['action']} " \
        "#{duration_ms.round}ms (db #{stats.sql_ms.round}ms/#{stats.sql_count} queries, " \
        "view #{stats.view_ms.round}ms, hooks #{stats.hooks_ms.round}ms) " \
        "status=#{status} path=#{request.path} request_id=#{request.request_id}" +
        most_frequent_note(frequent)
      )
      return unless slow_write_allowed? && ExpertMetricsSlowRequest.available?

      hooks = stats.hooks.map do |(hook, listener), (ms, calls)|
        { 'hook' => hook, 'listener' => listener, 'ms' => ms.round(1), 'calls' => calls }
      end
      hooks = hooks.sort_by { |entry| -entry['ms'] }.first(TOP_HOOKS)

      # frequent_sql arrives with db/migrate/004; until that has run, the row is
      # stored without it rather than not at all.
      extra = {}
      if ExpertMetricsSlowRequest.frequent_sql_available?
        extra[:frequent_sql] = frequent.map { |entry| entry.transform_keys(&:to_s) }.to_json
      end

      ExpertMetricsSlowRequest.create!(extra.merge(
        :created_at      => Time.now,
        :host            => hostname,
        :controller_name => labels['controller'][0, 100],
        :action_name     => labels['action'][0, 100],
        :http_method     => request.request_method.to_s[0, 10],
        :request_format  => labels['format'],
        :path            => request.path.to_s[0, 255],
        :status          => status,
        :duration_ms     => duration_ms.round,
        :db_ms           => stats.sql_ms.round,
        :view_ms         => stats.view_ms.round,
        :hooks_ms        => stats.hooks_ms.round,
        :gc_ms           => gc_ms && gc_ms.round,
        :sql_count       => stats.sql_count,
        :sql_cached      => stats.sql_cached,
        :top_sql         => stats.top_sql.map { |entry| entry.transform_keys(&:to_s) }.to_json,
        :hooks           => hooks.to_json,
        :user_id         => (User.current.logged? ? User.current.id : nil),
        :request_id      => request.request_id.to_s[0, 64]
      ))
      ExpertMetricsSlowRequest.purge_if_due
    rescue StandardError => e
      log_error('slow request not stored', e)
    end

    # " most_frequent=919x Checklist Load" for the warn line, so the log alone
    # names an N+1 (rows are rate limited, the line is not). Only when one shape
    # ran more than once; the name is Rails' statement name, never SQL text.
    def most_frequent_note(frequent)
      top = frequent.first
      return '' if top.nil?

      runs = top[:count] + top[:cached]
      runs > 1 ? " most_frequent=#{runs}x #{top[:name]}" : ''
    end

    def slow_write_allowed?
      SLOW_LOCK.synchronize do
        now = monotonic
        if @slow_window.nil? || now - @slow_window >= 60
          @slow_window = now
          @slow_writes = 0
        end
        @slow_writes += 1
        @slow_writes <= MAX_SLOW_WRITES_PER_MINUTE
      end
    end

    def reset_slow_limit!
      @slow_window = nil
    end

    def record_job(payload, seconds)
      return unless enabled?
      job = payload[:job]
      labels = { 'job_class' => job ? job.class.name.to_s : 'unknown' }.freeze
      REGISTRY.update do |r|
        r.observe('redmine_job_duration_seconds', JOB_BUCKETS, labels, seconds)
        r.increment('redmine_job_failures_total', labels) if payload[:exception_object]
      end
    rescue StandardError => e
      log_error('job not recorded', e)
    end

    # Literals become ? so statements of the same shape read alike and no
    # values (search terms, e-mail addresses) end up in the slow-request table:
    # single-quoted strings everywhere, double-quoted ones where they are
    # strings (MySQL/MariaDB - elsewhere they are identifiers), PostgreSQL
    # dollar-quoted strings, and numbers (decimal, scientific, 0x hex; X'..'
    # and b'..' are covered by the quotes).
    def fingerprint(sql)
      text = sql.to_s.gsub(/'(?:[^'\\]|\\.|'')*'/, '?')
      text = text.gsub(/"(?:[^"\\]|\\.|"")*"/, '?') if double_quoted_strings?
      # The empty alternative, not "?": a back-reference to a group that did not
      # take part never matches in Ruby, which would let $$...$$ through.
      text = text.gsub(/\$([A-Za-z_][A-Za-z_0-9]*|)\$.*?\$\1\$/m, '?')
      text = text.gsub(/\b0x[0-9A-Fa-f]+\b/, '?')
      text = text.gsub(/\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/, '?')
      text = text.gsub(/\(\?(?:\s*,\s*\?)+\)/, '(?...)')
      text = text.gsub(/\s+/, ' ').strip
      text.length > SQL_MAX_LENGTH ? text[0, SQL_MAX_LENGTH] + '...' : text
    end

    # Groups statements into shapes while a request runs: the statement's name
    # and its first SHAPE_KEY_LENGTH characters with the literals fingerprint
    # replaces masked (SHAPE_LITERALS). One pass over a short prefix, since it
    # runs for every statement; the key is never stored or shown
    # (Stats#frequent_sql fingerprints the whole statement for that). The
    # statements of an N+1 differ only in their literals and share a key; eager
    # loads whose column list runs past the prefix group under their name.
    def shape_key(name, sql)
      head = sql.to_s[0, SHAPE_KEY_LENGTH]
      literals = double_quoted_strings? ? SHAPE_LITERALS_DOUBLE_QUOTED : SHAPE_LITERALS
      [name.to_s, head.gsub(literals, '?')]
    end

    # The statement's name as Rails' log shows it: statements run without one
    # (nil on Rails 6.1, e.g. plain execute/select_all) read "SQL", so the page
    # and the warn line never show an empty name.
    def statement_label(name)
      label = name.to_s
      label.empty? ? 'SQL' : label
    end

    # MySQL/MariaDB read "..." as a string unless ANSI_QUOTES is set, which
    # Rails does not do. Unknown adapter: treat them as strings, so a value can
    # never slip through - the statement only reads worse.
    def double_quoted_strings?
      return @double_quoted_strings unless @double_quoted_strings.nil?

      adapter = ActiveRecord::Base.connection_db_config.adapter.to_s
      @double_quoted_strings = !(adapter =~ /postg|sqlite|sqlserver/i)
    rescue StandardError
      true
    end

    def format_label(format)
      value = format.to_s.downcase
      FORMATS.include?(value) ? value : 'other'
    end

    def hostname
      @hostname ||= Socket.gethostname.to_s[0, 64]
    rescue StandardError
      ''
    end

    # Point-in-time numbers of this process, read at scrape time.
    def process_stats
      stats = {}
      rss = resident_memory_bytes
      stats['resident_memory_bytes'] = rss if rss
      stats['start_time_seconds'] = PROCESS_STARTED_AT
      stats['threads'] = Thread.list.size
      gc = GC.stat
      stats['gc_minor'] = gc[:minor_gc_count] if gc.key?(:minor_gc_count)
      stats['gc_major'] = gc[:major_gc_count] if gc.key?(:major_gc_count)
      stats['gc_seconds'] = gc_time_ms / 1000.0 if gc_time_ms
      stats['heap_live_slots'] = gc[:heap_live_slots] if gc.key?(:heap_live_slots)
      stats['allocated_objects'] = gc[:total_allocated_objects] if gc.key?(:total_allocated_objects)
      stats['puma'] = puma_stats
      roundtrip = db_roundtrip_seconds
      stats['db_roundtrip_seconds'] = roundtrip if roundtrip
      stats
    end

    # One trivial statement on this process's database connection. On a healthy
    # link it takes well under a millisecond; while it is slow, every statement
    # of every request on this pod waits about as long - which tells a slow
    # database or network apart from one slow query. Bypasses the query cache.
    def db_roundtrip_seconds
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        ActiveRecord::Base.uncached do
          started = monotonic
          connection.select_value('SELECT 1', 'ExpertMetrics Roundtrip')
          monotonic - started
        end
      end
    rescue StandardError => e
      log_error('database round trip', e)
      nil
    end

    # Linux only; nil elsewhere (and the series is left out).
    def resident_memory_bytes
      line = File.foreach('/proc/self/status').find { |l| l.start_with?('VmRSS:') }
      line ? line.split[1].to_i * 1024 : nil
    rescue StandardError
      nil
    end

    # Single-mode Puma (one process per pod, threads): backlog = requests
    # waiting for a thread, pool_capacity = requests it could take right now.
    # nil when not running under Puma or in cluster mode.
    def puma_stats
      return nil unless defined?(::Puma) && ::Puma.respond_to?(:stats_hash)
      raw = ::Puma.stats_hash
      return nil unless raw.is_a?(Hash)
      raw = raw.transform_keys(&:to_s)
      keys = %w(backlog running pool_capacity max_threads)
      return nil unless keys.all? { |key| raw.key?(key) }
      raw.slice(*keys)
    rescue StandardError
      nil
    end

    def log_error(what, error)
      Rails.logger.warn("redmine_expert_metrics: #{what} (#{error.class}: #{error.message})")
    end
  end
end
