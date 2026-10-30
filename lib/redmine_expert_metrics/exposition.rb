# Renders a Collector snapshot in the Prometheus text exposition format
# (version 0.0.4). Only aggregate numbers, never user names.
module RedmineExpertMetrics
  module Exposition
    CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'.freeze

    module_function

    def render(snapshot, plugin_version)
      lines = []

      gauge(lines, 'redmine_active_users',
            'Distinct users with at least one session request in the given window.')
      snapshot['active_users'].each do |window, count|
        lines << sample('redmine_active_users', { 'window' => window }, count)
      end

      gauge(lines, 'redmine_sessions_total',
            'Session tokens Redmine would still accept (logged-in browser sessions, active or idle).')
      lines << sample('redmine_sessions_total', {}, snapshot['sessions'])

      gauge(lines, 'redmine_recent_logins_users',
            'Distinct users whose last login is within the given window.')
      lines << sample('redmine_recent_logins_users', { 'window' => '24h' }, snapshot['recent_logins_24h'])

      gauge(lines, 'redmine_users_total', 'User accounts by status.')
      snapshot['users'].each do |status, count|
        lines << sample('redmine_users_total', { 'status' => status }, count)
      end

      gauge(lines, 'redmine_projects_total', 'Projects by status.')
      lines << sample('redmine_projects_total', { 'status' => 'active' }, snapshot['projects_active'])

      gauge(lines, 'redmine_issues_total', 'Issues by open/closed state of their status.')
      lines << sample('redmine_issues_total', { 'state' => 'open' }, snapshot['issues_open'])
      lines << sample('redmine_issues_total', { 'state' => 'closed' }, snapshot['issues_closed'])

      counter(lines, 'redmine_notifications_sent_total',
              'Notification mails Redmine core delivered to its users (one per recipient), by project identifier; empty project for account and security mails.')
      snapshot['notifications_sent'].to_h.each do |project, count|
        lines << sample('redmine_notifications_sent_total', { 'project' => project }, count)
      end

      if snapshot['helpdesk_mails']
        counter(lines, 'redmine_helpdesk_mails_total',
                'Mails recorded by redmine_expert_helpdesk per project: in = received from customers, out = sent to customers, init = initial mail of a ticket opened in Redmine.')
        snapshot['helpdesk_mails'].each do |project, directions|
          directions.each do |direction, count|
            lines << sample('redmine_helpdesk_mails_total',
                            { 'project' => project, 'direction' => direction }, count)
          end
        end
      end

      # nil while API usage recording is switched off: series left out.
      render_api(lines, snapshot) unless snapshot['api_keys'].nil?

      gauge(lines, 'redmine_metrics_collect_seconds',
            'Wall time of the last uncached collection of these metrics.')
      lines << sample('redmine_metrics_collect_seconds', {}, snapshot['collect_seconds'])

      gauge(lines, 'redmine_info', 'Redmine and plugin version as labels; value is always 1.')
      lines << sample('redmine_info',
                      { 'redmine_version' => Redmine::VERSION.to_s, 'plugin_version' => plugin_version.to_s }, 1)

      lines.join("\n") + "\n"
    end

    # Help texts of the per-process performance series (see Performance).
    PERFORMANCE_COUNTERS = {
      'redmine_http_request_db_seconds_total' => 'Time spent in SQL statements, by controller, action and format. Per process.',
      'redmine_http_request_view_seconds_total' => 'Time spent rendering views (without SQL), by controller, action and format. Per process.',
      'redmine_http_request_hook_seconds_total' => 'Time spent in plugin hook listeners, by controller, action and format. Per process.',
      'redmine_http_request_sql_queries_total' => 'SQL statements sent to the database (query-cache hits not counted), by controller, action and format. Per process.',
      'redmine_http_server_errors_total' => 'Requests answered with a 5xx status, by controller and action. Per process.',
      'redmine_hook_seconds_total' => 'Time spent in a hook listener (inclusive of hooks it triggers), by hook and listener class. Per process.',
      'redmine_hook_calls_total' => 'Calls of a hook listener, by hook and listener class. Per process.',
      'redmine_job_failures_total' => 'Background jobs that raised, by job class. Per process.'
    }.freeze

    PERFORMANCE_HISTOGRAMS = {
      'redmine_http_request_duration_seconds' => 'Time Redmine spent on a request (callbacks, action, rendering), by controller, action and format. Per process.',
      'redmine_job_duration_seconds' => 'Run time of background jobs, by job class. Per process.'
    }.freeze

    # Per-process series: never part of the cached Collector snapshot, which is
    # shared by every pod. +registry+ is Registry#snapshot, +process+ is
    # Performance.process_stats.
    def render_performance(registry, process)
      lines = []

      PERFORMANCE_HISTOGRAMS.each do |name, help|
        metric = registry[:histograms][name]
        next if metric.nil?
        histogram(lines, name, help)
        metric[:series].each do |labels, data|
          cumulative = 0
          metric[:bounds].each_with_index do |bound, index|
            cumulative += data[:buckets][index]
            lines << sample("#{name}_bucket", labels.merge('le' => bound.to_s), cumulative)
          end
          lines << sample("#{name}_bucket", labels.merge('le' => '+Inf'), data[:count])
          lines << sample("#{name}_sum", labels, number(data[:sum]))
          lines << sample("#{name}_count", labels, data[:count])
        end
      end

      PERFORMANCE_COUNTERS.each do |name, help|
        series = registry[:counters][name]
        next if series.nil?
        counter(lines, name, help)
        series.each { |labels, value| lines << sample(name, labels, number(value)) }
      end

      render_process(lines, process)
      lines.empty? ? '' : lines.join("\n") + "\n"
    end

    def render_process(lines, process)
      if process['resident_memory_bytes']
        gauge(lines, 'redmine_process_resident_memory_bytes', 'Resident memory (RSS) of this Redmine process.')
        lines << sample('redmine_process_resident_memory_bytes', {}, process['resident_memory_bytes'])
      end
      gauge(lines, 'redmine_process_start_time_seconds', 'Start of this Redmine process, Unix time.')
      lines << sample('redmine_process_start_time_seconds', {}, number(process['start_time_seconds']))
      gauge(lines, 'redmine_ruby_threads', 'Ruby threads in this process.')
      lines << sample('redmine_ruby_threads', {}, process['threads'])
      if process['gc_minor'] && process['gc_major']
        counter(lines, 'redmine_ruby_gc_runs_total', 'Garbage collector runs of this process, minor and major.')
        lines << sample('redmine_ruby_gc_runs_total', { 'type' => 'minor' }, process['gc_minor'])
        lines << sample('redmine_ruby_gc_runs_total', { 'type' => 'major' }, process['gc_major'])
      end
      if process['gc_seconds']
        counter(lines, 'redmine_ruby_gc_seconds_total', 'Time this process spent in garbage collection (Ruby 3.1+).')
        lines << sample('redmine_ruby_gc_seconds_total', {}, number(process['gc_seconds']))
      end
      if process['heap_live_slots']
        gauge(lines, 'redmine_ruby_heap_live_slots', 'Live object slots on the Ruby heap.')
        lines << sample('redmine_ruby_heap_live_slots', {}, process['heap_live_slots'])
      end
      if process['allocated_objects']
        counter(lines, 'redmine_ruby_allocated_objects_total', 'Objects allocated by this process since it started.')
        lines << sample('redmine_ruby_allocated_objects_total', {}, process['allocated_objects'])
      end
      puma = process['puma']
      return if puma.nil?
      {
        'backlog'       => 'Requests waiting for a Puma thread.',
        'running'       => 'Puma threads started.',
        'pool_capacity' => 'Requests Puma could take on right now.',
        'max_threads'   => 'Configured maximum of Puma threads.'
      }.each do |key, help|
        gauge(lines, "redmine_puma_#{key}", help)
        lines << sample("redmine_puma_#{key}", {}, puma[key].to_i)
      end
    end

    def render_api(lines, snapshot)
      counter(lines, 'redmine_api_requests_total',
              'Requests authenticated by API credentials since the plugin recorded them, by HTTP method and auth (key, basic = API key as Basic user, password, oauth).')
      snapshot['api_requests'].to_h.each do |method, auths|
        auths.each do |auth, count|
          lines << sample('redmine_api_requests_total', { 'method' => method, 'auth' => auth }, count)
        end
      end

      gauge(lines, 'redmine_api_users',
            'Distinct users with at least one API request in the last n calendar days (today included).')
      snapshot['api_users'].to_h.each do |window, count|
        lines << sample('redmine_api_users', { 'window' => window }, count)
      end

      gauge(lines, 'redmine_api_keys_total', 'Users holding an API key.')
      lines << sample('redmine_api_keys_total', {}, snapshot['api_keys'].to_i)
    end

    def gauge(lines, name, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} gauge"
    end

    def counter(lines, name, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} counter"
    end

    def histogram(lines, name, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} histogram"
    end

    # Floats without exponent noise; integers stay integers.
    def number(value)
      value.is_a?(Float) ? value.round(6) : value
    end

    def sample(name, labels, value)
      label_text =
        if labels.empty?
          ''
        else
          '{' + labels.map { |k, v| "#{k}=\"#{escape(v)}\"" }.join(',') + '}'
        end
      "#{name}#{label_text} #{value}"
    end

    # Label values: backslash, double quote and newline must be escaped.
    def escape(value)
      value.to_s.gsub('\\', '\\\\\\\\').gsub('"', '\\"').gsub("\n", '\\n')
    end
  end
end
