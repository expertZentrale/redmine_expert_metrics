require File.expand_path(File.dirname(__FILE__) + '/../test_helper')

class RedmineExpertMetricsMailCounterTest < ActiveSupport::TestCase
  fixtures :users, :email_addresses, :projects, :trackers, :projects_trackers,
           :issue_statuses, :issues, :enumerations

  def setup
    ExpertMetricsCounter.delete_all
  end

  def test_increment_creates_then_adds
    ExpertMetricsCounter.increment!('demo', 'a')
    ExpertMetricsCounter.increment!('demo', 'a')
    ExpertMetricsCounter.increment!('demo', 'b', 5)
    ExpertMetricsCounter.increment!('other')

    assert_equal({ 'a' => 2, 'b' => 5 }, ExpertMetricsCounter.values('demo'))
    assert_equal({ '' => 1 }, ExpertMetricsCounter.values('other'))
  end

  def test_observer_counts_core_notifications_per_project
    RedmineExpertMetrics::MailObserver.delivered_email(core_mail('ecookbook'))
    RedmineExpertMetrics::MailObserver.delivered_email(core_mail('ecookbook'))
    RedmineExpertMetrics::MailObserver.delivered_email(core_mail(nil))

    assert_equal({ '' => 1, 'ecookbook' => 2 },
                 ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  def test_observer_ignores_mail_not_sent_by_core
    plugin_mail = Mail.new do
      to 'customer@example.net'
      subject 'Re: your ticket'
    end
    RedmineExpertMetrics::MailObserver.delivered_email(plugin_mail)

    assert_equal({}, ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  def test_observer_is_registered_and_fires_on_delivery
    mail = core_mail('onlinestore')
    mail.delivery_method :test
    mail.deliver

    assert_equal({ 'onlinestore' => 1 },
                 ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  # minitest 6 (Redmine 7) no longer bundles minitest/mock, so swap the method by hand.
  def test_observer_swallows_errors
    sc = ExpertMetricsCounter.singleton_class
    sc.alias_method(:__orig_increment!, :increment!)
    sc.define_method(:increment!) { |*| raise IOError, 'db gone' }
    assert_nothing_raised { RedmineExpertMetrics::MailObserver.delivered_email(core_mail('ecookbook')) }
  ensure
    sc.alias_method(:increment!, :__orig_increment!)
    sc.remove_method(:__orig_increment!)
  end

  def test_collect_and_exposition_include_notification_counters
    ExpertMetricsCounter.increment!(ExpertMetricsCounter::NOTIFICATIONS_SENT, 'ecookbook', 3)

    data = RedmineExpertMetrics::Collector.collect
    assert_equal({ 'ecookbook' => 3 }, data['notifications_sent'])

    text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
    assert_includes text, "# TYPE redmine_notifications_sent_total counter\n"
    assert_includes text, "redmine_notifications_sent_total{project=\"ecookbook\"} 3\n"
  end

  def test_helpdesk_mail_counts_per_project_and_direction
    skip 'redmine_expert_helpdesk not installed' unless defined?(::HelpdeskMessage)
    issue = Issue.find(1) # project ecookbook
    record_mail(issue, 'in')
    record_mail(issue, 'in')
    record_mail(issue, 'out')

    data = RedmineExpertMetrics::Collector.collect
    assert_equal({ 'ecookbook' => { 'in' => 2, 'out' => 1 } }, data['helpdesk_mails'])

    text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
    assert_includes text, "# TYPE redmine_helpdesk_mails_total counter\n"
    assert_includes text, "redmine_helpdesk_mails_total{project=\"ecookbook\",direction=\"in\"} 2\n"
    assert_includes text, "redmine_helpdesk_mails_total{project=\"ecookbook\",direction=\"out\"} 1\n"
  end

  # Counting helpdesk_messages by the ticket's current project made the value
  # drop when a ticket moved, and Prometheus read every drop as a counter
  # reset: increase() then showed the whole project's mail count at once.
  def test_moving_a_ticket_does_not_lower_the_helpdesk_count
    skip 'redmine_expert_helpdesk not installed' unless defined?(::HelpdeskMessage)
    issue = Issue.find(1)
    record_mail(issue, 'in')
    issue.update_column(:project_id, 2)

    assert_equal({ 'ecookbook' => { 'in' => 1 } }, RedmineExpertMetrics::Collector.collect['helpdesk_mails'])
  end

  def test_deleting_messages_does_not_lower_the_helpdesk_count
    skip 'redmine_expert_helpdesk not installed' unless defined?(::HelpdeskMessage)
    issue = Issue.find(1)
    record_mail(issue, 'in')
    record_mail(issue, 'init')
    ::HelpdeskMessage.delete_all # what deleting the issue does (:dependent => :delete_all)

    assert_equal({ 'ecookbook' => { 'in' => 1, 'init' => 1 } },
                 RedmineExpertMetrics::Collector.collect['helpdesk_mails'])
  end

  # LegacyContactsImport records historic customer mail without a mailbox.
  def test_imported_legacy_mail_is_not_counted
    skip 'redmine_expert_helpdesk not installed' unless defined?(::HelpdeskMessage)
    ::HelpdeskMessage.create!(:issue => Issue.find(1), :direction => 'in')

    assert_equal({}, RedmineExpertMetrics::Collector.collect['helpdesk_mails'])
  end

  def test_counting_a_helpdesk_mail_swallows_errors
    # Before the stub, not inside it: an ensure would otherwise restore a stub
    # that was never set (plain CI runs this plugin without the helpdesk).
    skip 'redmine_expert_helpdesk not installed' unless defined?(::HelpdeskMessage)
    sc = ExpertMetricsCounter.singleton_class
    sc.alias_method(:__orig_increment!, :increment!)
    begin
      sc.define_method(:increment!) { |*| raise IOError, 'db gone' }
      message = nil
      assert_nothing_raised { message = record_mail(Issue.find(1), 'in') }
      assert message.persisted?
    ensure
      sc.alias_method(:increment!, :__orig_increment!)
      sc.remove_method(:__orig_increment!)
    end
  end

  def test_collect_and_observer_tolerate_missing_counter_table
    without_counter_table do
      assert_nothing_raised { RedmineExpertMetrics::MailObserver.delivered_email(core_mail('ecookbook')) }
      record_mail(Issue.find(1), 'in') if defined?(::HelpdeskMessage)
      data = RedmineExpertMetrics::Collector.collect
      assert_equal({}, data['notifications_sent'])
      assert_equal({}, data['helpdesk_mails']) if defined?(::HelpdeskMessage)
      text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
      assert_includes text, "# TYPE redmine_notifications_sent_total counter\n"
      assert_not_includes text, 'redmine_notifications_sent_total{'
    end
    assert_equal({}, ExpertMetricsCounter.values(ExpertMetricsCounter::NOTIFICATIONS_SENT))
  end

  def test_exposition_omits_helpdesk_metric_without_plugin
    data = RedmineExpertMetrics::Collector.collect.merge('helpdesk_mails' => nil)
    text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
    assert_not_includes text, 'redmine_helpdesk_mails_total'
  end

  private

  # A helpdesk mail as MailProcessor and the reply/init mailers record it:
  # always with its mailbox.
  def record_mail(issue, direction)
    @mailbox ||= ::HelpdeskMailbox.create!(:project => issue.project, :mailbox_address => 'metrics-test@expert.local',
                                           :provider => 'imap', :imap_host => 'mail.example.com')
    ::HelpdeskMessage.create!(:issue => issue, :helpdesk_mailbox => @mailbox, :direction => direction)
  end

  # Pretend db/migrate/001 has not run (minitest 6 ships no minitest/mock).
  def without_counter_table
    sc = ExpertMetricsCounter.singleton_class
    sc.alias_method(:__orig_available?, :available?)
    sc.define_method(:available?) { false }
    yield
  ensure
    sc.alias_method(:available?, :__orig_available?)
    sc.remove_method(:__orig_available?)
  end

  def core_mail(project_identifier)
    Mail.new do
      from 'redmine@example.net'
      to 'user@example.net'
      subject '[eCookbook - Bug #1] Something'
    end.tap do |m|
      m.header['X-Mailer'] = 'Redmine'
      m.header['X-Redmine-Project'] = project_identifier if project_identifier
    end
  end
end
