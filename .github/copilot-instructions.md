# Copilot instructions – redmine_expert_metrics

This file mirrors [`CLAUDE.md`](../CLAUDE.md). The two are intentional duplicates for
different tools — **keep them in sync when either changes.**

## Overview

Small Redmine plugin: "who is active right now" as an admin page + JSON, aggregate
numbers and mail counters as Prometheus metrics on `/metrics`. One migration (counter
table), no settings, no permissions.

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
  `metrics_token` from `Redmine::Configuration`) and `active_users` (admin HTML/JSON).
- `lib/redmine_expert_metrics/mail_observer.rb` + `app/models/expert_metrics_counter.rb` –
  `Mail` observer counting core notifications (`X-Mailer: Redmine`, label `X-Redmine-Project`)
  into `expert_metrics_counters`; helpdesk customer mails are read from `helpdesk_messages`
  in the collector when that plugin is present.
- `init.rb` – plugin registration, admin menu entry (icon switch for Redmine 5 vs 6/7),
  observer registration.

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
