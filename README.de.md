> 🇩🇪 Deutsche Version · [English version](README.md)

# Redmine expert Metrics

Zeigt, wer **gerade jetzt** in Redmine arbeitet, und stellt das zusammen mit ein paar
Grundzahlen als Prometheus-Metriken bereit. Gebaut für die Frage „Kann ich eine Instanz für
Wartungsarbeiten herunterfahren?“. Läuft auf **Redmine 5.1, 6.0, 6.1 und 7.0**.


## Screenshots

Alle Screenshots zeigen eine synthetische Installation, erzeugt von
`scripts/seed_screenshot_demo.rb` gegen eine leere Datenbank.

![Administration, expert Metrics: aktive Benutzer über 5, 15 und 60 Minuten, offene Sitzungen
und Anmeldungen der letzten 24 Stunden, darunter eine Tabelle aller Benutzer mit einer Anfrage
in der letzten Stunde mit Mitgliedsname, Name, letzter Aktivität, angemeldet seit und Anzahl
Sitzungen](docs/screenshots/de/01-active-users.png)

## Was es macht

- **Administration → expert Metrics**: alle Benutzer mit mindestens einer Anfrage in den
  letzten 60 Minuten, neueste zuerst, mit letzter Aktivität, Anmeldezeitpunkt und Anzahl der
  Sitzungen. Die Seite aktualisiert sich jede Minute selbst. Oben eine Zusammenfassung: aktive
  Benutzer in den letzten 5 / 15 / 60 Minuten, angemeldete Sitzungen, Anmeldungen in den letzten 24 h.
- **`GET /admin/active_users.json`**: dieselben Daten für Skripte, mit Admin-API-Key.
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
| `redmine_metrics_collect_seconds` | – | Laufzeit der letzten ungecachten Erhebung |
| `redmine_info` | `redmine_version`, `plugin_version` | immer 1 |

## Wie „aktiv“ gemessen wird

Jede Browser-Sitzung besitzt eine Zeile in Redmines Tabelle `tokens` (`action = session`),
und der Kern setzt deren `updated_on` bei jeder Anfrage neu, höchstens einmal pro Minute. Das
Plugin liest nur diese Zeilen. Das funktioniert mit jedem Session-Store (Cookie, Redis,
Datenbank), gilt für die gesamte Installation und braucht keine Migration. API-Key-Zugriffe und
der Mailabruf erzeugen nie ein Sitzungs-Token und zählen daher nicht als „aktiv“.

Der Datenstand hinter `/metrics` und der Admin-Seite wird 15 Sekunden im `Rails.cache`
gehalten, sodass mehrere Pods, die alle paar Sekunden abgefragt werden, nur einen Satz
Datenbankabfragen kosten.

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

## Zugriffsschutz

| Endpunkt | Wer |
|---|---|
| `/admin/active_users` (HTML) | Redmine-Administratoren |
| `/admin/active_users.json` | Administratoren, auch per `X-Redmine-API-Key` / `?key=` (REST-API muss aktiviert sein) |
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
# Redmine neu starten
```

Danach die Plugin-Migration ausführen (eine kleine Zählertabelle):

```bash
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_metrics RAILS_ENV=production
```

Alternativ das Release-Archiv von der
[Releases-Seite](https://github.com/expertZentrale/redmine_expert_metrics/releases) herunterladen
und nach `plugins/` entpacken.

Keine Einstellungen, keine Berechtigungen — das Plugin ist aktiv, sobald es geladen wird.

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
