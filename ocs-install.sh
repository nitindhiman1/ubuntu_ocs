#!/usr/bin/env bash
# ocs_full_auto.sh
# Full non-interactive OCS Inventory agent installer for Ubuntu 22.04 (Jammy)
# - installs prerequisites
# - installs cpanminus and required Perl modules (including Parse::EDID)
# - downloads CaCert and OCS tarball (uses your PXE/GitHub sources)
# - writes ocsinventory-agent.cfg (so installer does not prompt)
# - builds & installs agent (expect fallback if needed)
# - adds cron and triggers first inventory
#
# Run as root: sudo ./ocs_full_auto.sh
set -euo pipefail
IFS=$'\n\t'

LOG(){ printf '%s %s\n' "$(date '+%F %T')" "$*"; }

need_root(){ [[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0"; exit 2; } }

# -------- CONFIG (edit if necessary) --------
WORKDIR="/opt"
OCS_TAR_URL_PXE="http://pxe.infoedge.com/Ocsinventory-Unix-Agent-2.10.5.tar.gz"
#OCS_TAR_URL_GITHUB="https://github.com/Ramprakashp9/OCS/raw/main/Ocsinventory-Unix-Agent-2.4.2.tar.gz"
OCS_TAR_URL_GITHUB="https://github.com/OCSInventory-NG/UnixAgent/releases/download/v2.10.5/Ocsinventory-Unix-Agent-2.10.5.tar.gz"
CACERT_URL_PXE="http://pxe.infoedge.com/CaCert.pem"
OCS_SERVER="https://itam.infoedge.com/ocsinventory"
ADMIN_TAG="ubuntu"
CRON_ENTRY="0,30 * * * * /usr/local/bin/ocsinventory-agent"
PERL_MODULES=(Parse::EDID Module::Install Digest::MD5 XML::Simple Net::IP Proc::Daemon Proc::PID::File Compress::Zlib Crypt::SSLeay LWP::Protocol::https Net::CUPS Net::SNMP Net::Netmask Net::Ping Nmap::Parser Data::UUID)
# --------------------------------------------

need_root
LOG "Starting OCS full automated installer"

# try to ensure correct time (helps apt)
timedatectl set-ntp true >/dev/null 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

LOG "Updating apt lists"
apt-get update -y
apt-get install -y build-essential gcc make

LOG "Install base packages (tolerant to missing names)"
apt-get -y install --no-install-recommends wget curl ca-certificates build-essential make perl dpkg-dev \
  git tzdata cron expect apt-transport-https software-properties-common || true

LOG "Install OCS dependencies (tolerant)"
apt-get -y install --no-install-recommends libssl-dev nmap pciutils dmidecode ipmitool rpcbind man-db \
  libdbd-mysql-perl libnet-ip-perl libxml-simple-perl php php-mbstring php-soap php-mysql php-curl php-xml php-zip php-pclzip libtirpc-common || true

# fix broken installs if any
apt-get -y -f install || true

LOG "Ensure cpanminus (cpanm) available"
if ! command -v cpanm >/dev/null 2>&1; then
  apt-get -y install --no-install-recommends cpanminus || {
    # fallback to CPAN install
    yes "" | cpan -i App::cpanminus || true
  }
fi

LOG "Install Perl modules (cpanm -n for noninteractive)"
for mod in "${PERL_MODULES[@]}"; do
  LOG "Installing Perl module: $mod"
  if command -v cpanm >/dev/null 2>&1; then
    cpanm -n "$mod" || LOG "cpanm failed for $mod; continuing"
  else
    printf "\n" | cpan -i "$mod" || LOG "cpan -i failed for $mod; continuing"
  fi
done

# prepare workspace
mkdir -p "$WORKDIR"
pushd "$WORKDIR" >/dev/null

OCS_TAR_LOCAL="${WORKDIR}/$(basename "$OCS_TAR_URL_PXE")"
CACERT_LOCAL="${WORKDIR}/$(basename "$CACERT_URL_PXE")"

# download CaCert (PXE preferred) and OCS tarball
LOG "Downloading CaCert"
if ! command -v wget >/dev/null 2>&1; then apt-get -y install wget || true; fi
if ! wget -q --show-progress -O "$CACERT_LOCAL" "$CACERT_URL_PXE"; then
  LOG "PXE CaCert not reachable; attempting GitHub raw (no guarantee)"
  wget -q --show-progress -O "$CACERT_LOCAL" "https://raw.githubusercontent.com/Ramprakashp9/OCS/main/CaCert.pem" || LOG "Failed to download CaCert (continue)"
fi

LOG "Downloading OCS tarball"
if ! wget -q --show-progress -O "$OCS_TAR_LOCAL" "$OCS_TAR_URL_PXE"; then
  LOG "PXE tarball not reachable; trying GitHub"
  wget -q --show-progress -O "$OCS_TAR_LOCAL" "$OCS_TAR_URL_GITHUB" || { LOG "Failed to download OCS tarball"; popd >/dev/null; exit 1; }
fi

chmod 644 "$CACERT_LOCAL" || true

# Create configuration BEFORE running make install to avoid interactive prompts
CFG_DIR="/etc/ocsinventory-agent"
CFG_PATH="${CFG_DIR}/ocsinventory-agent.cfg"
LOG "Preparing non-interactive config at $CFG_PATH"
mkdir -p "$CFG_DIR"
cat > "$CFG_PATH" <<EOF
# Auto-generated ocsinventory config
server=$OCS_SERVER
ca=/opt/$(basename "$CACERT_LOCAL")
logfile=/var/log/ocs.log
debug=1
use_software_deployment=1
use_snmp=1
send_inventory=1
tag=$ADMIN_TAG
EOF
chmod 0644 "$CFG_PATH" || true

# Extract and build
TMPDIR="$(mktemp -d /tmp/ocsbuild.XXXXXX)"
LOG "Extracting OCS to $TMPDIR"
tar -xzf "$OCS_TAR_LOCAL" -C "$TMPDIR"
OCS_DIR="$(find "$TMPDIR" -maxdepth 2 -type d -name 'Ocsinventory-Unix-Agent*' -print -quit || true)"
if [[ -z "$OCS_DIR" ]]; then
  LOG "ERROR: OCS extracted directory not found"; popd >/dev/null; exit 1
fi
LOG "OCS source: $OCS_DIR"
pushd "$OCS_DIR" >/dev/null

# ensure non-interactive Makefile.PL
export PERL_MM_USE_DEFAULT=1
LOG "Running perl Makefile.PL"
perl Makefile.PL || LOG "perl Makefile.PL returned non-zero (continuing)"

LOG "Running make"
make || LOG "make returned non-zero (continuing)"

LOG "Attempting make install (non-interactive). If it prompts, fallback to expect wrapper."
set +e
make install
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  LOG "make install returned $RC; using expect fallback to answer prompts"
  # create expect wrapper
  EXPECT_WRAPPER="$(mktemp /tmp/ocs_expect_wrapper.XXXXXX)"
  EXPECT_LOG="/tmp/ocs_expect.log"
  cat > "$EXPECT_WRAPPER" <<'EXPECT_EOF'
#!/usr/bin/env expect
log_file -noappend /tmp/ocs_expect.log
set timeout 1800
spawn make install

proc multi_reply {patterns answer} {
  set plist [split $patterns "||"]
  expect {
    -re [lindex $plist 0] { send -- "$answer\r"; exp_continue }
    -re [lindex $plist 1] { send -- "$answer\r"; exp_continue }
    -re [lindex $plist 2] { send -- "$answer\r"; exp_continue }
    -re {Value must be between 0 and 2} { send -- "1\r"; exp_continue }
    -re {\?>} { send -- "$answer\r"; exp_continue }
    timeout { puts "TIMEOUT waiting for $patterns"; exit 2 }
    eof {}
  }
}

# sequence approximating installer prompts
multi_reply {would you like to configure as much as possible automatically\?|Do you want to configure.*automatically\?||Do you want to configure the agent} "y"
multi_reply {Where do you want to write the configuration file.*0.*1.*2.*\?>||Where do you want to write the configuration file\?||\?>} "1"
multi_reply {Do you want to create the directory.*\?|Do you want to create the directory /etc/ocsinventory-agent\?} "y"
multi_reply {Should the old unix_agent settings be imported.*\?|Should the old unix_agent settings be imported \?} "n"
expect {
  -re {The config file will be written.*press Enter|press Enter} {
    send "\r"
    exp_continue
  }
  timeout {}
  eof {}
}
multi_reply {What is the address of your ocs server\?|Enter.*server address} "$env(OCS_SERVER)"
multi_reply {Do you need credential for the server.*\?|Do you need credentials.*\?} "n"
multi_reply {Do you want to apply an administrative tag.*\?|Do you want to apply.*tag.*\?} "y"
multi_reply {tag\?>|tag\?|Enter tag} "ubuntu"
multi_reply {Do yo.?u? want to install the cron task.*\?|Do you want to install the cron task in /etc/cron.d.*\?} "y"
expect {
  -re {Where do you want the agent to store its files.*\?>|Where do you want the agent to store its files\?} {
    send "\r"
    exp_continue
  }
  timeout {}
  eof {}
}
multi_reply {Do you want to create the .*var/lib/ocsinventory-agent.*\?|Do you want to create the /var/lib/ocsinventory-agent.*\?} "y"
multi_reply {Should I remove the old unix_agent.*\?|Should I remove the old unix_agent\?} "y"
multi_reply {Do you want to activate debug.*\?|Do you want to activate debug configuration option.*\?} "y"
multi_reply {Do you want to use OCS Inventory NG Unix Unified agent log file.*\?|Use OCS-Inventory.*log file.*\?} "y"
multi_reply {Specify log file path you want to use\?>|Specify log file path} "/var/log/ocs.log"
multi_reply {Do you want disable SSL CA verification.*\?|Disable SSL CA verification.*\?} "y"
multi_reply {Do you want to set CA certificate chain file path.*\?|Set CA certificate chain.*\?} "y"
multi_reply {Specify CA certificate chain file path\?>|CA certificate chain file path\?>} "/opt/$(basename \"$CACERT_LOCAL\")"
multi_reply {Do you want to use OCS-Inventory software deployment feature.*\?} "y"
multi_reply {Do you want to use OCS-Inventory SNMP scans feature.*\?} "y"
multi_reply {Do you want to send an inventory of this machine.*\?} "y"

expect {
  -re {New settings written|Thank you for using OCS Inventory|-> Success!|Success!} {
    send_user "Installer finished\n"
  }
  eof {
    send_user "make install finished (EOF)\n"
  }
  timeout {
    send_user "Expect timed out waiting for final message\n"
    exit 2
  }
}
EXPECT_EOF

  chmod +x "$EXPECT_WRAPPER"
  if ! command -v expect >/dev/null 2>&1; then
    apt-get -y install --no-install-recommends expect || true
  fi
  /usr/bin/expect -f "$EXPECT_WRAPPER" || LOG "Expect wrapper returned non-zero; check /tmp/ocs_expect.log"
  rm -f "$EXPECT_WRAPPER"
fi

popd >/dev/null || true
rm -rf "$TMPDIR" || true
popd >/dev/null || true

# fix dpkg/apt if necessary
apt-get -y -f install || true

# Ensure CA placed under /opt and correct perms
if [[ -f "$CACERT_LOCAL" ]]; then
  cp -f "$CACERT_LOCAL" /opt/$(basename "$CACERT_LOCAL") || true
  chmod 0644 /opt/$(basename "$CACERT_LOCAL") || true
fi

# Ensure config contains ca and server lines
if [[ -f "$CFG_PATH" ]]; then
  sed -i '/^ca=/d' "$CFG_PATH" || true
  sed -i '/^server=/d' "$CFG_PATH" || true
  echo "ca=/opt/$(basename "$CACERT_LOCAL")" >> "$CFG_PATH"
  echo "server=$OCS_SERVER" >> "$CFG_PATH"
  echo "tag=$ADMIN_TAG" >> "$CFG_PATH"
fi

# Ensure log exists
mkdir -p /var/log
touch /var/log/ocs.log || true
chmod 0644 /var/log/ocs.log || true

# Add cron for root (avoid duplicates)
OCS_BIN="$(command -v ocsinventory-agent || echo /usr/local/bin/ocsinventory-agent)"
( crontab -l 2>/dev/null | grep -v -F "$OCS_BIN" || true ; echo "$CRON_ENTRY" ) | crontab -

LOG "Triggering first inventory run (debug)"
if command -v ocsinventory-agent >/dev/null 2>&1; then
  ocsinventory-agent --debug --force || LOG "ocsinventory-agent returned non-zero (check /var/log/ocs.log)"
else
  LOG "ocsinventory-agent not found - installation may have failed"
fi

LOG "OCS install script finished. Check /var/log/ocs.log and /tmp/ocs_expect.log (if present) for details."
exit 0

