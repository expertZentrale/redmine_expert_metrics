# Counts helpdesk mails when redmine_expert_helpdesk records them, under the
# project the ticket is in at that moment. Moving or deleting the ticket later
# never lowers the count (Prometheus counter semantics); reading the totals from
# helpdesk_messages did, and every drop showed up as a spike of the whole
# project's mail count in increase() and rate().
#
# Included into HelpdeskMessage from init.rb, only when that plugin is present.
module RedmineExpertMetrics
  module HelpdeskMessagePatch
    def self.included(base)
      # after_commit, not after_create: a failure here must never undo the mail
      # record, and a rolled-back mail is not counted.
      base.after_commit :expert_metrics_count_mail, :on => :create
    end

    private

    def expert_metrics_count_mail
      # Plugin loaded but migration not run yet: count nothing, warn nothing.
      return unless ExpertMetricsCounter.available?
      # LegacyContactsImport writes historic customer mails without a mailbox;
      # a re-run would otherwise look like a flood of new mail. MailProcessor
      # records every real incoming mail with its mailbox.
      return if direction == 'in' && helpdesk_mailbox_id.nil?
      identifier = issue && issue.project && issue.project.identifier
      return if identifier.blank?
      ExpertMetricsCounter.increment!(ExpertMetricsCounter::HELPDESK_MAILS, "#{identifier}:#{direction}")
    rescue StandardError => e
      # Never let bookkeeping break mail processing.
      Rails.logger.warn("redmine_expert_metrics: could not count helpdesk mail (#{e.class}: #{e.message})")
    end
  end
end
