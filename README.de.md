> 🇩🇪 Deutsche Version · [English version](README.md)

# Redmine expert Metrics

Zeigt, wer **gerade jetzt** in Redmine arbeitet, und stellt das zusammen mit ein paar
Grundzahlen als Prometheus-Metriken bereit. Gebaut für die Frage „Kann ich eine Instanz für
Wartungsarbeiten herunterfahren?“. Läuft auf **Redmine 5.1, 6.0, 6.1 und 7.0**.

## Was es macht

- **Administration → Aktive Benutzer**: alle Benutzer mit mindestens einer Anfrage in den
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

Keine Migrationen, keine Einstellungen, keine Berechtigungen — das Plugin ist aktiv, sobald es geladen wird.

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
