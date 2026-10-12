> 🇬🇧 English version · [Deutsche Version](README.de.md)

# Redmine expert Metrics

See who is working in Redmine **right now**, who uses the **REST API** (and with which script),
and expose that, plus a few basic totals, as Prometheus metrics. Built for the questions "can I
take an instance down for maintenance?" and "who is changing data through the API?".
Works on **Redmine 5.1, 6.0, 6.1 and 7.0**.


## Screenshots

All screenshots show a synthetic installation, built by
`scripts/seed_screenshot_demo.rb` against an empty database.

![Administration, expert Metrics: active users over 5, 15 and 60 minutes, live sessions and
logins in the last 24 hours, above a table of everyone with a request in the last hour with
login, name, last activity, logged in since and how many sessions they
hold](docs/screenshots/en/01-active-users.png)

### Grafana dashboard

`contrib/grafana/redmine-expert-metrics.json`, over a working week.

![The dashboard over a working week: active users across the three windows, logged-in sessions,
accounts by status, open and closed issues, and customer versus notification mail per
hour](docs/screenshots/en/04-grafana.png)


## What it does

- **Administration → expert Metrics**: every user with at least one request in the last 60
  minutes, most recent first, with last activity, login time and number of sessions. The page
  refreshes itself every minute. Summary on top: active users in the last 5 / 15 / 60 minutes,
  logged-in sessions, logins in the last 24 h.
- **`GET /admin/active_users.json`**: the same data for scripts, with an admin API key.
- **Administration → expert Metrics → API usage** (`/admin/api_usage`, also `.json`): every
  user whose API credentials were used in the last 1 / 7 / 30 / 90 days, with requests, writing
  requests, authentication method, clients (User-Agent), last IP, last path and when the key was
  created — plus the users holding an API key that was not used in the period. See
  [API usage](#api-usage).
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
| `redmine_api_requests_total` | `method` = `GET`, `POST`, …, `auth` = `key`, `basic`, `password`, `oauth` | requests authenticated by API credentials (counter) |
| `redmine_api_users` | `window` = `1d`, `7d`, `30d` | distinct users with API requests in the last n calendar days, today included |
| `redmine_api_keys_total` | – | users holding an API key |
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

## API usage

API keys are created by the users themselves and carry their full permissions; with
AI-generated scripts more and more people use them. Redmine core keeps no record of when a key
is used, so the plugin records every request that core authenticated by API credentials:

- **What counts**: `.json` / `.xml` requests with an `X-Redmine-API-Key` header or `?key=`
  (`key`), an API key as HTTP Basic user name (`basic`), login and password via HTTP Basic
  (`password` — highlighted in red, the script stores a password) or an OAuth token (`oauth`,
  Redmine 6.1+). Requests that are denied afterwards (403) count too; requests with an invalid
  key, anonymous requests and browser sessions do not. Nothing is recorded while the REST API
  is disabled.
- **What is stored**: one row per user, day, HTTP method, authentication method and User-Agent
  in the table `expert_metrics_api_usages`, with the request count, first and last time, the
  **last IP address** and the last path (without query string, which may carry the key). When an
  admin key switches user (`X-Redmine-Switch-User`), the request is booked on the key owner and
  the switched-to user is shown.
- **Retention**: rows older than **90 days** are deleted automatically — on API requests, on every
  `/metrics` collection and on the admin page, at most once an hour. Without a regular Prometheus
  scrape, run `bundle exec rake redmine_expert_metrics:purge_api_usage RAILS_ENV=production` from cron. The IP address and
  User-Agent are personal data — mention the log in your privacy documentation.
- **Cost**: one `UPDATE` per API request (plus one on the counter table); an `INSERT` only for
  the first request of a day per user, HTTP method, authentication method and client — so a
  script that reads and writes produces two rows a day, not one.

What a script *changed* is in the issue history as usual — this page tells you whose key and
which client was behind it.

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
| `/admin/api_usage` (HTML, `.json`) | administrators; the JSON also via admin API key |
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
```

Then run the plugin migrations (a counter table and the API usage table) **before** restarting
Redmine — a process that starts without the tables does not record API usage until its next
restart:

```bash
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_metrics RAILS_ENV=production
# restart Redmine
```

Alternatively, download the release archive from the
[Releases page](https://github.com/expertZentrale/redmine_expert_metrics/releases) and unpack
it into `plugins/`.

No settings, no permissions — the plugin is active as soon as it loads.

## Grafana dashboard

A ready-made dashboard lives in
[`contrib/grafana/redmine-expert-metrics.json`](contrib/grafana/redmine-expert-metrics.json).
Import it under *Dashboards → New → Import*, upload the file or paste its contents, and pick your
Prometheus datasource — nothing else needs configuring.

It shows active users per window, logged-in sessions, accounts by status, open issues, active
projects, helpdesk and notification mail volume, REST API users and requests per hour by method
and authentication, and a scrape-health row with collection time and
per-target status. One variable selects the installation: **Job**, the scrape job that serves these
metrics.

Three details are built into the queries rather than left to the reader:

- **Every panel aggregates with `max`, never `sum`.** Each pod reports the same database-wide
  numbers, so summing them multiplies every figure by the number of replicas.
- **Job is single-select.** Since the panels reduce with `max`, two jobs selected at once would
  silently blend two Redmine installations into one number.
- **The scrape-health panels follow the Redmine targets only, and keep a dead one visible.** `up`
  exists for every target in a Prometheus — including sidecars that share the Redmine job label —
  so that panel joins `up` against a 24 h lookback on `redmine_info`. Without the lookback a target
  that stopped answering would go stale and disappear from the panel instead of dropping to 0.

The mail panels stay empty unless
[redmine_expert_helpdesk](https://github.com/expertZentrale/redmine_expert_helpdesk) is installed;
everything else works with this plugin alone.

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
