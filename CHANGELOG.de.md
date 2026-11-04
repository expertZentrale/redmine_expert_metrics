# Changelog – redmine_expert_metrics

> 🇩🇪 Deutsche Version · [English version](CHANGELOG.md)
>
> Maßgeblich ist die englische Fassung; diese Datei ist der deutsche Spiegel.

## [Unreleased]

### Geändert

- **Die Tests laufen auch auf MySQL und PostgreSQL.** Die CI führt die Suite für jede unterstützte
  Redmine-Version auf MariaDB aus und für die älteste und die neueste (5.1 und 7.0) zusätzlich auf
  MySQL 8.4 und PostgreSQL 17.

## [1.6.1] - 2026-11-02

### Behoben

- **`redmine_helpdesk_mails_total` sprang um den Mailbestand eines ganzen Projekts, wenn ein Ticket
  verschoben oder gelöscht wurde.** Der Collector zählte `helpdesk_messages` nach dem *aktuellen*
  Projekt jedes Tickets. Ein Ticket aus einem Projekt zu verschieben (oder zu löschen, was seine
  Nachrichten mitlöscht) senkte also den Wert dieses Projekts, und Prometheus wertet jeden
  Rückgang eines Counters als Neustart: `increase()` und `rate()` rechnen dann den ganzen vorigen
  Wert dazu. In Produktion zeigte ein Projekt über drei Tage 1.353 empfangene Mails statt etwa 4.
  Das Plugin zählt jetzt jede Mail in dem Moment, in dem redmine_expert_helpdesk sie anlegt, in
  `expert_metrics_counters` unter dem Projekt, in dem das Ticket in diesem Moment liegt
  (`HelpdeskMessagePatch`, ein `after_commit` auf `HelpdeskMessage`), so wie
  `redmine_notifications_sent_total` schon bisher. Metrikname, Labels und Typ bleiben gleich, die
  Dashboards funktionieren weiter. Mails, die `LegacyContactsImport` aus redmine_contacts_helpdesk
  übernimmt (eingehend, ohne Postfach), werden nicht gezählt.
- README: Die PromQL-Beispiele für die beiden Mailzähler summierten über die Pods
  (`sum by (project)`) und vervielfachten diese datenbankweiten Werte damit mit der Zahl der Pods.
  Sie verwenden jetzt `max by (project)`, wie das Dashboard.
- `scripts/seed_screenshot_demo.rb` setzt den Helpdesk-Mailzähler direkt, statt `HelpdeskMessage`-
  Zeilen anzulegen (die der neue Patch noch einmal zählen würde, eingehende ohne Postfach gar nicht),
  und das Teardown stellt diesen Zähler wie den Benachrichtigungszähler wieder her.

## [1.6.0] - 2026-11-02

### Hinzugefügt

- **Spanisch, Französisch, Italienisch und Portugiesisch.** Die Oberfläche gibt es in sieben
  Sprachen: `es`, `fr`, `it`, `pt` (Portugal) und `pt-BR` (Brasilien) neben Englisch und Deutsch.
  Redmine zeigt jedem Benutzer die Sprache seines Kontos (oder die Standardsprache, wenn sie für
  angemeldete Benutzer erzwungen ist) und fällt für jede andere auf Englisch zurück.
- **Die Sprachdateien werden getestet.** `test/unit/locale_files_test.rb` schlägt fehl, wenn einer
  Sprache ein Schlüssel aus `en.yml` fehlt, sie einen hat, den `en.yml` nicht hat, die Reihenfolge
  abweicht oder ein `%{…}`-Platzhalter verloren geht.

## [1.5.0] - 2026-11-02

### Hinzugefügt

- **`redmine_db_roundtrip_seconds`**: jeder Scrape misst ein `SELECT 1` über die
  Datenbankverbindung des Prozesses, am Query-Cache vorbei (`Performance.db_roundtrip_seconds`). In
  Produktion kamen die meisten langsamen Seiten aus Minuten, in denen *jede* Anweisung eines Pods
  0,1–2 s brauchte, selbst ein Zugriff über die ID, während der andere Pod in wenigen Millisekunden
  antwortete und seine CPU frei war — ein Problem der Datenbankverbindung, keine langsame Abfrage,
  und in den Anfrage-Serien nicht zu sehen. Die Metrik zeigt es je Pod. Nur bei eingeschaltetem
  *Performance-Metriken erfassen*; fehlt, wenn die Anweisung scheitert.
