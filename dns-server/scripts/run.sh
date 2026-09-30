#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
trap 'code=$?; printf "ERROR: line %s failed (exit %s).\n" "$LINENO" "$code" >&2; exit "$code"' ERR

APP=/opt/AdGuardHome
SERVICE=AdGuardHome
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n== %s ==\n' "$*"; }

require_install() {
    [[ -f $APP/.managed-dns-server ]] || fail 'This is not an installation managed by dns-server/; inspect it before making changes.'
    [[ -x $APP/AdGuardHome && -s $APP/AdGuardHome.yaml ]] || fail 'AdGuard Home is incomplete. Run Setup first.'
}

check_identity() {
    [[ $(hostname -s) == "$PI_HOSTNAME" ]] || fail "Expected hostname $PI_HOSTNAME; check the SSH alias and local.json."
    local addresses
    addresses=$(ip -o -4 address show dev "$PI_INTERFACE")
    awk '{print $4}' <<< "$addresses" | grep -Fxq "$PI_CIDR" ||
        fail "Expected $PI_CIDR on $PI_INTERFACE. Fix the reservation/config first."
    [[ -f /usr/share/zoneinfo/$PI_TIMEZONE ]] || fail "Unknown timezone: $PI_TIMEZONE"
}

backup() (
    local mode=$1 restart=false
    # Restore the previous service state even if archiving fails; never hide the error.
    trap 'code=$?; if [[ $restart == true ]]; then systemctl start "$SERVICE" || code=1; fi; exit "$code"' EXIT
    if [[ $mode == backup-if-installed && ! -s $APP/AdGuardHome.yaml ]]; then
        if [[ -d $APP && ! -f $APP/.managed-dns-server ]]; then
            fail 'Unmanaged /opt/AdGuardHome exists; refusing to overwrite it.'
        fi
        printf 'absent\n' > "$STAGE/backup-state"
        log 'No initialized AdGuard Home configuration to back up'
    else
        require_install
        log 'Backing up AdGuard Home (brief DNS pause for a consistent copy)'
        if systemctl is-active --quiet "$SERVICE"; then
            restart=true
            systemctl stop "$SERVICE"
        fi
        python3 "$STAGE/adguard.py" backup "$APP" "$STAGE/backup.zip"
        if [[ $restart == true ]]; then systemctl start "$SERVICE"; restart=false; fi
        chown "$SUDO_UID:$SUDO_GID" "$STAGE/backup.zip"
        chmod 600 "$STAGE/backup.zip"
        printf 'ready\n' > "$STAGE/backup-state"
    fi
    chown "$SUDO_UID:$SUDO_GID" "$STAGE/backup-state"
    chmod 600 "$STAGE/backup-state"
)

apt_update() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update </dev/null
    apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold -y upgrade </dev/null
}

download_adguard() (
    local arch work
    # Root-owned scratch space: the SSH user must be able to delete $STAGE afterwards.
    work=$(mktemp -d)
    trap 'code=$?; rm -rf -- "$work"; exit "$code"' EXIT
    case "$(dpkg --print-architecture)" in
        arm64) arch=arm64 ;;
        armhf) case "$(uname -m)" in armv6*) arch=armv6 ;; *) arch=armv7 ;; esac ;;
        armel) arch=armv5 ;;
        *) fail 'Expected a Raspberry Pi ARM OS.' ;;
    esac
    log "Downloading official AdGuard Home release ($arch)"
    # Same HTTPS release endpoint as AdGuard's official installer. Download to
    # staging first, so interruption cannot replace an existing executable.
    curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 300 --retry 3 \
        "https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_${arch}.tar.gz" \
        -o "$work/release.tar.gz"
    tar -xzf "$work/release.tar.gz" --no-same-owner --no-same-permissions \
        -C "$work" ./AdGuardHome/AdGuardHome
    "$work/AdGuardHome/AdGuardHome" --version
    install -m 755 "$work/AdGuardHome/AdGuardHome" "$APP/AdGuardHome.new"
    mv -f "$APP/AdGuardHome.new" "$APP/AdGuardHome"
)

configure_adguard() (
    local restart=false
    trap 'code=$?; if [[ $restart == true ]]; then systemctl start "$SERVICE" || code=1; fi; exit "$code"' EXIT
    if systemctl is-active --quiet "$SERVICE"; then
        restart=true
        systemctl stop "$SERVICE"
    fi
    # Never edit YAML while AdGuard is running: it writes its configuration back.
    cp -p "$APP/AdGuardHome.yaml" "$STAGE/before.yaml"
    python3 "$STAGE/adguard.py" configure "$APP" "$PI_IPV4" "$UPSTREAMS" "$BOOTSTRAP_DNS" "$LAN_SUBNET"
    if ! "$APP/AdGuardHome" --check-config -c "$APP/AdGuardHome.yaml" -w "$APP"; then
        cp -p "$STAGE/before.yaml" "$APP/AdGuardHome.yaml"
        fail 'AdGuard rejected the configuration; the previous YAML has been restored.'
    fi
)

