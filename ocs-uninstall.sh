#!/usr/bin/env bash
# ocs_uninstall.sh
# بالكامل removes OCS Inventory Agent and related configs

set -euo pipefail

LOG(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

need_root(){
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0"; exit 2; }
}

need_root
LOG "Starting OCS agent uninstall"

# Stop any running agent processes
LOG "Stopping running OCS processes (if any)"
pkill -f ocsinventory-agent || true

# Remove cron jobs
LOG "Removing cron entries"
crontab -l 2>/dev/null | grep -v 'ocsinventory-agent' | crontab - || true
rm -f /etc/cron.d/ocsinventory-agent || true

# Remove installed binaries
LOG "Removing binaries"
rm -f /usr/local/bin/ocsinventory-agent || true
rm -f /usr/bin/ocsinventory-agent || true

# Remove Perl modules installed via make install (best effort)
LOG "Attempting to remove installed Perl modules (best effort)"
rm -rf /usr/local/share/perl/*/Ocsinventory || true
rm -rf /usr/local/lib/*/perl/*/Ocsinventory || true

# Remove configuration and data
LOG "Removing configuration and data"
rm -rf /etc/ocsinventory-agent || true
rm -rf /var/lib/ocsinventory-agent || true
rm -rf /etc/ocsinventory || true

# Remove logs
LOG "Removing logs"
rm -f /var/log/ocs.log || true

# Remove CA cert (from your script location)
LOG "Removing CA certificate"
rm -f /opt/CaCert.pem || true

# Remove leftover build/install artifacts
LOG "Cleaning temporary/build files"
rm -rf /tmp/ocsbuild.* || true
rm -f /tmp/ocs_expect.log || true

# Optional: remove Perl modules installed via cpanm (not always safe globally)
# Uncomment ONLY if you are sure these are not used elsewhere
# cpanm --uninstall Parse::EDID Module::Install Digest::MD5 XML::Simple Net::IP Proc::Daemon Proc::PID::File Compress::Zlib Crypt::SSLeay LWP::Protocol::https Net::CUPS Net::SNMP Net::Netmask Net::Ping Nmap::Parser Data::UUID || true

LOG "OCS agent removal complete"

echo "NOTE:"
echo "- Some Perl dependencies may remain if shared with other apps"
echo "- Verify removal: which ocsinventory-agent"

