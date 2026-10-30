# Redmine expert Metrics Plugin
#
# Copyright (C) 2026 Dennis Buehring
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version. See LICENSE for the full text.

require 'redmine'

require File.expand_path('../lib/redmine_expert_metrics/collector', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/exposition', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/mail_observer', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/api_usage_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/purgeable', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/registry', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/performance', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/request_timing_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_metrics/hook_timing_patch', __FILE__)

Redmine::Plugin.register :redmine_expert_metrics do
  name 'Redmine expert Metrics'
  author 'Dennis Buehring'
  description 'Shows who is currently working in Redmine, who uses the REST API with which client and which requests are slow, and exposes that (plus a few basic totals and per-process request, hook, job and memory metrics) as Prometheus metrics. Works on Redmine 5.1 - 7.x.'
  version '1.4.1'
  url 'https://github.com/expertZentrale/redmine_expert_metrics'
  requires_redmine :version_or_higher => '5.0'

  # API usage recording and the performance metrics are opt-in: while off,
  # requests cost nothing extra and /metrics runs no extra queries. A key missing
  # from the stored hash (installs older than 1.3.0 / 1.4.0) reads as off, like
  # the default; a missing threshold reads as Performance::DEFAULT_THRESHOLD_MS.
  settings :default => { 'api_usage_enabled' => '0',
                         'performance_metrics_enabled' => '0',
                         'slow_request_threshold_ms' => RedmineExpertMetrics::Performance::DEFAULT_THRESHOLD_MS.to_s },
           :partial => 'settings/expert_metrics_settings'

  # Entry in the administration menu (sidebar + admin overview). It carries the
  # plugin name like the other expert plugins do; a bare functional caption
  # ("Active users") stood among Redmine's own areas without saying which
  # plugin owns it. The icon is version dependent, see redmine_expert_helpdesk
  # for the same switch:
  # - Redmine 6/7: core SVG sprite icon via :icon (render_single_menu_node calls
  #   sprite_icon). "user" ships with core, so no sprite of our own is needed.
  # - Redmine 5: the old CSS sprite via the "icon icon-*" class on the link.
  menu_options = { :caption => :label_expert_metrics }
  if Redmine::VERSION::MAJOR >= 6
    menu_options[:icon] = 'user'
    # The "icon" class makes the SVG inherit the blue currentColor stroke of the
    # other admin menu icons; without it the sprite stays in the default grey.
    menu_options[:html] = { :class => 'icon' }
  else
    menu_options[:html] = { :class => 'icon icon-user' }
  end
  menu :admin_menu, :redmine_expert_metrics,
       { :controller => 'expert_metrics', :action => 'active_users' },
       menu_options
end

# Count delivered notification mails. Mail.register_observer ignores a module
# that is already registered, so re-running init.rb (dev reload) is harmless.
ActionMailer::Base.register_observer(RedmineExpertMetrics::MailObserver)

# Record API-key usage. Redmine runs init.rb inside a to_prepare callback (and
# again on every dev reload), so patch directly and guard against prepending twice.
unless ApplicationController.ancestors.include?(RedmineExpertMetrics::ApiUsagePatch)
  ApplicationController.prepend(RedmineExpertMetrics::ApiUsagePatch)
end

# Performance metrics (opt-in, see Performance). Same reasoning as above: patch
# directly, guarded. The SQL and request subscribers are attached by the first
# request that finds the setting on (Performance.sync_subscriptions); the job
# subscriber is attached here, so job-only processes record jobs as well.
RedmineExpertMetrics::Performance.install_job_subscriber!
unless ApplicationController.ancestors.include?(RedmineExpertMetrics::RequestTimingPatch)
  ApplicationController.prepend(RedmineExpertMetrics::RequestTimingPatch)
end
unless Redmine::Hook.singleton_class.ancestors.include?(RedmineExpertMetrics::HookTimingPatch)
  Redmine::Hook.singleton_class.prepend(RedmineExpertMetrics::HookTimingPatch)
end