setup() {
    check_identity
    if systemctl is-active --quiet pihole-FTL; then
        fail 'Pi-hole is still running. Back it up and stop/disable it before switching DNS servers; see README.'
    fi
    if [[ -d $APP && ! -f $APP/.managed-dns-server ]]; then fail 'Refusing to overwrite unmanaged AdGuard Home.'; fi
    if [[ ! -s $APP/AdGuardHome.yaml ]]; then
        local listeners
        listeners=$(ss -H -lntu '( sport = :53 or sport = :3000 )')
        [[ -z $listeners ]] || fail 'Port 53 or 3000 is occupied; inspect sudo ss -lntup.'
    fi
    umask 022
    log 'Preparing Raspberry Pi OS'
    apt_update
    apt-get -o DPkg::Lock::Timeout=120 -y install ca-certificates curl dnsutils python3 python3-yaml </dev/null
    timedatectl set-timezone "$PI_TIMEZONE"
    install -d -m 700 "$APP"
    touch "$APP/.managed-dns-server"
    if [[ ! -x $APP/AdGuardHome ]]; then download_adguard; fi
    if [[ ! -s $APP/AdGuardHome.yaml ]]; then
        # The official setup API generates the current schema/defaults. It is
        # bound to loopback; the password is read on the terminal, never as an argument.
        python3 "$STAGE/adguard.py" initialize "$APP" "$PI_IPV4"
    fi
    require_install
    configure_adguard
    if [[ $(systemctl show "$SERVICE" -p LoadState --value) == not-found ]]; then
        "$APP/AdGuardHome" -s install -c "$APP/AdGuardHome.yaml" -w "$APP"
    fi
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    wait_for_dns
    wait_for_filters
    status
    log 'Admin UI: run ./dns-server/manage.ps1 Admin, then open http://127.0.0.1:3000'
}

dns_query() {
    local server=$1 transport=$2 answer
    answer=$(dig "@$server" "$DNS_TEST_NAME" A "$transport" +time=3 +tries=1 +noall +comments +answer) || return 1
    grep -q 'status: NOERROR' <<< "$answer" &&
        awk '$4 == "A" && $5 != "0.0.0.0" { found=1 } END { exit !found }' <<< "$answer"
}

wait_for_dns() {
    local attempt
    for attempt in {1..15}; do
        if dns_query 127.0.0.1 +notcp; then return 0; fi
        sleep 2
    done
    fail 'DNS did not become ready; inspect sudo journalctl -u AdGuardHome.'
}

wait_for_filters() {
    # AdGuard downloads filter lists asynchronously after (re)start.
    local attempt
    for attempt in {1..30}; do
        if python3 "$STAGE/adguard.py" health "$APP" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    # Not fatal here; status reports the concrete problem.
}

status() {
    require_install
    local failed=0 output usage server transport flag
    log 'AdGuard Home and DNS health'
    "$APP/AdGuardHome" --version
    if ! systemctl is-active "$SERVICE"; then failed=1; fi
    if ! systemctl is-enabled "$SERVICE"; then failed=1; fi
    for server in 127.0.0.1 "$PI_IPV4"; do
        for transport in +notcp +tcp; do
            if dns_query "$server" "$transport"; then
                printf 'OK: DNS %s %s (%s)\n' "$server" "$transport" "$DNS_TEST_NAME"
            else
                printf 'FAIL: DNS %s %s (%s)\n' "$server" "$transport" "$DNS_TEST_NAME"; failed=1
            fi
        done
    done
    if ! curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3000/login.html >/dev/null; then failed=1; fi
    if ! python3 "$STAGE/adguard.py" health "$APP"; then failed=1; fi
    log 'System health'
    uptime
    free -h
    df -h / "$APP"
    df -i / "$APP"
    for flag in -P -Pi; do
        usage=$(df "$flag" / "$APP" | awk 'NR > 1 { gsub(/%/, "", $5); if ($5 >= 90) print $5 }')
        if [[ -n $usage ]]; then printf 'FAIL: Disk/inode usage >=90%%.\n'; failed=1; fi
    done
    output=$(systemctl --failed --no-legend --plain)
    if [[ -n $output ]]; then printf 'FAIL: Failed systemd units:\n%s\n' "$output"; failed=1; fi
    if command -v vcgencmd >/dev/null; then vcgencmd measure_temp; vcgencmd get_throttled; fi
    printf 'Running kernel: %s\n' "$(uname -r)"
    if [[ -f /var/run/reboot-required ]]; then
        printf 'REBOOT REQUIRED: in WSL, schedule ssh -t roka-dns-server "sudo reboot"\n'
    else
        printf 'No reboot marker. Pi OS may not create one; review kernel/firmware updates manually.\n'
    fi
    return "$failed"
}

update_adguard() {
    "$APP/AdGuardHome" --update -c "$APP/AdGuardHome.yaml" -w "$APP" </dev/null
}

maintain() {
    require_install
    check_identity
    umask 022
    log 'Updating OS packages (services may restart; no automatic reboot)'
    apt_update
    log 'Updating AdGuard Home with its official updater'
    update_adguard
    log 'Packages held back or still upgradeable'
    apt list --upgradable 2>/dev/null
    apt-mark showhold
    wait_for_dns
    status
}

main() {
    [[ $# -eq 2 ]] || fail 'Usage: run.sh <setup|maintain|status|backup|backup-if-installed> <staging-directory>'
    local action=$1
    STAGE=$2
    [[ $EUID -eq 0 && -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]] || fail 'Invoke through sudo from your SSH admin user.'
    [[ $STAGE =~ ^/tmp/dns-server\.[a-zA-Z0-9]{10}$ && -d $STAGE ]] || fail 'Invalid staging directory.'
    source "$STAGE/config.env"
    [[ -d /run/systemd/system ]] || fail 'Requires Raspberry Pi OS with systemd.'
    source /etc/os-release
    [[ $ID == debian || $ID == raspbian ]] || fail 'Expected Raspberry Pi OS (Debian/Raspbian).'
    exec 9>/run/lock/raspberry-dns-server.lock
    flock -n 9 || fail 'Another DNS automation operation is running.'
    case "$action" in
        setup) setup ;;
        maintain) maintain ;;
        status) status ;;
        backup|backup-if-installed) backup "$action" ;;
        *) fail "Unknown action: $action" ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
