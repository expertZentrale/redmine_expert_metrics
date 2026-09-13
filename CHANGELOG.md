# Changelog – redmine_expert_metrics

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> EN is authoritative — release notes are generated from this file.

## [Unreleased]

### Added
- **Ready-to-import Grafana dashboard** (`contrib/grafana/redmine-expert-metrics.json`): activity,
  accounts, issues and mail volume of the installation, plus a scrape-health row. Import it and
  pick a Prometheus datasource — the panels are bound to a datasource variable, so nothing has to
  be edited afterwards. Two correctness details are baked into the queries: every panel reduces
  with `max` instead of `sum`, because each pod reports the same database-wide numbers; the job
  variable is single-select, because two jobs reduced with `max` would blend two installations into
  one number; and the scrape-health panels join `up` against a 24 h lookback on `redmine_info`, so
  that sidecars sharing the Redmine job label stay out while a target that stopped answering stays
  visible as 0 instead of going stale and disappearing. The mail panels stay empty without
  redmine_expert_helpdesk. Ships in the release archive.
- **`scripts/seed_screenshot_demo.rb` and its teardown** build a synthetic installation for the
  README screenshots: fourteen users with backdated session tokens spread across the 5/15/60
  minute windows, four projects, issues, notification counters and helpdesk mail volumes. It
  refuses to run against a database holding rows it did not create — the admin page and
  `/metrics` report installation-wide numbers, so seeding on top of real data would publish it.
- **Screenshots** in `docs/screenshots/{en,de}/`, the admin page and the Grafana dashboard, and a
  *Screenshots* section in both READMEs.
- **CI, issue templates and Copilot instructions** (`.github/`): the repository now carries the
  same GitHub setup as `redmine_expert_agile` and `redmine_expert_helpdesk` — `ci.yml` runs the
  MiniTest suite against Redmine 5.1/6.0/6.1/7.0-stable on a fresh MariaDB, `docker-image.yml`
  mounts the plugin into the official `redmine:5.1/6.0/6.1/7.0` images, migrates it via
  `REDMINE_PLUGINS_MIGRATE` and requires `/login` and `/metrics` to answer (asserting
  `redmine_active_users` and `redmine_info` are exposed), and `ISSUE_TEMPLATE/` provides the bug
  and feature forms. `.github/copilot-instructions.md` mirrors `CLAUDE.md`; both grew the
  conventions that were only implicit so far (Ruby 2.7 syntax, no user names in the exposition,
  migration numbering) plus the CI and release sections.

### Fixed
- **`release.yml` accepted malformed tags.** The semver check allowed the optional suffix to
  begin with `.`, so `v1.2.3.4` validated, and accepted empty identifiers such as `1.2.3-a..b`.

## [1.1.1] - 2026-09-09

### Added
- **Release workflow** (`.github/workflows/release.yml`): a pushed `vX.Y.Z` tag now builds the
  plugin archives (`.zip` + `.tar.gz`, unpacking straight into `redmine/plugins/`) and publishes
  a GitHub release with the notes of the matching `CHANGELOG.md` section — the same setup
  `redmine_expert_agile` and `redmine_expert_helpdesk` use. The workflow refuses to run when
  the `version` in `init.rb` and the tag disagree, so `init.rb` stays the single source of
  truth. `README.md` / `README.de.md` point at the releases page as an install alternative.

### Changed
- **Admin menu entry renamed to "expert Metrics"** (`init.rb`, `config/locales/{en,de}.yml`,
  `app/views/expert_metrics/active_users.html.erb`,
  `app/controllers/expert_metrics_controller.rb`): the entry was captioned "Active users",
  a bare functional name among Redmine's own administration areas that did not say which
  plugin owns it. It now carries the plugin name like `redmine_expert_helpdesk` and
  `redmine_expert_agile` do. The page heading follows the menu entry; the user list keeps
  "Active users" as its own heading. The menu item is registered as `:redmine_expert_metrics`
  (was `:expert_metrics_active_users`), `menu_item` in the controller follows. Routes and URLs
  are unchanged.

## [1.1.0] - 2026-09-08

### Added
- **`redmine_notifications_sent_total{project}`** (`lib/redmine_expert_metrics/mail_observer.rb`,
  `app/models/expert_metrics_counter.rb`): a `Mail` observer registered in `init.rb` counts
  every delivered message carrying core's `X-Mailer: Redmine` header, labelled with
  `X-Redmine-Project` (empty for account/security mails). One mail per recipient. Counts are
  stored in the new table `expert_metrics_counters` with an atomic `UPDATE value = value + n`,
  so all pods share them and they survive restarts. Errors in the observer are logged, never raised.
- **`redmine_helpdesk_mails_total{project,direction}`** (`lib/redmine_expert_metrics/collector.rb`):
  cumulative counts from redmine_expert_helpdesk's `helpdesk_messages` table grouped by project
  identifier and direction (`in` received, `out` sent to customers, `init`). Only emitted when
  that plugin is installed. Both new metrics are exposed as Prometheus counters
  (`lib/redmine_expert_metrics/exposition.rb`) and included in the JSON summary.
- Tests: `test/unit/mail_counter_test.rb`.
- Both mail sources are guarded: `redmine_helpdesk_mails_total` is only collected when the
  `HelpdeskMessage` model and its table exist, and `redmine_notifications_sent_total` stays
  empty (observer silent, no warnings) until `expert_metrics_counters` has been migrated, so
  `/metrics` keeps answering on a freshly installed plugin.

### Migration
- `001_create_expert_metrics_counters.rb` — table `expert_metrics_counters(name, label, value, updated_on)`,
  unique index on `(name, label)`.

## [1.0.0] - 2026-09-08

### Added
- **Administration → Active users** (`app/controllers/expert_metrics_controller.rb`,
  `app/views/expert_metrics/active_users.html.erb`): users with a session request in the last
  60 minutes, most recent first, with last activity, login time and session count; summary of
  active users (5/15/60 min), logged-in sessions and logins in the last 24 h. Auto-refreshes
  every minute. Same data as JSON at `/admin/active_users.json` for admin API keys.
- **`GET /metrics`** Prometheus text exposition (`lib/redmine_expert_metrics/exposition.rb`):
  `redmine_active_users{window}`, `redmine_sessions_total`, `redmine_recent_logins_users{window="24h"}`,
  `redmine_users_total{status}`, `redmine_projects_total{status}`, `redmine_issues_total{state}`,
  `redmine_metrics_collect_seconds`, `redmine_info{redmine_version,plugin_version}`.
  Aggregate numbers only. Open unless `metrics_token` is set in `configuration.yml`; then a
  bearer token or `?token=` is required. Admin session or admin API key always passes. Works
  with "Authentication required" enabled.
- **Collector** (`lib/redmine_expert_metrics/collector.rb`): activity derived from core's
  session tokens (`tokens.action = 'session'`, `updated_on` bumped by `User.verify_session_token`),
  session validity mirrors `session_lifetime` / `session_timeout`. Snapshot cached 15 s in
  `Rails.cache`. No settings, no permissions.
- Admin menu entry with a version-dependent icon (core SVG sprite on Redmine 6/7, CSS sprite on 5).
- MiniTest suite (`test/unit/collector_test.rb`, `test/functional/expert_metrics_controller_test.rb`).
