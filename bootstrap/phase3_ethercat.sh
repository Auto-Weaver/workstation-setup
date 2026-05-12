#!/usr/bin/env bash

# Source-build IgH EtherCAT master 1.5.3 and turn the chosen NIC into the
# dedicated EtherCAT bus device on this host. Mirrors the exact configure
# flags that produced a working master on the pluck-hair-machine on
# 2026-04-15 (see logs at /home/pluck-hair/logs/igh-disable-eoe-*).
#
# Running this script declares: "from now on, the --nic interface is the
# EtherCAT bus, not a TCP/IP interface." It will be claimed by the IgH
# generic driver at every boot via the enabled ethercat.service.

set -euo pipefail

IGH_VERSION="1.5.3"
IGH_TARBALL_URL="https://gitlab.com/etherlab.org/ethercat/-/archive/${IGH_VERSION}/ethercat-${IGH_VERSION}.tar.gz"
WORK_DIR="/tmp/igh-build-${IGH_VERSION}"

NIC=""

usage() {
  cat >&2 <<EOF
Usage: sudo bash phase3_ethercat.sh --nic <interface>

  --nic <interface>   The Ethernet interface that will become the dedicated
                      EtherCAT bus device (e.g. eno1, eno2, enp15s0). This
                      NIC will be claimed by the IgH generic driver at boot
                      time and will no longer carry TCP/IP traffic.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nic)
      NIC="${2:-}"
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
  echo "Please run as root: sudo bash phase3_ethercat.sh --nic <interface>" >&2
  exit 1
fi

if [[ -z "${NIC}" ]]; then
  echo "Missing --nic argument." >&2
  usage
  exit 1
fi

if [[ ! -d "/sys/class/net/${NIC}" ]]; then
  echo "Interface ${NIC} not found on this host." >&2
  echo "Available interfaces:" >&2
  ls /sys/class/net/ >&2
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

KERNEL_VERSION="$(uname -r)"
KDIR="/lib/modules/${KERNEL_VERSION}/build"

echo "[phase3] Target NIC:        ${NIC}"
echo "[phase3] IgH version:       ${IGH_VERSION}"
echo "[phase3] Kernel:            ${KERNEL_VERSION}"
echo "[phase3] Kernel build dir:  ${KDIR}"
echo

echo "[phase3] Installing build dependencies..."
apt-get update
apt-get install -y \
  build-essential \
  autoconf \
  automake \
  libtool \
  pkg-config \
  curl \
  ca-certificates \
  "linux-headers-${KERNEL_VERSION}"

if [[ ! -d "${KDIR}" ]]; then
  echo "Kernel build dir ${KDIR} not found even after installing headers." >&2
  echo "linux-headers-${KERNEL_VERSION} may not be available for this kernel." >&2
  exit 1
fi

echo "[phase3] Stopping any running ethercat service before reinstall..."
systemctl stop ethercat.service 2>/dev/null || true

# Idempotent cleanup of any previous IgH install. We don't trust `make
# uninstall` from a possibly-different source tree — the previous build dir
# in /tmp is gone, and a stale install can shadow the new one through PATH
# or linker cache. Remove every file IgH 1.5.3 puts on disk by hand, then
# rebuild fresh below. /etc/ethercat.conf and udev rules are NOT removed
# here — they're rewritten unconditionally further down.
echo "[phase3] Removing previous IgH install (if any)..."
for mod in ec_master ec_generic; do
  if lsmod | grep -q "^${mod} "; then
    rmmod "${mod}" 2>/dev/null || true
  fi
done

# Kernel modules from old installs (any kernel version, not just current)
find /lib/modules -maxdepth 3 -type d -name ethercat -exec rm -rf {} + 2>/dev/null || true

# Userland binaries + libs + headers
rm -f \
  /usr/local/bin/ethercat \
  /usr/local/sbin/ethercatctl \
  /usr/local/include/ecrt.h \
  /usr/local/include/ectty.h \
  /usr/local/lib/libethercat.a \
  /usr/local/lib/libethercat.la \
  /usr/local/lib/libethercat.so \
  /usr/local/lib/libethercat.so.1 \
  /usr/local/lib/libethercat.so.1.2.0 \
  /usr/local/share/bash-completion/completions/ethercat \
  /usr/lib/systemd/system/ethercat.service \
  /etc/init.d/ethercat \
  /etc/sysconfig/ethercat