- Grafana-Dashboard: *Database round trip per pod* und *Time per SQL statement per pod* in der
  Performance-Zeile, dazu ein Hinweis zum Lesen. README: die Metrik, eine Abfrage für die Zeit pro
  Anweisung je Pod und ein Alarmvorschlag.

## [1.4.1] - 2026-10-30

### Behoben

- **Ansichtszeit enthält bei Log-Level `warn` kein SQL mehr.** Die Ansichtszeit kam aus Rails'
  `view_runtime`, das die beim Rendern gelaufenen SQL-Anweisungen nur abzieht, wenn der Logger auf
  `info` oder niedriger steht (`ActiveRecord::Railties::ControllerRuntime#cleanup_view_runtime`).
  Produktivinstallationen loggen auf `warn`, also zählte jede Anweisung aus einem Template oder
  Hook-Listener als Datenbank- *und* als Ansichtszeit — auf der Seite Langsame Anfragen, in
  `redmine_http_request_view_seconds_total`, in der Warn-Zeile und im `Server-Timing`-Header (eine
  Ticketseite mit 2537 ms SQL zeigte 2722 ms Ansichten von 2797 ms gesamt). `RequestTimingPatch`
  misst das Rendern jetzt selbst und zieht das dabei gezählte SQL ab, unabhängig vom Log-Level.
  Datenbank-, Hook- und Gesamtzeit waren immer richtig.
- Die Dauer von SQL-Anweisungen und Hintergrundjobs kommt aus der monotonen Uhr
  (`ActiveSupport::Notifications.monotonic_subscribe`) statt aus `Time.now`; ein Stellen der
  Systemuhr während einer Anfrage verfälscht sie nicht mehr, und unter der eingefrorenen Uhr der
  Redmine-Testsuite (ab 6.1) bleiben sie messbar statt 0.

### Geändert

- Seite Langsame Anfragen: Die Benutzerspalte heißt *Benutzer* statt der Login-Bezeichnung aus
  dem Core (*Mitgliedsname*).

## [1.4.0] - 2026-10-30

### Hinzugefügt

- **Performance-Metriken**, **optional** über die neue Plugin-Einstellung *Performance-Metriken
  erfassen* (standardmäßig aus; solange aus, hängt kein SQL- oder Anfrage-Abonnent, eine Anfrage kostet
  einen Einstellungs-Lesezugriff, ein Hook-Aufruf eine Thread-lokale Prüfung und ein Hintergrundjob
  einen Einstellungs-Lesezugriff, und `/metrics` lässt
  die Reihen weg; Umschalten wirkt in jedem Prozess mit dessen nächster Anfrage). Jede Controller-Anfrage wird gemessen (`RequestTimingPatch` auf
  `ApplicationController#process_action`), zusammen mit der Zeit in SQL (`sql.active_record`), in
  den Ansichten (`process_action.action_controller`) und in jedem Plugin-Hook-Listener
  (`HookTimingPatch` auf `Redmine::Hook.call_hook`); Hintergrundjobs werden über
  `perform.active_job` gemessen. Die Abfrage durch Prometheus selbst wird nicht gemessen. Neue Reihen
  je Prozess in `/metrics`: `redmine_http_request_duration_seconds` (Histogramm),
  `redmine_http_request_{db,view,hook}_seconds_total`, `redmine_http_request_sql_queries_total` und
  `redmine_http_server_errors_total` je Controller, Aktion und Format; `redmine_hook_seconds_total` /
  `redmine_hook_calls_total` je Hook und Listener; `redmine_job_duration_seconds` (Histogramm) und
  `redmine_job_failures_total` je Job-Klasse (Label `job_class`, weil `job` das Ziel-Label von Prometheus selbst ist); sowie Prozesswerte für RSS, Startzeit, GC-Läufe und -Zeit,
  Heap-Slots, Allokationen, Threads und den Puma-Threadpool. Sie liegen im Speicher jedes Prozesses
  (threadsichere Registry, Anzahl der Label-Kombinationen begrenzt), werden hinter den gecachten
  Datenbank-Stand angehängt, sodass kein Pod die Zahlen eines anderen meldet, und über Pods hinweg
  mit `sum` zusammengefasst — anders als alle übrigen Reihen des Plugins.
