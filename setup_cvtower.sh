#!/usr/bin/env bash
# Drop Ceiling V2: first setup of the tower, straight after a clean Ubuntu 24.04 Desktop install.
# Run it at the tower, signed in as nick, connected to the wifi. Safe to run again.
#
#   wget https://raw.githubusercontent.com/npuckett/setupLinuxBox1/main/setup_cvtower.sh
#   bash setup_cvtower.sh
#
# It updates the system, installs SSH, Tailscale and the NVIDIA driver, and stops the machine sleeping, so it can be reached
# from elsewhere. It holds no secrets. You type your password once for sudo, and sign in to Tailscale from the link it prints.
#
# It leaves out what V1's linux_cv_setup.sh added: remote desktop (too slow over wifi), and software this machine no
# longer runs from a desktop. Python, torch and the rest come later, over SSH, and so do the firewall and SSH lock-down.
#
# Exit 0: all done. Exit 2: reboot, then run it again. Exit 1: something failed, and the report says what.
set -uo pipefail

EXPECT_HOST=cvtower
EXPECT_USER=nick
OS_RELEASE=${DC_OS_RELEASE:-/etc/os-release}
LOG="$HOME/setup_cvtower.log"

exec > >(tee -a "$LOG") 2>&1

FAILED=0
REBOOT=0
REPORT=""
say() { printf '\n== %s\n' "$*"; }
pass() { REPORT="$REPORT  ok      $*"$'\n'; }
warn() { REPORT="$REPORT  CHECK   $*"$'\n'; }
need_reboot() { REPORT="$REPORT  REBOOT  $*"$'\n'; REBOOT=1; }
fail() { REPORT="$REPORT  FAILED  $*"$'\n'; FAILED=1; }
refuse() { printf 'STOPPED: %s\n' "$*"; exit 1; }

say "Checking this is the right machine"
grep -q 'VERSION_ID="24.04"' "$OS_RELEASE" || refuse "this expects Ubuntu 24.04, and $OS_RELEASE says otherwise. Nothing was changed."
[ "$(id -u)" != 0 ] || refuse "run it as $EXPECT_USER, not with sudo. It asks for your password itself. Nothing was changed."
[ "$(hostname)" = "$EXPECT_HOST" ] || refuse "this computer is called $(hostname), and the ops scripts expect $EXPECT_HOST. Nothing was changed."
[ "$(id -un)" = "$EXPECT_USER" ] || refuse "you are signed in as $(id -un), and the ops scripts expect $EXPECT_USER. Nothing was changed."
# A clean install may have no curl yet, and this script is what installs it.
online() {
  if command -v curl >/dev/null 2>&1; then curl -fsS --max-time 20 -o /dev/null https://tailscale.com/
  elif command -v wget >/dev/null 2>&1; then wget -q --spider --timeout=20 https://tailscale.com/
  else getent hosts tailscale.com >/dev/null
  fi
}
online || refuse "no internet from here. Connect to the wifi, then run it again. Nothing was changed."

sudo -v || refuse "sudo did not accept the password. Nothing was changed."
# Updates can outlast sudo's 15 minutes, so keep it alive until this script ends.
( while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 60; done ) >/dev/null 2>&1 </dev/null &
KEEPALIVE=$!
trap 'kill "$KEEPALIVE" 2>/dev/null' EXIT

# A fresh install is often running its own updates, so wait for the lock, and never stop to ask about a config file.
apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold "$@"; }

say "Updating the system. This can take a while"
if ! apt_get update --error-on=any; then
  echo
  echo "STOPPED: apt could not read Ubuntu's package servers, so nothing can be installed. The error is above."
  echo "  Release file not valid yet, or a certificate error: the clock is wrong. Set the date and time, then run this again."
  echo "  Could not resolve, or timed out: the wifi isn't really online, or it has a login page. Open a browser and check."
  echo "  500, 503 or 404 from a server: that mirror is having trouble. Wait a few minutes, or use the main server with:"
  echo "    sudo sed -i -E 's#https?://[a-z0-9.-]*archive[.]ubuntu[.]com#http://archive.ubuntu.com#' /etc/apt/sources.list.d/ubuntu.sources"
  exit 1
