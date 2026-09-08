# Changelog – redmine_expert_metrics

> 🇩🇪 Deutsche Version · [English version](CHANGELOG.md)
>
> Maßgeblich ist die englische Fassung; diese Datei ist der deutsche Spiegel.

## [1.0.0] - 2026-09-08

### Hinzugefügt
- **Administration → Aktive Benutzer** (`app/controllers/expert_metrics_controller.rb`,
  `app/views/expert_metrics/active_users.html.erb`): Benutzer mit einer Sitzungs-Anfrage in den
  letzten 60 Minuten, neueste zuerst, mit letzter Aktivität, Anmeldezeitpunkt und Anzahl der
  Sitzungen; Zusammenfassung aktiver Benutzer (5/15/60 Min.), angemeldeter Sitzungen und
  Anmeldungen der letzten 24 h. Aktualisiert sich jede Minute. Dieselben Daten als JSON unter
  `/admin/active_users.json` für Admin-API-Keys.
- **`GET /metrics`** im Prometheus-Textformat (`lib/redmine_expert_metrics/exposition.rb`):
  `redmine_active_users{window}`, `redmine_sessions_total`, `redmine_recent_logins_users{window="24h"}`,
  `redmine_users_total{status}`, `redmine_projects_total{status}`, `redmine_issues_total{state}`,
  `redmine_metrics_collect_seconds`, `redmine_info{redmine_version,plugin_version}`.
  Nur Summen. Offen, solange kein `metrics_token` in der `configuration.yml` gesetzt ist; sonst
  ist ein Bearer-Token oder `?token=` nötig. Admin-Sitzung oder Admin-API-Key kommen immer durch.
  Funktioniert auch bei aktivierter „Authentifizierung erforderlich“.
- **Collector** (`lib/redmine_expert_metrics/collector.rb`): Aktivität aus den Sitzungs-Token des
  Kerns (`tokens.action = 'session'`, `updated_on` wird von `User.verify_session_token` gesetzt),
  Sitzungsgültigkeit wie `session_lifetime` / `session_timeout`. Datenstand 15 s im `Rails.cache`.
  Keine Migration, keine Einstellungen, keine Berechtigungen.
- Eintrag im Administrationsmenü mit versionsabhängigem Icon (Core-SVG-Sprite auf Redmine 6/7, CSS-Sprite auf 5).
- MiniTest-Suite (`test/unit/collector_test.rb`, `test/functional/expert_metrics_controller_test.rb`).
