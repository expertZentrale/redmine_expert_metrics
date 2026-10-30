# Times each hook listener during a request, so the metrics show which plugin
# spends how long on a page. Prepended to Redmine::Hook's singleton class.
#
# Core's call_hook is the loop below; it has looked the same from Redmine 2 to
# 7 (lib/redmine/hook.rb). Outside a timed request this calls core unchanged.
module RedmineExpertMetrics
  module HookTimingPatch
    def call_hook(hook, context = {})
      stats = Performance.current
      return super if stats.nil?

      [].tap do |response|
        hook_listeners(hook).each do |listener|
          started = Performance.monotonic
          stats.hook_depth += 1
          begin
            response << listener.send(hook, context)
          ensure
            stats.hook_depth -= 1
            stats.add_hook(hook, listener.class.name.to_s, (Performance.monotonic - started) * 1000.0,
                           stats.hook_depth.zero?)
          end
        end
      end
    end
  end
end