- **Seite Langsame Anfragen** (*Administration → expert Metrics → Langsame Anfragen*,
  `/admin/slow_requests`, für Administratoren auch als `.json`): Anfragen über der neuen Einstellung
  *Schwelle für langsame Anfragen* (Standard 2000 ms) mit Gesamt-, Datenbank- (samt Anzahl der
  Anweisungen), Ansichts-, Hook- und GC-Zeit, den fünf langsamsten SQL-Anweisungen mit `?` statt
  ihrer Werte (Zeichenketten in einfachen und, unter MySQL/MariaDB, doppelten Anführungszeichen,
  Dollar-Strings von PostgreSQL, Zahlen), den langsamsten Hook-Listenern, Benutzer, Pfad (ohne Query-String) und Pod, dazu eine
  Zusammenfassung je Controller und Aktion über 1 / 7 / 14 Tage. Gespeichert in der neuen Tabelle
  `expert_metrics_slow_requests` (Migration 003), höchstens 30 Zeilen pro Prozess und Minute,
  gelöscht nach 14 Tagen; jede wird zusätzlich als eine `warn`-Zeile mit ihrer Request-ID geloggt.
- **`Server-Timing`-Header** für Administratoren, solange die Performance-Metriken an sind (`app`,
  `db` mit Anzahl der Anweisungen, `view`, `hooks`, `gc`), lesbar in den Entwicklerwerkzeugen des
  Browsers.
- **Grafana-Dashboard**: neue Zeile *Performance* mit p50/p95/p99 von Ticketseite, Ticketliste und
  Ticket-Speichern, den zehn langsamsten Aktionen, dem Anteil von Datenbank, Ansichten und Hooks,
  SQL-Anweisungen pro Anfrage, Hook-Zeit je Listener, Hintergrundjobs sowie RSS, GC-Zeit und
  Puma-Warteschlange je Pod.

### Geändert

- Die stündliche Aufbewahrungs-Prüfung der API-Nutzungstabelle liegt jetzt in einem gemeinsamen
  Modul (`RedmineExpertMetrics::Purgeable`), das auch die Tabelle der langsamen Anfragen nutzt. Das
  Verhalten ist unverändert.

## [1.3.0] - 2026-10-12

### Hinzugefügt

- **Seite API-Nutzung** (*Administration → expert Metrics → API-Nutzung*, `/admin/api_usage`,
  für Administratoren auch als `.json`), **optional** über die neue Plugin-Einstellung
  *API-Nutzung erfassen* (standardmäßig aus; solange aus, kosten API-Anfragen nichts zusätzlich
  und `/metrics` führt keine API-Abfragen aus): wessen API-Zugangsdaten in den letzten 1 / 7 / 30 / 90
  Tagen verwendet wurden, mit Anfragen, schreibenden Anfragen (POST, PUT, PATCH, DELETE),
  Anmeldeart (API-Schlüssel, API-Schlüssel per HTTP Basic, Passwort per HTTP Basic —
  hervorgehoben, OAuth), Clients nach User-Agent, letzter IP-Adresse, letztem Pfad und
  Erstellungsdatum des Schlüssels; dazu die Benutzer mit einem API-Schlüssel, der im Zeitraum
  nicht verwendet wurde. Der Redmine-Kern protokolliert die Nutzung von API-Schlüsseln nicht,
  daher erfasst das Plugin jetzt jede Anfrage, die der Kern über API-Zugangsdaten angemeldet hat
  (Patch auf `ApplicationController#find_current_user`), eine Zeile pro Benutzer, Tag, Methode,
  Anmeldeart und Client in der neuen Tabelle `expert_metrics_api_usages` (Migration 002).
  Switch-User-Anfragen werden dem Schlüsselinhaber zugerechnet. Zeilen älter als 90 Tage werden
  automatisch gelöscht (bei API-Anfragen, `/metrics`-Erhebungen und auf der Admin-Seite;
  `rake redmine_expert_metrics:purge_api_usage` für Cron); der Pfad wird ohne Query-String gespeichert, ein `?key=` landet also nie
  in der Tabelle. Die Erfassung lässt nie eine Anfrage scheitern.
