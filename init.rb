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

Redmine::Plugin.register :redmine_expert_metrics do
  name 'Redmine expert Metrics'
  author 'Dennis Buehring'
  description 'Shows who is currently working in Redmine and exposes that (plus a few basic totals) as Prometheus metrics. Works on Redmine 5.1 - 7.x.'
  version '1.1.1'
  url 'https://github.com/expertZentrale/redmine_expert_metrics'
  requires_redmine :version_or_higher => '5.0'

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
