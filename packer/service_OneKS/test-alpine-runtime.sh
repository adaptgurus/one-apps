#!/bin/sh
# Dependency-only CI probe. Never builds or configures a seed or workload cluster.
set -eu

# Package installation is restricted to this disposable Docker test environment.
test -f /.dockerenv
test "$(id -u)" = 0
case "$(cat /etc/alpine-release)" in 3.24.*) ;; *) exit 1 ;; esac
src=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
packages=$(sed -n 's/^apk add //p' "$src/packer/service_OneKS/build-opennebula.sh")
test -n "$packages"
test "$(printf '%s\n' "$packages" | wc -l)" -eq 1
set -f
# Intentional word splitting of package names; the recipe is never sourced/eval'd.
# shellcheck disable=SC2086
set -- $packages
for package do
    case "$package" in -*|*[!a-zA-Z0-9+_.=-]*) exit 1 ;; esac
done
apk add --no-cache "$@"

# An empty context fixture permits loading the real appliance without credentials.
mkdir -p /run/one-context
test ! -e /run/one-context/one_env
: > /run/one-context/one_env
ruby --version
ruby -r "$src/appliances/OneKS/main.rb" -e '
  Service::OneKS.validate_provider_contracts!
  abort "Unexpected workload configuration" unless ONEKS_CLUSTER_NAME.empty? && ONEKS_CLUSTER_SPEC.empty?
  puts "ALPINE_SEED_RUNTIME_PASS"
'
