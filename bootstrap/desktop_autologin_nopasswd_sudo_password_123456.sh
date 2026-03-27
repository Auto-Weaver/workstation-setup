#!/usr/bin/env bash

set -euo pipefail

DESKTOP_USER="${SUDO_USER:-user}"
LOGIN_PASSWORD="123456"
GDM_CONF="/etc/gdm3/custom.conf"
SUDOERS_FILE=""

usage() {
  cat <<'EOF' >&2
Usage: sudo bash bootstrap/desktop_autologin_nopasswd_sudo_password_123456.sh [options]

Options:
  --desktop-user USER   Target desktop user (default: SUDO_USER or user)
  --password PASS       Login password to set (default: 123456)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop-user)
      if [[ $# -lt 2 ]]; then
        echo "--desktop-user requires a value." >&2
        usage
        exit 1
      fi
      DESKTOP_USER="$2"
      shift 2
      ;;
    --password)
      if [[ $# -lt 2 ]]; then
        echo "--password requires a value." >&2
        usage
        exit 1
      fi
      LOGIN_PASSWORD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root: sudo bash bootstrap/desktop_autologin_nopasswd_sudo_password_123456.sh" >&2
  exit 1
fi

if [[ -z "${DESKTOP_USER}" || "${DESKTOP_USER}" == "root" ]]; then
  echo "A non-root desktop user is required. Use --desktop-user USER." >&2
  exit 1
fi

if ! id "${DESKTOP_USER}" >/dev/null 2>&1; then
  echo "Desktop user does not exist: ${DESKTOP_USER}" >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Unsupported OS: /etc/os-release not found" >&2
  exit 1
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This script currently targets Ubuntu. Detected: ${ID:-unknown}" >&2
  exit 1
fi

if [[ ! -f "${GDM_CONF}" ]]; then
  echo "GDM config not found: ${GDM_CONF}" >&2
  echo "This script expects Ubuntu desktop with gdm3." >&2
  exit 1
fi

backup_gdm="${GDM_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "${GDM_CONF}" "${backup_gdm}"

tmp_gdm="$(mktemp)"
awk -v target_user="${DESKTOP_USER}" '
BEGIN {
  in_daemon = 0
  seen_daemon = 0
  wrote_enable = 0
  wrote_login = 0
}
function emit_daemon_settings() {
  if (!wrote_enable) {
    print "AutomaticLoginEnable=true"
    wrote_enable = 1
  }
  if (!wrote_login) {
    print "AutomaticLogin=" target_user
    wrote_login = 1
  }
}
/^\[daemon\][[:space:]]*$/ {
  seen_daemon = 1
  in_daemon = 1
  print
  next
}
/^\[[^]]+\][[:space:]]*$/ {
  if (in_daemon) {
    emit_daemon_settings()
    in_daemon = 0
  }
  print
  next
}
{
  if (in_daemon) {
    if ($0 ~ /^[#;]?[[:space:]]*AutomaticLoginEnable[[:space:]]*=/) {
      if (!wrote_enable) {
        print "AutomaticLoginEnable=true"
        wrote_enable = 1
      }
      next
    }
    if ($0 ~ /^[#;]?[[:space:]]*AutomaticLogin[[:space:]]*=/) {
      if (!wrote_login) {
        print "AutomaticLogin=" target_user
        wrote_login = 1
      }
      next
    }
  }
  print
}
END {
  if (!seen_daemon) {
    print ""
    print "[daemon]"
    in_daemon = 1
  }
  if (in_daemon) {
    emit_daemon_settings()
  }
}
' "${GDM_CONF}" > "${tmp_gdm}"

install -m 0644 "${tmp_gdm}" "${GDM_CONF}"
rm -f "${tmp_gdm}"

printf '%s:%s\n' "${DESKTOP_USER}" "${LOGIN_PASSWORD}" | chpasswd

SUDOERS_FILE="/etc/sudoers.d/90-${DESKTOP_USER}-nopasswd"
tmp_sudoers="$(mktemp)"
printf '%s\n' "${DESKTOP_USER} ALL=(ALL:ALL) NOPASSWD:ALL" > "${tmp_sudoers}"
visudo -cf "${tmp_sudoers}" >/dev/null
install -m 0440 "${tmp_sudoers}" "${SUDOERS_FILE}"
rm -f "${tmp_sudoers}"

echo "[dev-desktop] Automatic login enabled for ${DESKTOP_USER}."
echo "[dev-desktop] Password updated for ${DESKTOP_USER}."
echo "[dev-desktop] Passwordless sudo enabled via ${SUDOERS_FILE}."
echo "[dev-desktop] GDM backup saved to ${backup_gdm}."
echo "[dev-desktop] Reboot is recommended for automatic login to take effect."
