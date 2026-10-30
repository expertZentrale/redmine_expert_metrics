# Times every controller request for the performance metrics (see
# Performance). Prepended to ApplicationController and wrapping process_action,
# so it encloses callbacks, the action, rendering and rescue_from handlers - the
# whole time Redmine spends on a request, minus Rack middleware.
module RedmineExpertMetrics
  module RequestTimingPatch
    def process_action(*args)
      enabled = Performance.enabled?
      Performance.sync_subscriptions(enabled)
      return super unless enabled && !expert_metrics_scrape?

      stats = Performance.start_request
      error = nil
      begin
        super
      rescue Exception => e
        # Only noted for the status; the exception goes on unchanged.
        error = e
        raise
      ensure
        Performance.finish_request(self, stats, error)
      end
    end

    private

    # Rails' own view_runtime leaves out the SQL run while rendering only when
    # the logger is at info or below (ActiveRecord::Railties::ControllerRuntime);
    # at warn, as in production, it holds every statement a template or hook
    # ran. So the view time is measured here, around Rails' implementation:
    # the render minus the SQL Stats counted during it, whatever the log level.
    # Rails' return value (its log line) is passed on unchanged.
    def cleanup_view_runtime
      stats = Performance.current
      return super if stats.nil?

      sql_before = stats.sql_ms
      started = Performance.monotonic
      begin
        super
      ensure
        stats.add_view((Performance.monotonic - started) * 1000.0 - (stats.sql_ms - sql_before))
      end
    end

    # The scrape itself is left out: it would only measure how often
    # Prometheus calls.
    def expert_metrics_scrape?
      is_a?(ExpertMetricsController) && action_name == 'prometheus'
    end
  end
end
