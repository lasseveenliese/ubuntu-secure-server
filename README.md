# Ubuntu 24.04 Hardening Setup Script

Dieses Repository enthält ein Installations- und Hardening-Skript für **Ubuntu 24.04**, das grundlegende Sicherheitsmaßnahmen automatisiert: Firewall (UFW), Fail2ban (sshd „aggressive“), SSH-Härtung (Key-only), Systemupdates und optional automatische Sicherheitsupdates inkl. möglichem Reboot um 04:00.

## Inhalt

- [Features](#features)
- [Voraussetzungen](#voraussetzungen)
- [Wichtige Hinweise gegen Aussperren](#wichtige-hinweise-gegen-aussperren)
- [Installation und Ausführung](#installation-und-ausführung)
- [Was wird genau konfiguriert](#was-wird-genau-konfiguriert)
  - [Firewall (UFW)](#firewall-ufw)
  - [SSH-Härtung](#ssh-härtung)
  - [Fail2ban (sshd aggressive)](#fail2ban-sshd-aggressive)
  - [Updates und Auto-Updates](#updates-und-auto-updates)
- [Geänderte/erstellte Dateien](#geänderteerstellte-dateien)
- [Überprüfung nach dem Lauf](#überprüfung-nach-dem-lauf)
- [Rollback / Rückgängig machen](#rollback--rückgängig-machen)
- [Troubleshooting](#troubleshooting)

## Features

- **Systemupdates**: `apt-get update`, `full-upgrade`, `autoremove`, `autoclean`
- **Firewall (UFW)**:
  - `default deny incoming`
  - `default allow outgoing`
  - erlaubt **80/tcp** und **443/tcp**
  - erlaubt **22/tcp (SSH)** mit Rate-Limit via `ufw limit 22/tcp`
- **SSH-Härtung**:
  - Login nur per **SSH-Key** (kein Passwort)
  - `UsePAM yes`
  - `PermitRootLogin prohibit-password` (Root nur per Key)
  - schreibt eine eigene Datei unter `sshd_config.d`
  - testet Konfiguration via `sshd -t` bevor SSH neu gestartet wird
- **Fail2ban**:
  - Jail `sshd` aktiviert
  - `mode = aggressive`
  - Ban-Action über **UFW**
- **Optional**: automatische Updates mit `unattended-upgrades`
  - Zeitplan: **04:00**
  - **Hinweis:** kann bei Bedarf automatisch rebooten

## Voraussetzungen

- **Ubuntu 24.04**
- Root-Zugriff (oder `sudo`)
- SSH-Zugang (empfohlen: bereits funktionierender Key-Login)

## Wichtige Hinweise gegen Aussperren

Wenn du das Skript remote per SSH ausführst, beachte unbedingt:

1. **Zweite SSH-Session offen lassen**, bevor du startest.
2. Stelle sicher, dass mindestens ein gültiger SSH-Key in einer dieser Dateien liegt:
   - `/root/.ssh/authorized_keys`
   - `/home/<dein-user>/.ssh/authorized_keys`
3. Falls keine Keys gefunden werden, warnt das Skript und fragt nach, ob es Passwort-Login trotzdem deaktivieren soll.

Zusätzlich setzt das Skript die Firewall strikt auf **nur 22/80/443 eingehend**. Wenn du weitere Ports brauchst (z.B. WireGuard, Mail, Monitoring), musst du sie anschließend erlauben.

## Installation und Ausführung

1. Skriptdatei speichern, z.B. als:
   - `setup-ubuntu24-hardening.sh`

2. Ausführbar machen und starten:
   ```bash
   chmod +x setup-ubuntu24-hardening.sh
   sudo ./setup-ubuntu24-hardening.sh
   ```

Während des Laufs wirst du am Ende gefragt, ob automatische Updates aktiviert werden sollen.

## Was wird genau konfiguriert

### Firewall (UFW)

* Setzt UFW zurück (`ufw reset`) und konfiguriert neu:

  * Incoming: **deny**
  * Outgoing: **allow**
  * Erlaubt:

    * `80/tcp`
    * `443/tcp`
    * `22/tcp` via `ufw limit` (Rate-Limit)

Wenn du zusätzliche Ports brauchst:

```bash
sudo ufw allow 51820/udp   # Beispiel WireGuard
sudo ufw allow 25/tcp      # Beispiel SMTP (nur wenn wirklich nötig)
sudo ufw status verbose
```

### SSH-Härtung

Das Skript erstellt:

* `/etc/ssh/sshd_config.d/99-hardening.conf`

Typische Inhalte:

* `UsePAM yes`
* `PubkeyAuthentication yes`
* `AuthenticationMethods publickey`
* `PasswordAuthentication no`
* `KbdInteractiveAuthentication no`
* `ChallengeResponseAuthentication no`
* `PermitRootLogin prohibit-password`

Vor dem Neustart wird geprüft:

```bash
sudo sshd -t
```

Danach:

```bash
sudo systemctl restart ssh
```

### Fail2ban (sshd aggressive)

Das Skript erstellt:

* `/etc/fail2ban/jail.d/sshd.conf`

Wichtige Werte:

* `enabled = true`
* `backend = systemd`
* `mode = aggressive`
* `findtime = 10m`
* `maxretry = 4`
* `bantime = 1h`
* `action = ufw[...]`

Status prüfen:

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

### Updates und Auto-Updates

Direkt am Anfang werden Updates eingespielt:

* `apt-get update`
* `apt-get full-upgrade`
* `apt-get autoremove --purge`
* `apt-get autoclean`

Wenn du am Ende **Auto-Updates** aktivierst, installiert das Skript:

* `unattended-upgrades`

Und setzt:

* automatische Paketlisten-Updates
* automatische unattended-upgrades
* optionaler Reboot **bei Bedarf** um **04:00**

Außerdem werden die Systemd-Timer fest auf Uhrzeiten gesetzt (ohne Random Delay):

* `apt-daily` um **03:30**
* `apt-daily-upgrade` um **04:00**

Timer prüfen:

```bash
systemctl list-timers --all | grep -E 'apt-daily|apt-daily-upgrade'
```

## Geänderte/erstellte Dateien

* Firewall:

  * UFW Regeln (intern), sichtbar über: `ufw status verbose`

* SSH:

  * `/etc/ssh/sshd_config.d/99-hardening.conf`

* Fail2ban:

  * `/etc/fail2ban/jail.d/sshd.conf`

* Auto-Updates (nur wenn aktiviert):

  * `/etc/apt/apt.conf.d/20auto-upgrades`
  * `/etc/apt/apt.conf.d/52unattended-upgrades-local`
  * `/etc/systemd/system/apt-daily.timer.d/override.conf`
  * `/etc/systemd/system/apt-daily-upgrade.timer.d/override.conf`

## Überprüfung nach dem Lauf

Empfohlen:

```bash
# Firewall
sudo ufw status verbose

# SSH Konfig
sudo sshd -t

# Fail2ban
sudo fail2ban-client status sshd

# Logs (Beispiele)
sudo journalctl -u ssh --no-pager -n 50
sudo journalctl -u fail2ban --no-pager -n 80
```

Teste danach unbedingt einen neuen SSH-Login per Key in einer zweiten Session.

## Rollback / Rückgängig machen

### Firewall zurücksetzen

```bash
sudo ufw disable
sudo ufw --force reset
```

### SSH-Änderungen entfernen

```bash
sudo rm -f /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t
sudo systemctl restart ssh
```

### Fail2ban entfernen oder deaktivieren

```bash
sudo systemctl disable --now fail2ban
sudo apt-get remove -y fail2ban
sudo rm -f /etc/fail2ban/jail.d/sshd.conf
```

### Unattended-Upgrades deaktivieren (falls aktiviert)

```bash
sudo apt-get remove -y unattended-upgrades
sudo rm -f /etc/apt/apt.conf.d/20auto-upgrades
sudo rm -f /etc/apt/apt.conf.d/52unattended-upgrades-local
sudo rm -rf /etc/systemd/system/apt-daily.timer.d
sudo rm -rf /etc/systemd/system/apt-daily-upgrade.timer.d
sudo systemctl daemon-reload
sudo systemctl restart apt-daily.timer apt-daily-upgrade.timer
```

## Troubleshooting

### „Permission denied“ beim Skript

```bash
chmod +x setup-ubuntu24-hardening.sh
sudo ./setup-ubuntu24-hardening.sh
```

### SSH-Verbindung bricht nach Neustart ab

* Das ist möglich, wenn SSH neu startet.
* Nutze eine zweite Session und logge dich erneut ein.

### Ausgesperrt (kein SSH-Zugang mehr)

* Nutze die Server-Konsole/Rescue-Mode (z.B. Hetzner) und überprüfe:

  * `authorized_keys`
  * `/etc/ssh/sshd_config.d/99-hardening.conf`
  * Firewall-Regeln (UFW)

### Fail2ban bannt dich selbst

* Prüfe die Fail2ban-Status und ggf. Unban:

  ```bash
  sudo fail2ban-client status sshd
  sudo fail2ban-client set sshd unbanip <DEINE_IP>
  ```

---

## Lizenz / Nutzung

Du kannst das Skript frei für eigene Server verwenden. Prüfe es vor produktivem Einsatz und passe es an deine Infrastruktur (zusätzliche Ports, andere SSH-User-Policies, Fail2ban-Tuning) an.

```
