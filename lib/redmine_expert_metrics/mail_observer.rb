# Counts the notification mails Redmine core delivers to its users.
#
# Registered as a Mail observer (init.rb), so it sees every delivered message
# regardless of delivery method or ActiveJob. Core's Mailer stamps its mails
# with "X-Mailer: Redmine" and "X-Redmine-Project: <identifier>"; mails from
# redmine_expert_helpdesk to customers carry neither and are counted from the
# plugin's own helpdesk_messages table instead (see Collector). Account and
# security mails have no project and land under the empty label.
#
# Redmine sends one mail per recipient, so the counter is "notifications
# delivered", not "events notified".
module RedmineExpertMetrics
  module MailObserver
    module_function

    def delivered_email(mail)
      return unless header(mail, 'X-Mailer') == 'Redmine'
      ExpertMetricsCounter.increment!(ExpertMetricsCounter::NOTIFICATIONS_SENT,
                                      header(mail, 'X-Redmine-Project'))
    rescue StandardError => e
      # Never let bookkeeping break mail delivery.
      Rails.logger.warn("redmine_expert_metrics: could not count notification (#{e.class}: #{e.message})")
    end

    def header(mail, name)
      field = mail.header[name]
      field = field.first if field.is_a?(Array)
      field.nil? ? '' : field.value.to_s.strip
    end
  end
end
