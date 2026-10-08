#!/usr/bin/env bash
# Moved to common/purge.sh; kept for parmaham-purge.service units
# installed by older versions (re-run install-hammerdb-purge.sh to update the unit).
exec "$(dirname "$0")/../../common/purge.sh" "$@"
