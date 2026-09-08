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
    ::HelpdeskMessage.delete_all
    issue = Issue.find(1) # project ecookbook
    ::HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    ::HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    ::HelpdeskMessage.create!(:issue => issue, :direction => 'out')

    data = RedmineExpertMetrics::Collector.collect
    assert_equal({ 'ecookbook' => { 'in' => 2, 'out' => 1 } }, data['helpdesk_mails'])

    text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
    assert_includes text, "# TYPE redmine_helpdesk_mails_total counter\n"
    assert_includes text, "redmine_helpdesk_mails_total{project=\"ecookbook\",direction=\"in\"} 2\n"
    assert_includes text, "redmine_helpdesk_mails_total{project=\"ecookbook\",direction=\"out\"} 1\n"
  end

  def test_exposition_omits_helpdesk_metric_without_plugin
    data = RedmineExpertMetrics::Collector.collect.merge('helpdesk_mails' => nil)
    text = RedmineExpertMetrics::Exposition.render(data, '1.1.0')
    assert_not_includes text, 'redmine_helpdesk_mails_total'
  end

  private

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