- **Prometheus** (nur bei eingeschalteter Erfassung): `redmine_api_requests_total{method,auth}` (Counter), `redmine_api_users{window}`
  (`1d`, `7d`, `30d`) und `redmine_api_keys_total` — nur Summen, keine Namen.
- **Grafana-Dashboard**: neue Zeile *REST API* mit API-Benutzern, API-Schlüsseln und Anfragen
  pro Stunde nach Methode und nach Anmeldeart.

## [1.2.0] - 2026-09-13

### Hinzugefügt
- **Fertiges Grafana-Dashboard zum Import** (`contrib/grafana/redmine-expert-metrics.json`):
  Aktivität, Konten, Tickets und Mailaufkommen der Installation sowie eine Zeile zur
  Scrape-Gesundheit. Importieren, Prometheus-Datenquelle auswählen — die Panels hängen an einer
  Datenquellen-Variable, es muss nichts nachbearbeitet werden. Zwei Feinheiten stecken in den
  Abfragen: Jedes Panel reduziert mit `max` statt `sum`, weil jeder Pod dieselben datenbankweiten
  Zahlen meldet; die Job-Variable ist einfach auswählbar, weil zwei per `max` reduzierte Jobs zwei
  Installationen zu einer Zahl verschmelzen würden; und die Panels zur Scrape-Gesundheit verknüpfen
  `up` mit einem 24-h-Rückblick auf `redmine_info`, damit Sidecars mit demselben Job-Label
  draußen bleiben und ein Ziel, das nicht mehr antwortet, als 0 sichtbar bleibt, statt zu
  verschwinden. Die
  Mail-Panels bleiben ohne redmine_expert_helpdesk leer. Liegt im Release-Archiv bei.
- **`scripts/seed_screenshot_demo.rb` und das zugehörige Teardown** erzeugen eine synthetische
  Installation für die README-Screenshots: vierzehn Benutzer mit rückdatierten Sitzungs-Token
  über die Fenster 5/15/60 Minuten, vier Projekte, Tickets, Benachrichtigungszähler und
  Helpdesk-Mailvolumen. Das Skript verweigert den Dienst gegen eine Datenbank mit Daten, die es
  nicht selbst angelegt hat — Administrationsseite und `/metrics` melden installationsweite
  Zahlen, ein Seed auf echten Daten würde sie veröffentlichen.
- **Screenshots** unter `docs/screenshots/{en,de}/` — Administrationsseite und Grafana-Dashboard —
  sowie ein Abschnitt *Screenshots* in beiden READMEs.
- **CI, Issue-Vorlagen und Copilot-Anweisungen** (`.github/`): das Repository hat jetzt dieselbe
  GitHub-Einrichtung wie `redmine_expert_agile` und `redmine_expert_helpdesk` — `ci.yml` führt die
  MiniTest-Suite gegen Redmine 5.1/6.0/6.1/7.0-stable auf einer frischen MariaDB aus,
  `docker-image.yml` hängt das Plugin in die offiziellen `redmine:5.1/6.0/6.1/7.0`-Images ein,
  migriert es über `REDMINE_PLUGINS_MIGRATE` und verlangt Antworten von `/login` und `/metrics`
  (mit Prüfung auf `redmine_active_users` und `redmine_info`), und `ISSUE_TEMPLATE/` liefert die
  Formulare für Fehler und Wünsche. `.github/copilot-instructions.md` spiegelt `CLAUDE.md`; beide
  haben die bisher nur implizierten Konventionen bekommen (Ruby-2.7-Syntax, keine Benutzernamen in
  der Exposition, Migrationsnummerierung) sowie die Abschnitte zu CI und Releases.

### Behoben
- **`release.yml` akzeptierte fehlerhafte Tags.** Die Semver-Prüfung erlaubte dem optionalen
  Suffix, mit `.` zu beginnen, womit `v1.2.3.4` als gültig durchging, und ließ leere Bezeichner
  wie `1.2.3-a..b` zu.

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