fi
if apt_get -y full-upgrade; then pass "system updated"; else fail "system update. Run it again, and look in $LOG if it repeats"; fi

say "Installing the basics"
if apt_get -y install openssh-server curl git jq mokutil ubuntu-drivers-common; then pass "SSH, curl, git, jq installed"; else fail "basic packages"; fi
if systemctl is-active --quiet ssh.socket || systemctl is-active --quiet ssh; then pass "SSH is listening"
elif sudo systemctl enable --now ssh; then pass "SSH started"
else fail "SSH did not start"; fi

say "Stopping the machine from ever sleeping"
# The same files as ops/bootstrap/tower_bootstrap.sh step 5, and a test holds them equal. A sleeping tower can't be reached.
sudo install -d /etc/systemd/sleep.conf.d /etc/systemd/logind.conf.d
printf '[Sleep]\nAllowSuspend=no\nAllowHibernation=no\nAllowSuspendThenHibernate=no\nAllowHybridSleep=no\n' | sudo tee /etc/systemd/sleep.conf.d/50-dc-never.conf >/dev/null
printf '[Login]\nIdleAction=ignore\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\nHandleLidSwitch=ignore\n' | sudo tee /etc/systemd/logind.conf.d/50-dc-never.conf >/dev/null
if sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; then pass "sleep is off"; else fail "could not turn sleep off"; fi

say "NVIDIA driver"
if [ "$(mokutil --sb-state 2>/dev/null | grep -c enabled)" != 0 ]; then
  warn "Secure Boot is on, which can stop the NVIDIA driver loading. Turn it off in the BIOS"
fi
if nvidia-smi -L >/dev/null 2>&1; then
  pass "NVIDIA driver running: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"
elif dpkg -l 'nvidia-driver-*' 2>/dev/null | grep -q '^ii'; then
  need_reboot "NVIDIA driver is installed but not running. If it still says this after a reboot, check Secure Boot"
elif sudo ubuntu-drivers install; then
  need_reboot "NVIDIA driver just installed"
else
  fail "NVIDIA driver did not install"
fi

say "Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh || fail "Tailscale did not install"
fi
if command -v tailscale >/dev/null 2>&1; then
  if ! tailscale status >/dev/null 2>&1; then
    echo "Open the link below in a browser and sign in, using the same account as the Mac. This waits until you have."
    sudo tailscale up || fail "Tailscale sign-in did not finish. Run this again"
  fi
  NAME=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | cut -d. -f1)
  if [ "$NAME" = "$EXPECT_HOST" ]; then
    pass "Tailscale is up as $NAME"
    warn "In the Tailscale admin console, choose Disable key expiry for $NAME"
  elif [ -n "$NAME" ]; then
    fail "Tailscale calls this machine $NAME. Remove the old $EXPECT_HOST from the admin console, then run: sudo tailscale up --force-reauth --hostname=$EXPECT_HOST"
  fi
fi

say "Wifi"
WIFI=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep ':802-11-wireless$' | head -1 | sed 's/:802-11-wireless$//')
if [ -z "$WIFI" ]; then
  warn "No active wifi connection, so check it reconnects by itself if the tower is meant to use wifi"
else
  PERMS=$(nmcli -g connection.permissions connection show "$WIFI" 2>/dev/null)
  AUTO=$(nmcli -g connection.autoconnect connection show "$WIFI" 2>/dev/null)
  if [ -z "$PERMS" ] && [ "$AUTO" = yes ]; then
    pass "Wifi reconnects by itself, with nobody signed in"
  else
    warn "In wifi settings, tick Connect automatically and All Users May Connect, or it won't come back after a power cut"
  fi
fi

say "Report"
printf '%s' "$REPORT"
warn_bios="Set Restore on AC power loss to Power On in the BIOS, if you haven't. No script can do this"
printf '  CHECK   %s\n' "$warn_bios"
echo
echo "Full log: $LOG"
if [ "$FAILED" = 1 ]; then
  echo "Something failed. Fix what the report says, then run this again."
  exit 1
fi
if [ "$REBOOT" = 1 ]; then
  echo "Now run: sudo reboot"
  echo "Then sign in and run this script again, to confirm."
  exit 2
fi
echo "All done. Next: pull the plug and restore it to confirm the tower comes back by itself, then go to the Mac."
exit 0
