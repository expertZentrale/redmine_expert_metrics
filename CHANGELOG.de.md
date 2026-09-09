# Changelog – redmine_expert_metrics

> 🇩🇪 Deutsche Version · [English version](CHANGELOG.md)
>
> Maßgeblich ist die englische Fassung; diese Datei ist der deutsche Spiegel.

## [Unreleased]

### Hinzugefügt
- **CI, Issue-Vorlagen und Copilot-Anweisungen** (`.github/`): das Repository hat jetzt dieselbe
  GitHub-Einrichtung wie `redmine_expert_agile` und `redmine_expert_helpdesk` — `ci.yml` führt die
  MiniTest-Suite gegen Redmine 5.1/6.0/6.1/7.0-stable auf einer frischen MariaDB aus,
  `docker-image.yml` hängt das Plugin in die offiziellen `redmine:5.1/6.0/6.1/7.0`-Images ein,
  migriert es über `REDMINE_PLUGINS_MIGRATE` und verlangt Antworten von `/login` und `/metrics`
  (mit Prüfung auf `redmine_active_users` und `redmine_info`), und `ISSUE_TEMPLATE/` liefert die
  Formulare für Fehler und Wünsche. `.github/copilot-instructions.md` spiegelt `CLAUDE.md`; beide
  haben die bisher nur implizierten Konventionen bekommen (Ruby-2.7-Syntax, keine Benutzernamen in
  der Exposition, Migrationsnummerierung) sowie die Abschnitte zu CI und Releases.

## [1.1.1] - 2026-09-09

### Hinzugefügt
- **Release-Workflow** (`.github/workflows/release.yml`): ein gepushter `vX.Y.Z`-Tag baut jetzt
  die Plugin-Archive (`.zip` + `.tar.gz`, entpacken direkt nach `redmine/plugins/`) und
  veröffentlicht ein GitHub-Release mit den Notizen aus dem passenden `CHANGELOG.md`-Abschnitt —
  dasselbe Vorgehen wie bei `redmine_expert_agile` und `redmine_expert_helpdesk`. Der Workflow
  bricht ab, wenn `version` in `init.rb` und der Tag nicht zusammenpassen; `init.rb` bleibt damit
  die einzige Quelle der Wahrheit. `README.md` / `README.de.md` nennen die Releases-Seite als
  Installationsalternative.

### Geändert
- **Admin-Menüeintrag heißt jetzt „expert Metrics“** (`init.rb`, `config/locales/{en,de}.yml`,
  `app/views/expert_metrics/active_users.html.erb`,
  `app/controllers/expert_metrics_controller.rb`): der Eintrag hieß „Aktive Benutzer“ – ein
  rein funktionaler Name zwischen Redmines eigenen Administrationsbereichen, der nicht
  verriet, zu welchem Plugin er gehört. Er trägt jetzt den Plugin-Namen wie
  `redmine_expert_helpdesk` und `redmine_expert_agile`. Die Seitenüberschrift folgt dem
  Menüeintrag; die Benutzerliste behält „Aktive Benutzer“ als eigene Überschrift. Der
  Menüeintrag ist als `:redmine_expert_metrics` registriert (vorher
  `:expert_metrics_active_users`), `menu_item` im Controller folgt. Routen und URLs bleiben
  unverändert.

## [1.1.0] - 2026-09-08

### Hinzugefügt
- **`redmine_notifications_sent_total{project}`** (`lib/redmine_expert_metrics/mail_observer.rb`,
  `app/models/expert_metrics_counter.rb`): ein in `init.rb` registrierter `Mail`-Observer zählt
  jede zugestellte Nachricht mit dem Kern-Header `X-Mailer: Redmine`, gelabelt mit
  `X-Redmine-Project` (leer bei Konto-/Sicherheitsmails). Eine Mail pro Empfänger. Die Zähler
  liegen in der neuen Tabelle `expert_metrics_counters` mit atomarem `UPDATE value = value + n`,
  gemeinsam für alle Pods und über Neustarts hinweg. Fehler im Observer werden geloggt, nie geworfen.
- **`redmine_helpdesk_mails_total{project,direction}`** (`lib/redmine_expert_metrics/collector.rb`):
  kumulative Zahlen aus der Tabelle `helpdesk_messages` von redmine_expert_helpdesk, gruppiert
  nach Projektkennung und Richtung (`in` empfangen, `out` an Kunden gesendet, `init`). Nur
  vorhanden, wenn dieses Plugin installiert ist. Beide neuen Metriken sind Prometheus-Counter
  (`lib/redmine_expert_metrics/exposition.rb`) und Teil der JSON-Zusammenfassung.
- Tests: `test/unit/mail_counter_test.rb`.
- Beide Mailquellen sind abgesichert: `redmine_helpdesk_mails_total` wird nur erhoben, wenn das
  Modell `HelpdeskMessage` und seine Tabelle existieren, und `redmine_notifications_sent_total`
  bleibt leer (Observer still, keine Warnungen), bis `expert_metrics_counters` migriert wurde,
  sodass `/metrics` auch bei einem frisch installierten Plugin antwortet.

### Migration
- `001_create_expert_metrics_counters.rb` — Tabelle `expert_metrics_counters(name, label, value, updated_on)`,
  eindeutiger Index auf `(name, label)`.

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
  Keine Einstellungen, keine Berechtigungen.
- Eintrag im Administrationsmenü mit versionsabhängigem Icon (Core-SVG-Sprite auf Redmine 6/7, CSS-Sprite auf 5).
- MiniTest-Suite (`test/unit/collector_test.rb`, `test/functional/expert_metrics_controller_test.rb`).
