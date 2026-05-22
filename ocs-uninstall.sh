#!/usr/bin/env bash
# ocs_uninstall.sh
# Complete OCS Inventory Agent Removal Script

set -euo pipefail

LOG(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

need_root(){
  [[ "$(id -u)" -eq 0 ]] || {
    echo "Run as root: sudo $0"
    exit 2
  }
}

need_root

LOG "Starting OCS agent uninstall"

# Stop running processes
LOG "Stopping OCS processes"
pkill -f ocsinventory-agent || true

# Remove cron jobs
LOG "Removing cron jobs"
crontab -l 2>/dev/null | grep -v 'ocsinventory-agent' | crontab - || true

rm -f /etc/cron.d/ocsinventory-agent || true
rm -f /etc/cron.daily/ocsinventory-agent || true

# Remove binaries
LOG "Removing binaries"

rm -f /usr/local/bin/ocsinventory-agent || true
rm -f /usr/bin/ocsinventory-agent || true
rm -f /usr/sbin/ocsinventory-agent || true

# Remove Perl libraries/modules
LOG "Removing Perl modules"

rm -rf /usr/local/share/perl/*/Ocsinventory || true
rm -rf /usr/local/lib/*/perl/*/Ocsinventory || true
rm -rf /usr/share/perl5/Ocsinventory || true

# Remove configuration files
LOG "Removing configuration files"

rm -rf /etc/ocsinventory-agent || true
rm -rf /etc/ocsinventory || true

rm -f /etc/ocsinventory/ocsinventory-agent.cfg || true
rm -f /etc/ocsinventory-agent/ocsinventory-agent.cfg || true
rm -f /usr/local/etc/ocsinventory-agent.cfg || true

# Remove any leftover configs
find /etc -type f -name "*ocsinventory*" -exec rm -f {} \; 2>/dev/null || true
find /usr/local/etc -type f -name "*ocsinventory*" -exec rm -f {} \; 2>/dev/null || true

# Remove data/cache/runtime
LOG "Removing data/cache"

rm -rf /var/lib/ocsinventory-agent || true
rm -rf /var/lib/ocsinventory-agent/* || true

rm -rf /tmp/ocs* || true
rm -rf /tmp/OCS* || true
rm -rf /var/tmp/ocs* || true

# Remove logs
LOG "Removing logs"

rm -f /var/log/ocs.log || true
rm -f /var/log/ocsinventory-agent.log || true

# Remove CA certificates
LOG "Removing certificates"

rm -f /opt/CaCert.pem || true

# Remove build/temp files
LOG "Removing temporary files"

rm -rf /tmp/ocsbuild.* || true
rm -f /tmp/ocs_expect.log || true

# Remove systemd leftovers
LOG "Removing systemd leftovers"

rm -f /etc/systemd/system/ocsinventory-agent.service || true
systemctl daemon-reload || true

# Final verification
LOG "Verification"

find /etc /usr/local/etc -name "*ocsinventory*" 2>/dev/null || true
which ocsinventory-agent || true

LOG "OCS agent removal completed successfully"

echo ""
echo "=============================================="
echo "OCS Agent Completely Removed"
echo "Recommended: Reboot system before reinstall"
echo "=============================================="
echo ""
