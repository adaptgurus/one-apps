#!/usr/bin/env bash

# Configure and enable service context.

exec 1>&2
set -eux -o pipefail

mv /etc/one-appliance/net-90-service-appliance /etc/one-context.d/
mv /etc/one-appliance/net-99-report-ready      /etc/one-context.d/

# OneKS configure can run for many minutes while kind/CAPI converges. Start
# the guest agent and SSH after network contextualization, before configure,
# so bootstrap remains observable and recoverable during that interval.
tmp=$(mktemp)
awk '
    { print }
    /^\[\[ -x \/etc\/one-appliance\/service \]\]$/ {
        print ""
        print "# OneKS early diagnostics before long-running configure"
        print "rc-service qemu-guest-agent restart || true"
        print "rc-service sshd restart || true"
    }
' /etc/one-context.d/net-90-service-appliance > "$tmp"
install -m 0755 "$tmp" /etc/one-context.d/net-90-service-appliance
rm -f "$tmp"

chown root:root /etc/one-context.d/*
chmod u=rwx,go=rx /etc/one-context.d/*

sync