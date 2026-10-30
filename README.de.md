> 🇩🇪 Deutsche Version · [English version](README.md)

# Redmine expert Metrics

Zeigt, wer **gerade jetzt** in Redmine arbeitet, wer die **REST-API** nutzt (und mit
welchem Skript) und **welche Seiten langsam sind und warum**, und stellt das zusammen mit ein paar
Grundzahlen als Prometheus-Metriken bereit. Gebaut für die Fragen „Kann ich eine Instanz für
Wartungsarbeiten herunterfahren?“, „Wer ändert Daten über die API?“ und „Redmine fühlt sich
langsamer an – wo bleibt die Zeit?“. Läuft auf **Redmine 5.1, 6.0, 6.1 und 7.0**.


## Screenshots

Alle Screenshots zeigen eine synthetische Installation, erzeugt von
`scripts/seed_screenshot_demo.rb` gegen eine leere Datenbank.

![Administration, expert Metrics: aktive Benutzer über 5, 15 und 60 Minuten, offene Sitzungen
und Anmeldungen der letzten 24 Stunden, darunter eine Tabelle aller Benutzer mit einer Anfrage
in der letzten Stunde mit Mitgliedsname, Name, letzter Aktivität, angemeldet seit und Anzahl
Sitzungen](docs/screenshots/de/01-active-users.png)

### Grafana-Dashboard

`contrib/grafana/redmine-expert-metrics.json`, über eine Arbeitswoche.

![Das Dashboard über eine Arbeitswoche: aktive Benutzer in den drei Zeitfenstern, offene
Sitzungen, Konten nach Status, offene und geschlossene Tickets sowie Kunden- und
Benachrichtigungsmail pro Stunde](docs/screenshots/de/04-grafana.png)


## Was es macht

- **Administration → expert Metrics**: alle Benutzer mit mindestens einer Anfrage in den
  letzten 60 Minuten, neueste zuerst, mit letzter Aktivität, Anmeldezeitpunkt und Anzahl der
  Sitzungen. Die Seite aktualisiert sich jede Minute selbst. Oben eine Zusammenfassung: aktive
  Benutzer in den letzten 5 / 15 / 60 Minuten, angemeldete Sitzungen, Anmeldungen in den letzten 24 h.
