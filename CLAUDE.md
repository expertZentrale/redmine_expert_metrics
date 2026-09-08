# CLAUDE.md – redmine_expert_metrics

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
- "expert" (the company) is always lowercase in user-facing text.
- Hash rockets, no frozen-string magic comments, `requires_redmine '5.0'` — keep it running
  on Redmine 5.1 (production) and 7.x (dev image).

## Tests

```bash
# from the parent repo root
docker-compose -f docker-compose.yml --profile test run --build --rm -e PLUGIN=redmine_expert_metrics redmine-test
```

Tests clear `Collector::CACHE_KEY` and delete all session tokens in `setup`; create test
tokens with `Token.create!(:user_id, :action => 'session')` + `update_columns(:updated_on)`.
