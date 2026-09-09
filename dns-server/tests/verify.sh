#!/usr/bin/env bash
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
bash -n "$project/scripts/run.sh"
source "$project/scripts/run.sh"
DNS_TEST_NAME=example.com

# dig can exit successfully despite DNS errors. Exercise the actual health parser.
dig() { printf '%s\n' "$REPLY"; }
REPLY=';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
example.com. 60 IN A 93.184.215.14'
dns_query 127.0.0.1 +tcp || fail 'Valid DNS reply rejected'
for REPLY in \
    ';; status: SERVFAIL' \
    ';; status: NXDOMAIN' \
    ';; status: NOERROR' \
    $';; status: NOERROR\nexample.com. 60 IN A 0.0.0.0'; do
    if dns_query 127.0.0.1 +notcp; then fail 'Invalid DNS reply accepted'; fi
done
dig() { return 9; }
if dns_query 127.0.0.1 +tcp; then fail 'dig transport failure ignored'; fi

# Isolated subshells stub every operation on the maintenance path.
# Execute outside an if/! condition so Bash errexit retains production semantics.
error_trap=$(trap -p ERR)
trap - ERR
set +e
(
    set -e
    require_install() { :; }
    check_identity() { :; }
    apt_update() { return 23; }
    update_adguard() { exit 99; }
    maintain
) >/dev/null 2>&1
result=$?
set -e
eval "$error_trap"
[[ $result -eq 23 ]] || fail "Package failure was not propagated: $result"

trap - ERR
set +e
(
    set -e
    require_install() { :; }
    check_identity() { :; }
    apt_update() { :; }
    update_adguard() { return 24; }
    wait_for_dns() { exit 99; }
    maintain
) >/dev/null 2>&1
result=$?
set -e
eval "$error_trap"
[[ $result -eq 24 ]] || fail "AdGuard Home update failure was not propagated: $result"

# Backups must restart DNS after a failed archive, preserving the failure code.
record=$(mktemp)
trap - ERR
set +e
(
    set -e
    STAGE=/unused
    require_install() { :; }
    systemctl() { printf '%s\n' "$*" >> "$record"; }
    python3() { return 25; }
    backup backup
) >/dev/null 2>&1
result=$?
set -e
eval "$error_trap"
[[ $result -eq 25 ]] || fail "Backup failure was hidden: $result"
grep -q '^stop AdGuardHome$' "$record" || fail 'Backup did not stop the service'
grep -q '^start AdGuardHome$' "$record" || fail 'Backup failure left the service stopped'
rm -- "$record"

printf 'PASS: Bash syntax, DNS validation, failed updates, DNS restart after backup failure.\n'
