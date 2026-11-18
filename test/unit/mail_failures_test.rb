require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class RedmineExpertMetricsMailFailuresTest < ActiveSupport::TestCase
  fixtures :projects, :enabled_modules, :issues, :users, :email_addresses, :user_preferences,
           :members, :member_roles, :roles, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :journals, :journal_details, :versions, :issue_categories,
           :custom_fields, :custom_values, :custom_fields_projects, :custom_fields_trackers,
           :watchers, :groups_users

  class RecipientRejected < StandardError; end

  # What Exchange Online answers for a recipient it does not know.
  class RejectingDelivery
    def initialize(_settings = {}); end

    def deliver!(_mail)
      raise RecipientRejected,
            '550 5.4.1 Recipient address rejected: Access denied. For more information see ' \
            'https://aka.ms/EXOSmtpErrors [AM0PR01MB0001.eurprd01.prod.outlook.com 2026-11-18T12:24:05.070Z 08DF44DE6DA44A47]'
    end
  end

  class TimingOutDelivery
    def initialize(_settings = {}); end

    def deliver!(_mail)
      raise Net::ReadTimeout
    end
  end

  def setup
    ExpertMetricsCounter.delete_all
    Thread.current[RedmineExpertMetrics::MailFailures::THREAD_KEY] = nil
    ActionMailer::Base.add_delivery_method :expert_metrics_rejecting, RejectingDelivery
    ActionMailer::Base.add_delivery_method :expert_metrics_timing_out, TimingOutDelivery
    @delivery_method = ActionMailer::Base.delivery_method
    @raise_delivery_errors = ActionMailer::Base.raise_delivery_errors
    # As in production: core's Mailer logs the error and carries on.
    ActionMailer::Base.raise_delivery_errors = false
  end

  def teardown
    ActionMailer::Base.delivery_method = @delivery_method
    ActionMailer::Base.raise_delivery_errors = @raise_delivery_errors
    Thread.current[RedmineExpertMetrics::MailFailures::THREAD_KEY] = nil
  end

  def test_rejected_notification_is_logged_with_recipient_and_message_id
    ActionMailer::Base.delivery_method = :expert_metrics_rejecting
    log = capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now }

    line = log.lines.grep(/mail delivery failed/).first
    assert line, "no warn line in:\n#{log}"
    assert_includes line, 'redmine_expert_metrics: mail delivery failed: 550 5.4.1 mailer=Mailer '
    assert_includes line, 'recipients=jsmith@somenet.foo '
    # Core's Message-ID names the issue and the recipient's user id.
    assert_match(/message_id=redmine\.issue-1\.\d+\.2@\S+ /, line)
    assert_includes line, 'error=550 5.4.1 Recipient address rejected: Access denied.'
    # Core still writes its own line; the plugin adds to it, it does not replace it.
    assert_match(/Email delivery error: 550 5\.4\.1/, log)
  end

  def test_failures_are_counted_per_mailer_and_reason_and_not_as_sent
    ActionMailer::Base.delivery_method = :expert_metrics_rejecting
    capture_log do
      Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now
      Mailer.issue_add(User.find(3), Issue.find(1)).deliver_now
    end
    ActionMailer::Base.delivery_method = :expert_metrics_timing_out
    capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now }

    assert_equal({ 'Mailer' => { '550 5.4.1' => 2, 'Net::ReadTimeout' => 1 } },
                 RedmineExpertMetrics::Collector.collect['mail_delivery_failures'])
    assert_equal({}, ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  # The mark of a failed mail must not make the observer skip the next one.
  def test_a_delivered_mail_after_a_failure_is_counted_as_sent
    ActionMailer::Base.delivery_method = :expert_metrics_rejecting
    capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now }
    ActionMailer::Base.delivery_method = :test
    Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now

    assert_equal({ 'ecookbook' => 1 }, ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  def test_successful_delivery_logs_nothing
    ActionMailer::Base.delivery_method = :test
    log = capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now }

    assert_no_match(/mail delivery failed/, log)
    assert_equal({}, RedmineExpertMetrics::Collector.collect['mail_delivery_failures'])
  end

  def test_reason_is_the_smtp_reply_code_or_the_error_class
    reason = ->(error) { RedmineExpertMetrics::MailFailures.reason(error) }
    assert_equal '550 5.4.1', reason.call(RecipientRejected.new('550 5.4.1 Recipient address rejected'))
    assert_equal '451 4.3.2', reason.call(RecipientRejected.new("451-4.3.2 Temporary server error\n451 4.3.2 Try again"))
    assert_equal '421', reason.call(RecipientRejected.new('421 Service not available'))
    assert_equal 'Net::ReadTimeout', reason.call(Net::ReadTimeout.new)
    assert_equal 'ArgumentError', reason.call(ArgumentError.new('SMTP To address may not be blank: []'))
  end

  def test_subscribing_twice_records_once
    RedmineExpertMetrics::MailFailures.subscribe!
    ActionMailer::Base.delivery_method = :expert_metrics_rejecting
    log = capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now }

    assert_equal 1, log.lines.grep(/mail delivery failed/).size
  end

  # minitest 6 (Redmine 7) no longer bundles minitest/mock, so swap the method by hand.
  def test_recording_errors_never_break_delivery
    sc = ExpertMetricsCounter.singleton_class
    sc.alias_method(:__orig_increment!, :increment!)
    begin
      sc.define_method(:increment!) { |*| raise IOError, 'db gone' }
      ActionMailer::Base.delivery_method = :expert_metrics_rejecting
      log = nil
      assert_nothing_raised { log = capture_log { Mailer.issue_add(User.find(2), Issue.find(1)).deliver_now } }
      assert_match(/could not record a failed mail \(IOError: db gone\)/, log)
    ensure
      sc.alias_method(:increment!, :__orig_increment!)
      sc.remove_method(:__orig_increment!)
    end
  end

  def test_exposition_renders_failures
    ExpertMetricsCounter.increment!(ExpertMetricsCounter::MAIL_DELIVERY_FAILURES, 'Mailer|550 5.4.1', 3)
    ExpertMetricsCounter.increment!(ExpertMetricsCounter::MAIL_DELIVERY_FAILURES, 'Mailer|Net::ReadTimeout')

    text = RedmineExpertMetrics::Exposition.render(RedmineExpertMetrics::Collector.collect, '1.9.0')
    assert_includes text, "# TYPE redmine_mail_delivery_failures_total counter\n"
    assert_includes text, "redmine_mail_delivery_failures_total{mailer=\"Mailer\",reason=\"550 5.4.1\"} 3\n"
    assert_includes text, "redmine_mail_delivery_failures_total{mailer=\"Mailer\",reason=\"Net::ReadTimeout\"} 1\n"
  end

  # A snapshot cached by 1.8.0 (shared across processes) has no such key.
  def test_exposition_tolerates_a_snapshot_without_failures
    data = RedmineExpertMetrics::Collector.collect.except('mail_delivery_failures')
    text = RedmineExpertMetrics::Exposition.render(data, '1.9.0')
    assert_includes text, "# TYPE redmine_mail_delivery_failures_total counter\n"
  end

  private

  def capture_log
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = previous
  end
end
