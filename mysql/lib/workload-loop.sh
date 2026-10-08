#!/usr/bin/env bash
# Moved to common/workload-loop.sh; kept for parmaham-workload.service units
# installed by older versions (re-run install-workload.sh to update the unit).
exec "$(dirname "$0")/../../common/workload-loop.sh" "$@"
