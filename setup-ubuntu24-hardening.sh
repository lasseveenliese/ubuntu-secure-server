#!/usr/bin/env bash
set -euo pipefail

trap 'echo "FEHLER in Zeile $LINENO. Abbruch." >&2' ERR

log() { echo; echo "==> $*"; }

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte als root ausführen (z.B. sudo bash $0)." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "apt-get nicht gefunden. Dieses Skript ist für Ubuntu/Debian gedacht." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log "Paketlisten aktualisieren und System updaten"
apt-get update -y
apt-get full-upgrade -y
apt-get autoremove -y --purge
apt-get autoclean -y

log "UFW (Firewall) und Fail2ban installieren"
apt-get install -y ufw fail2ban

log "Firewall konfigurieren: incoming deny (default), outgoing allow, Ports 22/80/443 erlaubt"
# Achtung: reset löscht bestehende UFW-Regeln
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
# SSH erlaubt, aber mit Rate-Limit (hilft gegen Brute Force zusätzlich zu Fail2ban)
ufw limit 22/tcp
ufw --force enable

log "SSH härten: nur Key-Login, PAM aktiv"
SSHD_HARDEN_FILE="/etc/ssh/sshd_config.d/99-hardening.conf"

# Sicherheitsgurt: Nur Passwort-Login deaktivieren, wenn mindestens ein authorized_keys existiert
HAS_KEYS="no"
if [[ -s /root/.ssh/authorized_keys ]]; then HAS_KEYS="yes"; fi
if [[ -n "${SUDO_USER:-}" ]] && [[ -s "/home/${SUDO_USER}/.ssh/authorized_keys" ]]; then HAS_KEYS="yes"; fi

if [[ "${HAS_KEYS}" != "yes" ]]; then
  echo
  echo "WARNUNG: Keine nicht-leere authorized_keys gefunden (weder /root noch /home/\$SUDO_USER)."
  echo "Wenn du jetzt Passwort-Login deaktivierst, kannst du dich ggf. aussperren."
  read -r -p "Trotzdem Passwort-Login deaktivieren? (ja/nein) " FORCE_DISABLE_PW
  if [[ "${FORCE_DISABLE_PW}" != "ja" ]]; then
    echo "OK: SSH-Passwort-Login bleibt unverändert. Du kannst später erneut ausführen, nachdem du Keys hinterlegt hast."
    DISABLE_PW="no"
  else
    DISABLE_PW="yes"
  fi
else
  DISABLE_PW="yes"
fi

# Konfig schreiben (über conf.d statt sshd_config direkt)
cat > "${SSHD_HARDEN_FILE}" <<'EOF'
# Managed by hardening script
UsePAM yes

PubkeyAuthentication yes
AuthenticationMethods publickey

PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# Root darf sich weiterhin per Key anmelden (kein Passwort)
PermitRootLogin prohibit-password
EOF

if [[ "${DISABLE_PW}" != "yes" ]]; then
  # Passwortlogin nicht deaktivieren: die entsprechenden Zeilen neutralisieren
  # (Wir lassen PubkeyAuthentication/UsePAM drin, aber entfernen die Passwort-Verbote)
  sed -i \
    -e '/^PasswordAuthentication no$/d' \
    -e '/^AuthenticationMethods publickey$/d' \
    -e '/^KbdInteractiveAuthentication no$/d' \
    -e '/^ChallengeResponseAuthentication no$/d' \
    "${SSHD_HARDEN_FILE}"
fi

# SSHD-Konfig testen, bevor wir neu starten
log "SSHD-Konfiguration prüfen"
sshd -t

log "SSH Dienst neu starten"
systemctl restart ssh

log "Fail2ban konfigurieren: sshd im Aggressive Mode, Ban via UFW"
F2B_SSHD_JAIL="/etc/fail2ban/jail.d/sshd.conf"
cat > "${F2B_SSHD_JAIL}" <<'EOF'
[sshd]
enabled = true
backend = systemd
mode = aggressive
port = ssh
logpath = %(sshd_log)s

# Tuning (bei Bedarf anpassen)
findtime = 10m
maxretry = 4
bantime  = 1h

# Ban über UFW
action = ufw[port="ssh", protocol="tcp"]
EOF

log "Fail2ban starten/aktivieren"
systemctl enable --now fail2ban
systemctl restart fail2ban

log "Status-Checks"
ufw status verbose || true
fail2ban-client status sshd || true

echo
read -r -p 'Sollen Updates künftig automatisch installiert werden? Hinweis: bei "ja" werden Updates nachts um 04:00 eingespielt und der Server kann bei Bedarf automatisch rebooten. (ja/nein) ' AUTO_UPDATES

if [[ "${AUTO_UPDATES}" == "ja" ]]; then
  log "unattended-upgrades installieren und aktivieren"
  apt-get install -y unattended-upgrades

  # Auto-Upgrades aktivieren
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Lokale Overrides (nicht die Standarddatei zerlegen)
  cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

  # Systemd Timer auf feste Uhrzeiten setzen (Update-Listen 03:30, Upgrades 04:00, ohne Random Delay)
  mkdir -p /etc/systemd/system/apt-daily.timer.d
  cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30
RandomizedDelaySec=0
EOF

  mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d
  cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00
RandomizedDelaySec=0
EOF

  systemctl daemon-reload
  systemctl restart apt-daily.timer apt-daily-upgrade.timer

  log "Timer-Status"
  systemctl list-timers --all | grep -E 'apt-daily|apt-daily-upgrade' || true
fi

log "Fertig"
echo "Wichtig: Prüfe, dass du dich per SSH-Key anmelden kannst, bevor du die aktuelle Sitzung schließt."
