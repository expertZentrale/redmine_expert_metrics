# Copilot instructions – redmine_expert_metrics

This file mirrors [`CLAUDE.md`](../CLAUDE.md). The two are intentional duplicates for
different tools — **keep them in sync when either changes.**

## Overview

Small Redmine plugin: "who is active right now", "who uses the REST API" and "which requests
are slow" as admin pages + JSON, aggregate numbers, mail/API counters and per-process
performance series as Prometheus metrics on `/metrics`. Three migrations (counter table, API
usage table, slow-request table), no permissions, three settings: `api_usage_enabled` (off by
default) — while off, `ApiUsagePatch` returns before any query and `Collector.collect` leaves
`api_*` nil, so `/metrics` omits those series; `performance_metrics_enabled` (off by default) and
`slow_request_threshold_ms` (default 2000, nil on old installs → `Performance.threshold_ms`
falls back).

This directory lives inside the parent `redmine-expert` deployment repo (`../../`). It is
**not** a Redmine checkout — Redmine only exists inside the Docker image. Run everything
from the parent repo root and read its `README.md` first (hard rule: never `docker exec`;
rebuild with `docker-compose -f docker-compose.yml up --build`).

## Layout

- `lib/redmine_expert_metrics/collector.rb` – all queries; returns a string-keyed hash,
  cached 15 s under `Collector::CACHE_KEY`. Activity comes from core's session tokens
  (`tokens.action = 'session'`, `updated_on` bumped by `User.verify_session_token`).
- `lib/redmine_expert_metrics/exposition.rb` – Prometheus text rendering. Aggregates only,
  never user names.
- `app/controllers/expert_metrics_controller.rb` – `prometheus` (`GET /metrics`, optional
  `metrics_token` from `Redmine::Configuration`), `active_users` and `api_usage` (admin
  HTML/JSON).
- `lib/redmine_expert_metrics/api_usage_patch.rb` + `app/models/expert_metrics_api_usage.rb` –
  prepended to `ApplicationController`, wraps core's `find_current_user` and records every
  request authenticated by API credentials (key / Basic key / Basic password / OAuth) as daily
  rows per user, verb, auth and User-Agent (`expert_metrics_api_usages`, atomic UPDATE then
  INSERT like the counter), plus `ExpertMetricsCounter` `api_requests` (`"VERB:auth"`) for
  Prometheus. Switch-user is booked on the key owner; the path is stored without query string;
  rows are purged after `RETENTION_DAYS` (90) from the request path, `Collector.collect` and the
  admin page (`purge_if_due`, hourly, never raises), plus `rake redmine_expert_metrics:purge_api_usage`.
  Any error is logged and swallowed.
- `lib/redmine_expert_metrics/mail_observer.rb` + `app/models/expert_metrics_counter.rb` –
  `Mail` observer counting core notifications (`X-Mailer: Redmine`, label `X-Redmine-Project`)
  into `expert_metrics_counters`; helpdesk customer mails are read from `helpdesk_messages`
  in the collector when that plugin is present.
