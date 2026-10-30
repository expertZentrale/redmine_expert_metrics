# Prometheus text exposition. No format suffix: Prometheus scrapes the bare path
# and the response is always text/plain.
get 'metrics', :to => 'expert_metrics#prometheus', :as => 'expert_metrics_prometheus',
    :format => false

# Admin page (HTML) and the same data as JSON (admin session or admin API key).
get 'admin/active_users', :to => 'expert_metrics#active_users',
    :as => 'expert_metrics_active_users'

# Who uses the REST API (HTML, JSON for admins).
get 'admin/api_usage', :to => 'expert_metrics#api_usage', :as => 'expert_metrics_api_usage'

# Requests over the slow-request threshold (HTML, JSON for admins).
get 'admin/slow_requests', :to => 'expert_metrics#slow_requests',
    :as => 'expert_metrics_slow_requests'