systemctl daemon-reload

echo "[phase3] Fetching IgH ${IGH_VERSION} tarball..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
curl -fL --retry 3 --connect-timeout 10 --max-time 300 \
  -o "ethercat-${IGH_VERSION}.tar.gz" \
  "${IGH_TARBALL_URL}"
tar -xf "ethercat-${IGH_VERSION}.tar.gz"
SRC_DIR="${WORK_DIR}/ethercat-${IGH_VERSION}"
cd "${SRC_DIR}"

# Auto-tools bootstrap. IgH gitlab archive doesn't ship a pre-generated
# configure script (only the autotools sources).
if [[ ! -x ./configure ]]; then
  echo "[phase3] Running autoreconf to generate configure..."
  autoreconf -i
fi

# Configure flags are taken verbatim from the working 2026-04-15 build on
# pluck-hair-machine. Rationale:
#   --disable-eoe       avoid EoE kernel-thread crash on PREEMPT_RT
#   --enable-generic    use generic Ethernet driver (works with any NIC)
#   --disable-{8139too,e100,e1000,e1000e,igb,r8169}
#                       don't build native EtherCAT drivers; we use generic
#   --enable-sii-assign enable SII override (needed for some Beckhoff/Epson slaves)
#   --enable-hrtimer    use hrtimer for cyclic operations
#   --prefix=/usr/local --sysconfdir=/etc
#                       match the layout the existing install expects
echo "[phase3] Configuring..."
./configure \
  --disable-eoe \
  --enable-generic \
  --disable-8139too \
  --disable-e100 \
  --disable-e1000 \
  --disable-e1000e \
  --disable-igb \
  --disable-r8169 \
  --enable-sii-assign \
  --enable-hrtimer \
  --prefix=/usr/local \
  --sysconfdir=/etc \
  --with-linux-dir="${KDIR}"

echo "[phase3] Building userland + modules..."
make -j"$(nproc)"
make modules

echo "[phase3] Installing..."
make install
make modules_install
depmod -a
ldconfig

echo "[phase3] Writing /etc/ethercat.conf (NIC=${NIC})..."
# Backup whatever was there before, then write a minimal config. The
# upstream conf file has 60 lines of comments; we keep only the live values
# since the source layout under /etc + the script itself document the why.
if [[ -f /etc/ethercat.conf ]]; then
  cp -a /etc/ethercat.conf "/etc/ethercat.conf.bak-$(date +%Y%m%d-%H%M%S)"
fi
cat >/etc/ethercat.conf <<EOF
# Managed by workstation-setup/bootstrap/phase3_ethercat.sh.
# NIC ${NIC} is the dedicated EtherCAT bus device on this host.
MASTER0_DEVICE="${NIC}"
DEVICE_MODULES="generic"
EOF

echo "[phase3] Writing /etc/udev/rules.d/99-ethercat.rules..."
cat >/etc/udev/rules.d/99-ethercat.rules <<'EOF'
KERNEL=="EtherCAT[0-9]*", MODE="0666"
EOF
udevadm control --reload-rules

echo "[phase3] Enabling + starting ethercat.service..."
systemctl daemon-reload
systemctl enable ethercat.service
systemctl start ethercat.service

# IgH service is Type=oneshot RemainAfterExit=yes — "active (exited)" is the
# success state, not a failure.
sleep 2

echo
echo "[phase3] === verification ==="
echo "--- systemctl status ---"
systemctl status ethercat.service --no-pager | head -10 || true
echo
echo "--- /dev/EtherCAT0 ---"
ls -la /dev/EtherCAT0 2>&1 || true
echo
echo "--- loaded modules ---"
lsmod | grep -E "^ec_" || echo "(no ec_ modules loaded — FAILURE)"
echo
echo "--- ethercat master ---"
/usr/local/bin/ethercat master 2>&1 | head -20 || true
echo
echo "--- ethercat slaves ---"
/usr/local/bin/ethercat slaves 2>&1 || true

echo
echo "[phase3] Done. ${NIC} is now the EtherCAT bus device."
echo "[phase3] If 'ethercat slaves' is empty, check that the cable is in the"
echo "[phase3] slave's ECAT-IN port and the slave is powered on."
