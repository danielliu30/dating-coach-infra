#!/usr/bin/env bash
# Release-window gate for the deploy pipelines. Exits 0 inside the window,
# 1 outside — outside is a refusal, not a failure of the build.
#
# Config (env, set as repo variables):
#   DEPLOY_WINDOW_DAYS       allowed UTC weekdays, %w numbering (0=Sun..6=Sat).
#                            Comma list with ranges: "1-4" or "1,2,3". Empty = any day.
#   DEPLOY_WINDOW_START_UTC  first allowed UTC hour (0-23). Empty = 0.
#   DEPLOY_WINDOW_END_UTC    window closes at this UTC hour, exclusive. Empty = 24.
#                            start<end: [start,end). start>end: wraps midnight.
#                            start==end or both empty: all hours allowed.
#   DEPLOY_WINDOW_NOW_EPOCH  override "now" (seconds) — tests only.
#
# A merge outside the window fails the deploy job fast; re-run the workflow
# (or merge the next PR) inside the window to deploy.
set -u

now=${DEPLOY_WINDOW_NOW_EPOCH:-$(date -u +%s)}
day=$(date -u -d "@$now" +%w)    # 0=Sun .. 6=Sat
hour=$(date -u -d "@$now" +%H); hour=$((10#$hour))
stamp=$(date -u -d "@$now" '+%Y-%m-%d %H:%M UTC')

day_allowed() { # $1 = spec like "1-4" or "1,2,6"
  local spec=$1 lo hi d
  [ -z "$spec" ] && return 0
  IFS=',' read -ra parts <<<"$spec"
  for p in "${parts[@]}"; do
    case "$p" in
      *-*) lo=${p%-*}; hi=${p#*-}
           [ "$hi" -lt "$lo" ] && hi=$((hi+7))   # wrapping range like "5-1"
           for ((d=lo; d<=hi; d++)); do [ "$((d % 7))" = "$day" ] && return 0; done ;;
      *)   [ "$p" = "$day" ] && return 0 ;;
    esac
  done
  return 1
}

hour_allowed() { # $1 = start, $2 = end
  local s=${1:-0} e=${2:-24}
  [ "$s" = "$e" ] && return 0
  if [ "$s" -lt "$e" ]; then
    [ "$hour" -ge "$s" ] && [ "$hour" -lt "$e" ]
  else
    [ "$hour" -ge "$s" ] || [ "$hour" -lt "$e" ]
  fi
}

if ! day_allowed "${DEPLOY_WINDOW_DAYS:-}"; then
  echo "outside release window: $stamp is not an allowed deploy day (DEPLOY_WINDOW_DAYS='${DEPLOY_WINDOW_DAYS:-}')"
  exit 1
fi
if ! hour_allowed "${DEPLOY_WINDOW_START_UTC:-}" "${DEPLOY_WINDOW_END_UTC:-}"; then
  echo "outside release window: $stamp is outside ${DEPLOY_WINDOW_START_UTC:-0}:00-${DEPLOY_WINDOW_END_UTC:-24}:00 UTC"
  exit 1
fi
echo "inside release window ($stamp)"
exit 0
