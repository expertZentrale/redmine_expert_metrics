# Times every controller request for the performance metrics (see
# Performance). Prepended to ApplicationController and wrapping process_action,
# so it encloses callbacks, the action, rendering and rescue_from handlers - the
# whole time Redmine spends on a request, minus Rack middleware.
module RedmineExpertMetrics
  module RequestTimingPatch
    def process_action(*args)
      return super unless expert_metrics_time_request?

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

    # The scrape itself is left out: it would only measure how often
    # Prometheus calls.
    def expert_metrics_time_request?
      return false if is_a?(ExpertMetricsController) && action_name == 'prometheus'
      Performance.enabled?
    end
  end
end
