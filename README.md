> 🇬🇧 English version · [Deutsche Version](README.de.md)

# Redmine expert Metrics

See who is working in Redmine **right now** and expose that, plus a few basic totals, as
Prometheus metrics. Built for the question "can I take an instance down for maintenance?".
Works on **Redmine 5.1, 6.0, 6.1 and 7.0**.

## What it does

- **Administration → expert Metrics**: every user with at least one request in the last 60
  minutes, most recent first, with last activity, login time and number of sessions. The page
  refreshes itself every minute. Summary on top: active users in the last 5 / 15 / 60 minutes,
  logged-in sessions, logins in the last 24 h.
- **`GET /admin/active_users.json`**: the same data for scripts, with an admin API key.
- **`GET /metrics`**: Prometheus text exposition with aggregate numbers only (no names).

| Metric | Labels | Meaning |
|---|---|---|
| `redmine_active_users` | `window` = `5m`, `15m`, `60m` | distinct users with a session request in the window |
| `redmine_sessions_total` | – | session tokens Redmine would still accept (active or idle) |
| `redmine_recent_logins_users` | `window` = `24h` | distinct users whose last login is within the window |
| `redmine_users_total` | `status` = `active`, `registered`, `locked` | user accounts |
| `redmine_projects_total` | `status` = `active` | projects |
| `redmine_issues_total` | `state` = `open`, `closed` | issues by the closed flag of their status |
| `redmine_notifications_sent_total` | `project` | notification mails Redmine core delivered to its users, one per recipient (counter); empty project for account and security mails |
| `redmine_helpdesk_mails_total` | `project`, `direction` = `in`, `out`, `init` | mails recorded by [redmine_expert_helpdesk](https://github.com/expertZentrale/redmine_expert_helpdesk): `in` received from customers, `out` sent to customers (replies, autoresponder, follow-ups), `init` initial mail of a ticket opened in Redmine. Only present when that plugin is installed (counter) |
| `redmine_metrics_collect_seconds` | – | wall time of the last uncached collection |
| `redmine_info` | `redmine_version`, `plugin_version` | always 1 |

## How "active" is measured

Every browser session owns a row in Redmine's `tokens` table (`action = session`), and core
bumps its `updated_on` on every request, at most once per minute. The plugin only reads those
rows. This works with any session store (cookie, Redis, database), is global for the whole
installation and needs no migration. API-key requests and the mail fetcher never create a
session token, so they do not count as "active".

The snapshot behind `/metrics` and the admin page is cached for 15 seconds in `Rails.cache`,
so several pods scraped every few seconds still cost one set of queries.

## How mails are counted

- **Notifications to Redmine users**: a `Mail` observer counts every delivered message that
  carries core's `X-Mailer: Redmine` header, labelled with its `X-Redmine-Project`. Redmine
  sends one mail per recipient, so this is "mails delivered", not "events". The counts live in
  the plugin's own table `expert_metrics_counters` (one migration), shared by all pods and
  surviving restarts.
- **Customer mail of the helpdesk plugin**: read straight from its `helpdesk_messages` table,
  grouped by project and direction. Those mails do not carry the core header, so the two
  metrics never overlap.

Both are cumulative, so use `increase()` / `rate()` in Prometheus:

```promql
sum by (project) (increase(redmine_helpdesk_mails_total{direction="in"}[24h]))
sum by (project) (increase(redmine_notifications_sent_total[1h]))
```

## Multiple instances (Kubernetes)

Every pod reports the **same** database-wide numbers. Aggregate with `max`, never `sum`:

```promql
max by (window) (redmine_active_users)
```

## Access control

| Endpoint | Who |
|---|---|
| `/admin/active_users` (HTML) | Redmine administrators |
| `/admin/active_users.json` | administrators, also via `X-Redmine-API-Key` / `?key=` (REST API must be enabled) |
| `/metrics` | open by default; if `metrics_token` is set in `config/configuration.yml`, it must be sent as `Authorization: Bearer <token>` or `?token=<token>`. Administrators (session or API key) always pass. |

```yaml
# config/configuration.yml
production:
  metrics_token: "change-me"
```

`/metrics` works even when *Authentication required* is enabled in Redmine's settings.

## Installation

```bash
cd /path/to/redmine/plugins
git clone https://github.com/expertZentrale/redmine_expert_metrics.git
# restart Redmine
```

Then run the plugin migration (one small counter table):

```bash
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_metrics RAILS_ENV=production
```

No settings, no permissions — the plugin is active as soon as it loads.

## Usage before maintenance

```bash
curl -s -H "X-Redmine-API-Key: $KEY" https://redmine.example.com/admin/active_users.json | jq '.summary.active_users'
curl -s https://redmine.example.com/metrics | grep redmine_active_users
```

## Tests

MiniTest, requires a Redmine environment:

```bash
bundle exec rake redmine:plugins:test NAME=redmine_expert_metrics RAILS_ENV=test
```

## License

Copyright (C) 2026 Dennis Buehring

**GNU General Public License, version 2 or (at your option) any later version** — the same license
Redmine itself uses. See [`LICENSE`](LICENSE) for the full text. Distributed WITHOUT ANY WARRANTY.

No third-party components are bundled.
