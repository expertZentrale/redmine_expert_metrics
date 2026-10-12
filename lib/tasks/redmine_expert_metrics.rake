namespace :redmine_expert_metrics do
  # Retention also runs on API requests, /metrics collections and the admin page;
  # this is for installations where none of those happen regularly (cron).
  desc 'Delete API usage rows older than the retention period (90 days)'
  task :purge_api_usage => :environment do
    if ExpertMetricsApiUsage.available?
      deleted = ExpertMetricsApiUsage.purge!
      puts "Deleted #{deleted} API usage rows older than #{ExpertMetricsApiUsage::RETENTION_DAYS} days."
    else
      puts 'API usage table missing - run rake redmine:plugins:migrate first.'
    end
  end
end
