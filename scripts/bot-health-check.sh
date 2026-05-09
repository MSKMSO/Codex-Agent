#!/usr/bin/env bash
# bot-health-check.sh — definitive "is this bot healthy" check that does NOT
# get fooled by crash loops. Returns JSON; exit 0 = healthy, 1 = sick.
#
# Usage (run as root or via `sudo` so we can see process info):
#   bash bot-health-check.sh <bot-shortname>
#
# Where <bot-shortname> matches the systemd unit prefix:
#   cameron, ashley, jesus-reyes, aixa, zahid, neil-claude, emily-claude, ...
#
# What this checks (in this order):
#   1. Both <name>-bot.service and <name>-responder.service exist
#   2. Each unit's MainPID is non-zero
#   3. Each MainPID has been alive for >= MIN_UPTIME_S seconds (default 30)
#   4. Restart count in the last 2 minutes is <= MAX_RESTARTS_2M (default 1)
#   5. ~/.{name}-bot/creds.json is readable by azureuser
#   6. Directory ownership is azureuser (not root — common provisioning bug)
#   7. Bot Framework client_credentials grant works (real network call)
#
# A bot is "healthy" only if ALL seven pass. A pass on any subset (e.g.
# "service is active" alone) is INSUFFICIENT — a crash-looping bot will
# return active 30-50% of the time during the brief running window
# between RestartSec ticks.

set -uo pipefail
NAME="${1:?usage: $0 <bot-shortname>}"
MIN_UPTIME_S=${MIN_UPTIME_S:-30}
MAX_RESTARTS_2M=${MAX_RESTARTS_2M:-1}

declare -A R   # results

check_units_exist() {
  systemctl list-unit-files "${NAME}-bot.service" "${NAME}-responder.service" --no-pager 2>/dev/null \
    | grep -qE "${NAME}-bot.service|${NAME}-responder.service" \
    && R[units_exist]=pass || R[units_exist]=fail
}

check_main_pid() {
  for kind in bot responder; do
    PID=$(systemctl show "${NAME}-${kind}.service" -p MainPID --value 2>/dev/null)
    if [ -n "$PID" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null; then
      R[pid_${kind}]="pass:$PID"
    else
      R[pid_${kind}]="fail:no-pid"
    fi
  done
}

check_uptime() {
  for kind in bot responder; do
    PID="${R[pid_${kind}]##pass:}"
    [[ "${R[pid_${kind}]}" == fail* ]] && { R[uptime_${kind}]="skip"; continue; }
    SECS=$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')
    if [ -n "$SECS" ] && [ "$SECS" -ge "$MIN_UPTIME_S" ]; then
      R[uptime_${kind}]="pass:${SECS}s"
    else
      R[uptime_${kind}]="fail:${SECS:-?}s<${MIN_UPTIME_S}s"
    fi
  done
}

check_restart_count() {
  for kind in bot responder; do
    N=$(journalctl -u "${NAME}-${kind}.service" --since "2 minutes ago" --no-pager 2>/dev/null | grep -c 'Started')
    if [ "$N" -le "$MAX_RESTARTS_2M" ]; then
      R[restarts_${kind}]="pass:${N}/2min"
    else
      R[restarts_${kind}]="fail:${N}/2min"
    fi
  done
}

check_creds_readable() {
  CREDS="/home/azureuser/.${NAME}-bot/creds.json"
  if sudo -u azureuser test -r "$CREDS" 2>/dev/null; then
    R[creds_readable]="pass"
  else
    R[creds_readable]="fail:cannot-read"
  fi
}

check_dir_ownership() {
  DIR="/home/azureuser/.${NAME}-bot"
  OWNER=$(stat -c %U "$DIR" 2>/dev/null)
  if [ "$OWNER" = "azureuser" ]; then
    R[dir_owner]="pass:azureuser"
  else
    R[dir_owner]="fail:${OWNER:-missing}"
  fi
}

check_bf_auth() {
  CREDS="/home/azureuser/.${NAME}-bot/creds.json"
  if [ ! -r "$CREDS" ]; then R[bf_auth]="skip:no-creds"; return; fi
  APP=$(sudo -u azureuser jq -r .app_id "$CREDS" 2>/dev/null)
  SEC=$(sudo -u azureuser jq -r .client_secret "$CREDS" 2>/dev/null)
  TEN=$(sudo -u azureuser jq -r .tenant "$CREDS" 2>/dev/null)
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APP" --data-urlencode "client_secret=$SEC" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=https://api.botframework.com/.default")
  unset SEC
  if [ "$CODE" = "200" ]; then R[bf_auth]="pass"; else R[bf_auth]="fail:HTTP-${CODE}"; fi
}

check_units_exist
check_main_pid
check_uptime
check_restart_count
check_creds_readable
check_dir_ownership
check_bf_auth

# Verdict
HEALTHY=true
for k in "${!R[@]}"; do
  case "${R[$k]}" in fail*) HEALTHY=false ;; esac
done

# JSON output (no jq — manual to avoid extra deps)
printf '{\n  "name": "%s",\n  "healthy": %s,\n  "checks": {\n' "$NAME" "$HEALTHY"
KEYS=("units_exist" "pid_bot" "pid_responder" "uptime_bot" "uptime_responder"
      "restarts_bot" "restarts_responder" "creds_readable" "dir_owner" "bf_auth")
SEP=""
for k in "${KEYS[@]}"; do
  v="${R[$k]:-skip}"
  printf '%s    "%s": "%s"' "$SEP" "$k" "$v"
  SEP=$',\n'
done
printf '\n  }\n}\n'

[ "$HEALTHY" = true ] && exit 0 || exit 1
