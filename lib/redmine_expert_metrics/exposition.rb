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

      gauge(lines, 'redmine_metrics_collect_seconds',
            'Wall time of the last uncached collection of these metrics.')
      lines << sample('redmine_metrics_collect_seconds', {}, snapshot['collect_seconds'])

      gauge(lines, 'redmine_info', 'Redmine and plugin version as labels; value is always 1.')
      lines << sample('redmine_info',
                      { 'redmine_version' => Redmine::VERSION.to_s, 'plugin_version' => plugin_version.to_s }, 1)

      lines.join("\n") + "\n"
    end

    def gauge(lines, name, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} gauge"
    end

    def counter(lines, name, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} counter"
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
