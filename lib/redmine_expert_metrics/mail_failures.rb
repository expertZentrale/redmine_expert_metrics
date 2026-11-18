# Logs and counts every mail that ActionMailer fails to deliver.
#
# Core's Mailer.deliver_mail catches delivery errors and logs only
# "Email delivery error: <message>": no recipient, no object. Mail then informs
# its observers as if the mail had gone out. ActionMailer wraps each delivery
# in the "deliver.action_mailer" event, and when the SMTP server rejects the
# mail or does not answer, the event's payload carries the exception next to
# the recipients and the Message-ID. Core's Message-ID names the object and the
# recipient's user id ("redmine.journal-123.20261118122404.628@host"), so the
# warn line written here says which notification failed for whom.
#
# The event covers every mailer that sends through ActionMailer (core
# notifications, plugin mailers); the counter keeps them apart by mailer class.
# Mail sent past ActionMailer (Net::SMTP directly, an HTTP API) is not seen.
#
# Recording never breaks mail delivery: every error is logged and swallowed.
module RedmineExpertMetrics
  module MailFailures
    EVENT = 'deliver.action_mailer'.freeze
    # Message-ID of the last mail that failed in this thread. Mail informs its
    # observers right after the delivery handler returns, also when core's
    # Mailer swallowed the error, so MailObserver asks failed? first.
    THREAD_KEY = :redmine_expert_metrics_failed_message_id
    # Long SMTP replies are cut. Exchange Online's end in a server and trace id,
    # which is what its support asks for, so the cut is generous.
    ERROR_MAX_LENGTH = 300
    # An SMTP reply: the code, and the enhanced status code when there is one
    # ("550 5.4.1 ...", "451-4.3.2 ..." for a multiline reply).
    SMTP_REPLY = /\A([245]\d\d)(?:[ -]([245]\.\d{1,3}\.\d{1,3}))?/
    SUBSCRIBE_LOCK = Mutex.new

    module_function

    # Attached once from init.rb, which runs again on every dev reload.
    def subscribe!
      return if @subscriber

      SUBSCRIBE_LOCK.synchronize do
        @subscriber ||= ActiveSupport::Notifications.subscribe(EVENT) do |*args|
          record(args.last)
        end
      end
    end

    def record(payload)
      error = payload[:exception_object]
      return if error.nil?

      Thread.current[THREAD_KEY] = payload[:message_id]
      reason = reason(error)
      mailer = payload[:mailer].to_s
      Rails.logger.warn(
        "redmine_expert_metrics: mail delivery failed: #{reason} mailer=#{mailer} " \
        "recipients=#{recipients(payload)} message_id=#{payload[:message_id]} " \
        "error=#{error.message.to_s.squish.truncate(ERROR_MAX_LENGTH)}"
      )
      # Plugin loaded but migration not run yet: the log line is all there is.
      return unless ExpertMetricsCounter.available?

      ExpertMetricsCounter.increment!(ExpertMetricsCounter::MAIL_DELIVERY_FAILURES, "#{mailer}|#{reason}")
    rescue StandardError => e
      Rails.logger.warn("redmine_expert_metrics: could not record a failed mail (#{e.class}: #{e.message})")
    end

    # "550 5.4.1" for an SMTP reply, the error class for anything else
    # ("Net::ReadTimeout", "EOFError"). Both come from a small set, so the
    # reason works as a metric label.
    def reason(error)
      match = SMTP_REPLY.match(error.message.to_s)
      match ? match.captures.compact.join(' ') : error.class.name
    end

    # Whether this mail is the one that just failed in this thread. Clears the
    # mark either way: a mailer that re-raises skips the observers, and its
    # mark must not stick to the next mail.
    def failed?(mail)
      failed_id = Thread.current[THREAD_KEY]
      return false if failed_id.nil?

      Thread.current[THREAD_KEY] = nil
      failed_id == mail.message_id
    end

    def recipients(payload)
      [payload[:to], payload[:cc], payload[:bcc]].flatten.compact.uniq.join(',')
    end
  end
end