- `lib/redmine_expert_metrics/performance.rb` + `registry.rb` + `request_timing_patch.rb` +
  `hook_timing_patch.rb` – performance metrics. `RequestTimingPatch` (prepended to
  `ApplicationController#process_action`, skips `/metrics` itself) opens a `Performance::Stats` in
  a thread-local per request; the `sql.active_record` / `process_action.action_controller`
  subscribers (attached only while the setting is on: `Performance.sync_subscriptions`, called by
  every request with the setting it read; the `perform.active_job` one stays attached from init.rb,
  `install_job_subscriber!`, so job-only processes record jobs too) and `HookTimingPatch` (prepended to
  `Redmine::Hook.singleton_class`, re-implements core's 5-line `call_hook` loop to time each
  listener) add to it, and `RequestTimingPatch#cleanup_view_runtime` adds the render time minus the
  SQL counted during it (never take Rails' `view_runtime`: it keeps SQL in unless the logger is at
  `info`, and production logs at `warn`); `finish_request` books it into `Performance::REGISTRY` under one lock,
  sets `Server-Timing` for admins and writes an `ExpertMetricsSlowRequest` over the threshold
  (≤ 30/min/process, SQL fingerprinted — literals → `?`; `"…"` is a string only on MySQL/MariaDB,
  `Performance.double_quoted_strings?`). Jobs via `perform.active_job`.
  **These series are per process**: `ExpertMetricsController#prometheus` appends
  `Exposition.render_performance` *after* the cached snapshot (never put them into
  `Collector.snapshot` — it is shared via Redis across pods) and dashboards aggregate them with
  `sum`, not `max`. Never use `job` as a metric label (Prometheus' target label) — it is
  `job_class`.
- `lib/redmine_expert_metrics/purgeable.rb` – hourly `purge_if_due` claim (Redis SET NX), extended
  by `ExpertMetricsApiUsage` (90 days) and `ExpertMetricsSlowRequest` (14 days).
- `init.rb` – plugin registration, admin menu entry (icon switch for Redmine 5 vs 6/7),
  observer registration, `ApiUsagePatch` / `RequestTimingPatch` / `HookTimingPatch` prepends
  (guarded against dev reload).

## Conventions

- Code comments English; UI German via `config/locales/{en,de}.yml` (both files).
- Docs bilingual: `README.md` / `CHANGELOG.md` are authoritative, `README.de.md` /
  `CHANGELOG.de.md` are the German mirror — update both for every user-facing change.
- "expert" (the company) is always lowercase in user-facing text — the admin menu entry,
  labels, README, CHANGELOG. Never "Expert", not even at the start of a label. Code
  identifiers keep normal casing (`ExpertMetricsCounter`, `expert_metrics_counters`).
- Hash rockets, no frozen-string magic comments, `requires_redmine '5.0'` — keep it running
  on Redmine 5.1 (production) and 7.x (dev image).
- Plain `def ... end` — Redmine 5.1 runs on Ruby 2.7, where endless methods are a syntax
  error.
- The exposition never carries user names: the admin page may show who is active, `/metrics`
  only aggregates.
- Add the next migration number; never edit a shipped migration.

## Commands

```bash
# Stack (from the parent repo root)
docker-compose -f docker-compose.yml up --build

# Tests (from the parent repo root; -e is required, a plain PLUGIN=... prefix
# would set the variable in the compose process, not in the container)
docker-compose -f docker-compose.yml --profile test run --build --rm -e PLUGIN=redmine_expert_metrics redmine-test
```

Tests clear `Collector::CACHE_KEY` and delete all session tokens in `setup`; create test
tokens with `Token.create!(:user_id, :action => 'session')` + `update_columns(:updated_on)`.
API capture is tested end to end in `test/integration/api_usage_test.rb`
(`Redmine::ApiTest::Base`, real requests through core's `find_current_user`), request timing in
`test/integration/performance_test.rb` (`Redmine::IntegrationTest`; call `reset!` before logging
in a second user, and reset `Performance::REGISTRY` / `reset_slow_limit!` in `setup`).

## CI

- `.github/workflows/ci.yml` – plugin tests against Redmine 5.1/6.0/6.1/7.0-stable on a
  fresh MariaDB.
- `.github/workflows/docker-image.yml` – smoke test against the official `redmine:*` Docker
  images: the plugin is mounted in, migrated via `REDMINE_PLUGINS_MIGRATE`, and `/login` plus
  `/metrics` have to answer.
- `.github/workflows/release.yml` – runs on `vX.Y.Z` tags only, see below.

## Git and releases

Branch as `type/short-desc` (Conventional-Commit types), PR into `main`, CI must pass.
Releases are tag driven: bump `version` in `init.rb` (single source of truth), add the
`## [<version>]` section to `CHANGELOG.md` (and its German mirror), commit, then
`git tag vX.Y.Z && git push origin vX.Y.Z`. `release.yml` verifies that the tag matches the
`init.rb` version, builds the notes from the matching CHANGELOG section and attaches the
`.zip` / `.tar.gz` archives to the GitHub release.
A final step asks the plugin website (`expertZentrale/redmine-plugins`) to rebuild via a
`plugin-released` dispatch, using the `SITE_DISPATCH_TOKEN` secret (fine-grained token, Contents
read/write on that repo only); without it the site catches up on its weekly cron, and the step
never fails a release.

**Every release must also update `docs/redmine_org/`** — the copy-paste sources for the listing
at <https://www.redmine.org/plugins/redmine_expert_metrics>. That directory renders **Textile**,
not Markdown (`h3.` headings, `*bold*`, `@code@`, `"label":url`), so these files are written in
Textile and are pasted in unedited. Description and installation notes are **separate fields**
there — keep them split. Part of the release commit, not an afterthought:

- `docs/redmine_org/releases/<version>.textile` — new file per release. User-facing changes only;
  the CHANGELOG is the source but this is not a copy of it. House shape:
  `h3. redmine_expert_metrics <version> — <YYYY-MM-DD>`, then `h4. Added`/`Changed`/`Fixed`, always
  closing with `h4. Upgrade notes` (say "No migrations. Replace the plugin directory and restart."
  when that is all it takes).
- `docs/redmine_org/description.textile` — what the plugin *is*; update when a release adds a
  feature, a metric or a page, and bump the Redmine versions under *Requirements* when they move.
  **This one drifts silently**: read it end to end against the CHANGELOG since the last tag.
- `docs/redmine_org/installation.textile` — update when a step changes (new migration, new
  `configuration.yml` key, new endpoint, new gem).

`docs/redmine_org/README.md` is the full checklist. `docs/` is excluded from the release archives.
