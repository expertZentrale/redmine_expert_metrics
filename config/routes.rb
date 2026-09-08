# Prometheus text exposition. No format suffix: Prometheus scrapes the bare path
# and the response is always text/plain.
get 'metrics', :to => 'expert_metrics#prometheus', :as => 'expert_metrics_prometheus',
    :format => false

# Admin page (HTML) and the same data as JSON (admin session or admin API key).
get 'admin/active_users', :to => 'expert_metrics#active_users',
    :as => 'expert_metrics_active_users'