- **`GET /admin/active_users.json`**: dieselben Daten für Skripte, mit Admin-API-Key.
- **Administration → expert Metrics → API-Nutzung** (`/admin/api_usage`, auch `.json`): alle
  Benutzer, deren API-Zugangsdaten in den letzten 1 / 7 / 30 / 90 Tagen verwendet wurden, mit
  Anfragen, schreibenden Anfragen, Anmeldeart, Clients (User-Agent), letzter IP, letztem Pfad und
  Erstellungsdatum des Schlüssels — dazu die Benutzer mit einem API-Schlüssel, der im Zeitraum
  nicht verwendet wurde. Siehe [API-Nutzung](#api-nutzung).
- **Administration → expert Metrics → Langsame Anfragen** (`/admin/slow_requests`, auch `.json`):
  Anfragen über der eingestellten Schwelle mit der Zeit in Datenbank, Ansichten, Plugin-Hooks und
  Garbage Collection, den langsamsten SQL-Anweisungen (ohne Werte) und den langsamsten
  Hook-Listenern, dazu eine Zusammenfassung je Controller und Aktion. Siehe
  [Performance-Metriken](#performance-metriken).
- **`GET /metrics`**: Prometheus-Textformat, nur Summen (keine Namen).

| Metrik | Labels | Bedeutung |
|---|---|---|
| `redmine_active_users` | `window` = `5m`, `15m`, `60m` | verschiedene Benutzer mit einer Sitzungs-Anfrage im Zeitfenster |
| `redmine_sessions_total` | – | Sitzungs-Token, die Redmine noch akzeptieren würde (aktiv oder untätig) |
| `redmine_recent_logins_users` | `window` = `24h` | verschiedene Benutzer mit letzter Anmeldung im Zeitfenster |
| `redmine_users_total` | `status` = `active`, `registered`, `locked` | Benutzerkonten |
| `redmine_projects_total` | `status` = `active` | Projekte |
| `redmine_issues_total` | `state` = `open`, `closed` | Tickets nach dem Geschlossen-Kennzeichen ihres Status |
| `redmine_notifications_sent_total` | `project` | Benachrichtigungs-Mails, die der Redmine-Kern an seine Benutzer zugestellt hat, eine pro Empfänger (Counter); leeres Projekt für Konto- und Sicherheitsmails |
| `redmine_helpdesk_mails_total` | `project`, `direction` = `in`, `out`, `init` | Mails aus [redmine_expert_helpdesk](https://github.com/expertZentrale/redmine_expert_helpdesk): `in` von Kunden empfangen, `out` an Kunden gesendet (Antworten, Autoresponder, Nachfragen), `init` Erstmail eines in Redmine angelegten Tickets. Nur vorhanden, wenn dieses Plugin installiert ist (Counter) |
| `redmine_api_requests_total`¹ | `method` = `GET`, `POST`, …, `auth` = `key`, `basic`, `password`, `oauth` | mit API-Zugangsdaten angemeldete Anfragen (Counter) |
| `redmine_api_users`¹ | `window` = `1d`, `7d`, `30d` | verschiedene Benutzer mit API-Anfragen in den letzten n Kalendertagen, heute eingeschlossen |
| `redmine_api_keys_total`¹ | – | Benutzer mit API-Schlüssel |
| `redmine_metrics_collect_seconds` | – | Laufzeit der letzten ungecachten Erhebung |
| `redmine_info` | `redmine_version`, `plugin_version` | immer 1 |

¹ Die drei `redmine_api_*`-Reihen gibt es nur, solange *API-Nutzung erfassen* eingeschaltet ist.

Solange *Performance-Metriken erfassen* eingeschaltet ist, enthält `/metrics` zusätzlich Reihen
**je Prozess** (siehe [Performance-Metriken](#performance-metriken)):

| Metrik | Labels | Bedeutung |
|---|---|---|
| `redmine_http_request_duration_seconds` | `controller`, `action`, `format` | Histogramm der Zeit, die Redmine für eine Anfrage gebraucht hat (Callbacks, Aktion, Rendern) |
| `redmine_http_request_db_seconds_total` | `controller`, `action`, `format` | Zeit in SQL-Anweisungen (Counter) |
| `redmine_http_request_view_seconds_total` | `controller`, `action`, `format` | Zeit für das Rendern der Ansichten, ohne SQL (Counter) |
| `redmine_http_request_hook_seconds_total` | `controller`, `action`, `format` | Zeit in Plugin-Hook-Listenern (Counter) |
| `redmine_http_request_sql_queries_total` | `controller`, `action`, `format` | an die Datenbank gesendete SQL-Anweisungen, Treffer im Query-Cache nicht mitgezählt (Counter) |
| `redmine_http_server_errors_total` | `controller`, `action` | mit einem 5xx-Status beantwortete Anfragen (Counter) |
| `redmine_hook_seconds_total` / `redmine_hook_calls_total` | `hook`, `listener` | Zeit in und Aufrufe jedes Hook-Listeners, also welches Plugin wie lange auf einer Seite braucht (Counter) |
| `redmine_job_duration_seconds` | `job_class` | Histogramm der Laufzeit von Hintergrundjobs |
| `redmine_job_failures_total` | `job_class` | Hintergrundjobs, die mit einem Fehler endeten (Counter) |
| `redmine_process_resident_memory_bytes` | – | RSS des Redmine-Prozesses (Linux) |
| `redmine_process_start_time_seconds` | – | Startzeit des Prozesses, Unix-Zeit |
| `redmine_ruby_gc_runs_total` | `type` = `minor`, `major` | Läufe der Garbage Collection (Counter) |
| `redmine_ruby_gc_seconds_total` | – | Zeit in der Garbage Collection (Counter, Ruby 3.1+) |
| `redmine_ruby_heap_live_slots`, `redmine_ruby_allocated_objects_total`, `redmine_ruby_threads` | – | Kennzahlen zu Ruby-Heap und Threads |
| `redmine_puma_backlog`, `redmine_puma_running`, `redmine_puma_pool_capacity`, `redmine_puma_max_threads` | – | Puma-Threadpool (nur im Single-Modus) |

## Wie „aktiv“ gemessen wird

Jede Browser-Sitzung besitzt eine Zeile in Redmines Tabelle `tokens` (`action = session`),
und der Kern setzt deren `updated_on` bei jeder Anfrage neu, höchstens einmal pro Minute. Das
Plugin liest nur diese Zeilen. Das funktioniert mit jedem Session-Store (Cookie, Redis,
Datenbank), gilt für die gesamte Installation und braucht keine Migration. API-Key-Zugriffe und
der Mailabruf erzeugen nie ein Sitzungs-Token und zählen daher nicht als „aktiv“.

Der Datenstand hinter `/metrics` und der Admin-Seite wird 15 Sekunden im `Rails.cache`
gehalten, sodass mehrere Pods, die alle paar Sekunden abgefragt werden, nur einen Satz
Datenbankabfragen kosten.

## API-Nutzung

API-Schlüssel legen die Benutzer selbst an, und sie tragen deren volle Berechtigungen; mit
KI-generierten Skripten nutzen sie immer mehr Leute. Der Redmine-Kern protokolliert nicht, wann
ein Schlüssel verwendet wird, also kann das Plugin jede Anfrage erfassen, die der Kern über
API-Zugangsdaten angemeldet hat.

**Die Erfassung ist standardmäßig aus.** Einschalten unter *Administration → Plugins → Redmine
expert Metrics → Konfigurieren* (*API-Nutzung erfassen*). Solange sie aus ist, kosten
API-Anfragen nichts zusätzlich, `/metrics` führt keine API-Abfragen aus und lässt die
`redmine_api_*`-Reihen weg, und die Seite zeigt, was erfasst wurde, solange sie an war. Bereits
gespeicherte Zeilen werden trotzdem nach 90 Tagen gelöscht.


- **Was zählt**: `.json`-/`.xml`-Anfragen mit Header `X-Redmine-API-Key` oder `?key=` (`key`),
  einem API-Schlüssel als HTTP-Basic-Benutzername (`basic`), Login und Passwort per HTTP Basic
  (`password` — rot hervorgehoben, das Skript speichert ein Passwort) oder einem OAuth-Token
  (`oauth`, Redmine 6.1+). Anfragen, die danach abgelehnt werden (403), zählen mit; Anfragen mit
  ungültigem Schlüssel, anonyme Anfragen und Browser-Sitzungen nicht. Solange die REST-API
  deaktiviert ist, wird nichts erfasst.
- **Was gespeichert wird**: eine Zeile pro Benutzer, Tag, HTTP-Methode, Anmeldeart und
  User-Agent in der Tabelle `expert_metrics_api_usages`, mit Anzahl der Anfragen, erstem und
  letztem Zeitpunkt, der **letzten IP-Adresse** und dem letzten Pfad (ohne Query-String, der den
  Schlüssel enthalten kann). Wechselt ein Admin-Schlüssel den Benutzer (`X-Redmine-Switch-User`),
  wird die Anfrage dem Schlüsselinhaber zugerechnet und der Zielbenutzer angezeigt.
- **Aufbewahrung**: Zeilen älter als **90 Tage** werden automatisch gelöscht — bei API-Anfragen,
  bei jeder `/metrics`-Erhebung und auf der Admin-Seite, höchstens einmal pro Stunde. Ohne
  regelmäßigen Prometheus-Abruf `bundle exec rake redmine_expert_metrics:purge_api_usage RAILS_ENV=production`
  per Cron ausführen. IP-Adresse und
  User-Agent sind personenbezogene Daten — das Protokoll in der Datenschutzdokumentation erwähnen.
- **Kosten**: ein `UPDATE` pro API-Anfrage (plus eines auf der Zählertabelle); ein `INSERT` nur
  für die erste Anfrage eines Tages je Benutzer, HTTP-Methode, Anmeldeart und Client — ein
  Skript, das liest und schreibt, erzeugt also zwei Zeilen pro Tag, nicht eine.

Was ein Skript *geändert* hat, steht wie gewohnt in der Ticket-Historie — diese Seite zeigt,
wessen Schlüssel und welcher Client dahinterstand.

## Performance-Metriken

Wenn sich ein Redmine „langsamer anfühlt“, ist die erste Frage *wo*: eine Seite oder alle, die
Datenbank oder die Ansichten, Redmine selbst oder eines der Plugins. Der Kern schreibt pro Anfrage
eine Zeitzeile ins Log, aber Produktivinstallationen loggen meist auf `warn`, und eine Logzeile
lässt sich nicht über Wochen als Kurve zeichnen.

**Die Erfassung ist standardmäßig aus.** Einschalten unter *Administration → Plugins → Redmine
expert Metrics → Konfigurieren* (*Performance-Metriken erfassen*). Solange sie aus ist, hängt kein
SQL- oder Anfrage-Abonnent: Eine Anfrage kostet einen Einstellungs-Lesezugriff, ein Plugin-Hook-Aufruf
eine Thread-lokale Prüfung, ein Hintergrundjob einen Einstellungs-Lesezugriff, und `/metrics` lässt
die Reihen weg. Ein- und Ausschalten wirkt in jedem
Prozess mit dessen nächster Anfrage.

- **Je Anfrage**: Das Plugin umschließt jede Controller-Aktion und hört auf die Instrumentierung
  von Rails selbst (`sql.active_record`, `process_action.action_controller`,
  `perform.active_job`). Jeder Hook-Listener wird einzeln gemessen, das Dashboard zeigt also, welches
  Plugin wie lange etwa auf der Ticketseite braucht. Kosten: wenige Mikrosekunden pro
  SQL-Anweisung und Hook-Aufruf, ein Lock pro Anfrage.
- **Je Prozess**: Diese Reihen liegen im Speicher jedes Redmine-Prozesses, nicht in der Datenbank.
  Jeder Pod meldet seinen eigenen Anteil, Prometheus muss **jeden Pod** abfragen (ein
  Kubernetes-`ServiceMonitor`/`PodMonitor` tut das), und Dashboards addieren sie mit **`sum`** —
  das Gegenteil der datenbankweiten Reihen oben. Ein Neustart beginnt bei null; `rate()` und
  `increase()` kommen damit zurecht. Mehrere Puma-*Worker* pro Pod (Cluster-Modus) würden jeweils
  nur ihre eigenen Anfragen zählen, aber nur einer beantwortet die Abfrage; Puma im Single-Modus
  betreiben (wie das offizielle Docker-Image) oder jeden Worker abfragen. Hintergrundjobs zählt der
  Prozess, der sie ausführt — mit Redmines Standard-Adapter (`async`, im Prozess) ist das der
  Web-Prozess; ein eigener Job-Worker ohne Webserver erfasst sie, lässt sich aber nicht abfragen.
- **Langsame Anfragen**: Eine Anfrage, die mindestens die *Schwelle für langsame Anfragen*
  (Standard 2000 ms) dauert, wird mit ihrer Aufschlüsselung in `expert_metrics_slow_requests`
  gespeichert und als eine `warn`-Zeile mit ihrer Request-ID geloggt. SQL-Anweisungen werden mit
  `?` statt ihrer Werte gespeichert (Zeichenketten in einfachen und, unter MySQL/MariaDB, doppelten
  Anführungszeichen, Dollar-Strings von PostgreSQL, Zahlen), Suchbegriffe und E-Mail-Adressen landen
  also nicht in der Tabelle. Höchstens 30 Zeilen pro Prozess und Minute werden geschrieben — eine langsame Datenbank
  macht jede Anfrage langsam, und alle zu erfassen würde dort Last erzeugen, wo schon zu viel ist.
  Zeilen werden nach **14 Tagen** gelöscht. Eine Schwelle von `0` speichert jede Anfrage; nur für
  kurze Messungen verwenden.
- **Server-Timing**: Administratoren erhalten einen `Server-Timing`-Response-Header (`app`, `db`
  mit Anzahl der Anweisungen, `view`, `hooks`, `gc`), den die Entwicklerwerkzeuge des Browsers
  unter *Netzwerk → Timing* zeigen. Praktisch, um eine einzelne Seite in Produktion ohne Zugriff
  auf die Logs zu prüfen.

Nützliche Abfragen:

```promql
# 95. Perzentil der Ticketseite, alle Pods zusammen
histogram_quantile(0.95, sum by (le) (rate(redmine_http_request_duration_seconds_bucket{controller="issues", action="show"}[5m])))

# Langsamste Aktionen nach Durchschnittszeit
topk(10, sum by (controller, action) (rate(redmine_http_request_duration_seconds_sum[1h]))
       / sum by (controller, action) (rate(redmine_http_request_duration_seconds_count[1h])))

# Welcher Plugin-Hook kostet am meisten pro Sekunde Laufzeit
topk(10, sum by (listener) (rate(redmine_hook_seconds_total[1h])))
```

Sinnvolle Alarme (nicht mitgeliefert, an die eigene Installation anpassen):

| Bedingung | Deutet hin auf |
|---|---|
| p95 von `issues#show` über 1,5 s für 15 Minuten | eine langsame Abfrage oder einen Hook auf der meistgenutzten Seite |
| `redmine_process_resident_memory_bytes` über 85 % des Container-Limits | Speicherwachstum Richtung OOM-Kill |
| `rate(redmine_ruby_gc_seconds_total[5m])` über 0,1 | mehr als 10 % der Laufzeit in der Garbage Collection |
| `redmine_puma_backlog` über 0 für 5 Minuten | Anfragen warten auf einen Thread |

## Wie Mails gezählt werden

- **Benachrichtigungen an Redmine-Benutzer**: ein `Mail`-Observer zählt jede zugestellte
  Nachricht mit dem Kern-Header `X-Mailer: Redmine`, gelabelt mit ihrem `X-Redmine-Project`.
  Redmine schickt eine Mail pro Empfänger, gezählt werden also „zugestellte Mails“, nicht
  „Ereignisse“. Die Zähler liegen in der plugineigenen Tabelle `expert_metrics_counters`
  (eine Migration), gemeinsam für alle Pods und über Neustarts hinweg.
- **Kundenmails des Helpdesk-Plugins**: direkt aus dessen Tabelle `helpdesk_messages`, nach
  Projekt und Richtung gruppiert. Diese Mails tragen den Kern-Header nicht, die beiden
  Metriken überschneiden sich also nie.

Beide sind kumulativ, in Prometheus daher `increase()` / `rate()` verwenden:

```promql
sum by (project) (increase(redmine_helpdesk_mails_total{direction="in"}[24h]))
sum by (project) (increase(redmine_notifications_sent_total[1h]))
```

## Mehrere Instanzen (Kubernetes)

Jeder Pod meldet **dieselben** installationsweiten Zahlen. Mit `max` zusammenfassen, nie mit `sum`:

```promql
max by (window) (redmine_active_users)
```

Die [Performance-Reihen](#performance-metriken) sind die Ausnahme: Sie gelten je Prozess und
werden daher mit `sum` zusammengefasst.

## Zugriffsschutz

| Endpunkt | Wer |
|---|---|
| `/admin/active_users` (HTML) | Redmine-Administratoren |
| `/admin/active_users.json` | Administratoren, auch per `X-Redmine-API-Key` / `?key=` (REST-API muss aktiviert sein) |
| `/admin/api_usage` (HTML, `.json`) | Administratoren; das JSON auch per Admin-API-Key |
| `/admin/slow_requests` (HTML, `.json`) | Administratoren; das JSON auch per Admin-API-Key |
| `/metrics` | standardmäßig offen; ist `metrics_token` in `config/configuration.yml` gesetzt, muss er als `Authorization: Bearer <token>` oder `?token=<token>` mitgeschickt werden. Administratoren (Sitzung oder API-Key) kommen immer durch. |

```yaml
# config/configuration.yml
production:
  metrics_token: "change-me"
```

`/metrics` funktioniert auch, wenn in den Redmine-Einstellungen *Authentifizierung erforderlich* aktiv ist.

## Installation

```bash
cd /pfad/zu/redmine/plugins
git clone https://github.com/expertZentrale/redmine_expert_metrics.git
```

Danach die Plugin-Migrationen ausführen (eine Zählertabelle, die Tabelle für die API-Nutzung und
die für langsame Anfragen), und zwar **vor** dem Neustart von Redmine — ein Prozess, der ohne die
Tabellen startet, erfasst API-Nutzung und langsame Anfragen erst nach dem nächsten Neustart:

```bash
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_metrics RAILS_ENV=production
# Redmine neu starten
```

Alternativ das Release-Archiv von der
[Releases-Seite](https://github.com/expertZentrale/redmine_expert_metrics/releases) herunterladen
und nach `plugins/` entpacken.

Keine Berechtigungen; drei Einstellungen: *API-Nutzung erfassen* (standardmäßig aus, siehe
[API-Nutzung](#api-nutzung)), *Performance-Metriken erfassen* (standardmäßig aus) und *Schwelle für
langsame Anfragen* (2000 ms, siehe [Performance-Metriken](#performance-metriken)). Alles andere ist
aktiv, sobald das Plugin geladen wird.

## Grafana-Dashboard

Ein fertiges Dashboard liegt in
[`contrib/grafana/redmine-expert-metrics.json`](contrib/grafana/redmine-expert-metrics.json).
Unter *Dashboards → New → Import* die Datei hochladen oder ihren Inhalt einfügen und die eigene
Prometheus-Datenquelle auswählen — mehr ist nicht zu konfigurieren.

Es zeigt aktive Benutzer je Zeitfenster, angemeldete Sitzungen, Konten nach Status, offene Tickets,
aktive Projekte, das Mailaufkommen von Helpdesk und Benachrichtigungen, REST-API-Benutzer und
Anfragen pro Stunde nach Methode und Anmeldeart, eine Zeile zur Scrape-Gesundheit mit
Sammeldauer und Status je Ziel sowie eine Performance-Zeile: Antwortzeit-Perzentile von Ticketseite,
Ticketliste und Speichern, die langsamsten Aktionen, Datenbank- gegen Ansichts- gegen Hook-Zeit,
SQL-Anweisungen pro Anfrage, Hook-Zeit je Plugin, Hintergrundjobs sowie Speicher, GC und Puma je
Pod. Eine Variable wählt die Installation: **Job**,
der Scrape-Job, der diese Metriken ausliefert.

Drei Feinheiten stecken in den Abfragen selbst, statt sie dem Leser zu überlassen:

- **Jedes Panel aggregiert mit `max`, nie mit `sum`** — außer der Performance-Zeile. Jeder Pod
  meldet dieselben datenbankweiten Zahlen; eine Summe vervielfacht daher jeden Wert mit der Anzahl
  der Replicas. Die Performance-Reihen gelten je Prozess und werden stattdessen summiert.
- **Job ist einfach auswählbar.** Da die Panels mit `max` reduzieren, würden zwei gleichzeitig
  gewählte Jobs zwei Redmine-Installationen unbemerkt zu einer Zahl verschmelzen.
- **Die Panels zur Scrape-Gesundheit folgen nur den Redmine-Zielen und behalten ein totes Ziel im
  Blick.** `up` existiert für jedes Ziel einer Prometheus-Instanz — auch für Sidecars, die sich das
  Job-Label mit Redmine teilen. Das Panel verknüpft `up` deshalb mit einem 24-h-Rückblick auf
  `redmine_info`. Ohne diesen Rückblick würde ein Ziel, das nicht mehr antwortet, veralten und aus
  dem Panel verschwinden, statt auf 0 zu fallen.

Die Mail-Panels bleiben leer, solange
[redmine_expert_helpdesk](https://github.com/expertZentrale/redmine_expert_helpdesk) nicht
installiert ist; alles andere funktioniert mit diesem Plugin allein.

## Nutzung vor Wartungsarbeiten

```bash
curl -s -H "X-Redmine-API-Key: $KEY" https://redmine.example.com/admin/active_users.json | jq '.summary.active_users'
curl -s https://redmine.example.com/metrics | grep redmine_active_users
```

## Tests

MiniTest, benötigt eine Redmine-Umgebung:

```bash
bundle exec rake redmine:plugins:test NAME=redmine_expert_metrics RAILS_ENV=test
```

## Lizenz

Copyright (C) 2026 Dennis Buehring

**GNU General Public License, Version 2 oder (nach Wahl) jede spätere Version** — dieselbe Lizenz
wie Redmine selbst. Der vollständige Text steht in [`LICENSE`](LICENSE). OHNE JEDE GEWÄHRLEISTUNG.

Es werden keine Fremdkomponenten mitgeliefert.
