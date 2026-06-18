#!/bin/bash

set -euo pipefail

# -------- CONFIG --------
# These are JumpCloud Command template variables, substituted at dispatch time:
#   {{Apikey}}                 -> JumpCloud Automation Variable (admin-created)
#   {{OrgID}}                  -> JumpCloud Automation Variable (admin-created; optional)
#   {{device.id}}              -> built-in command variable (resolved automatically)
#   {{device.primary_user_id}} -> built-in command variable (resolved automatically)
# Never hardcode a real API key here. If you must run manually for testing,
# export the values as env vars and lock the script down (root:wheel 700).
API_KEY={{Apikey}}
ORG_ID={{OrgID}}
SYSTEM_ID={{device.id}}
PRIMARY_USER_ID={{device.primary_user_id}}  # Non-empty/non-zero = already bound; skip entire script.
JC_BASE="https://console.jumpcloud.com"
EMAIL_FILE="/var/tmp/jc_user_email.txt"
LOG_FILE="/var/log/jc_bind.log"

# Timing
START_DELAY_SECONDS=45                # initial wait before doing anything
CONSOLE_USER_WAIT_MAX=600             # max seconds to keep polling for a real console user
CONSOLE_USER_WAIT_INTERVAL=10         # poll interval during that wait

# UX / robustness
MAX_EMPTY_EMAIL_RETRIES=2             # how many blank email submissions to tolerate
API_MAX_TRIES=3                       # retry attempts for transient API failures
API_RETRY_SLEEP=3                     # seconds between API retries
# ------------------------

# -------- LOGGING --------
# Log to stderr so command substitutions that capture stdout (e.g. the
# console-user wait helper) don't get polluted by log lines.
log() { echo "[JC-BIND $(date '+%Y-%m-%d %H:%M:%S')] $1" >&2; }
# -------------------------

# -------- ROOT CHECK --------
# Must be root: we need launchctl asuser, /var/log, and PUT to /opt/jc/...
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "Must run as root. Current uid: ${EUID:-$(id -u)}"
  exit 1
fi

# -------- PRIMARY USER PRE-CHECK --------
# If the MDM attribute already carries a non-empty, non-zero primary user ID
# this device is already bound — skip the entire workflow immediately.
if [[ -n "${PRIMARY_USER_ID:-}" && "${PRIMARY_USER_ID}" != "0" ]]; then
  log "Primary user already set (ID: ${PRIMARY_USER_ID}). Nothing to do — exiting."
  exit 0
fi
log "No primary user detected. Continuing workflow..."

# -------- LOG FILE REDIRECT --------
# Send stdout + stderr to both the log file and the original terminal.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true
exec > >(tee -a "$LOG_FILE") 2>&1

log "===== jc_bind.sh starting ====="

# -------- STARTUP DELAY --------
log "Waiting ${START_DELAY_SECONDS}s before starting workflow..."
sleep "${START_DELAY_SECONDS}"

# -------- WAIT FOR REAL CONSOLE USER --------
# Even after the initial delay, a Mac can still be at loginwindow or running
# Setup Assistant. Poll until a real interactive user owns /dev/console or
# we hit the timeout.
wait_for_console_user() {
  local waited=0 u
  while (( waited < CONSOLE_USER_WAIT_MAX )); do
    u="$(stat -f "%Su" /dev/console 2>/dev/null || echo "")"
    case "$u" in
      ""|root|_mbsetupuser|loginwindow)
        log "Console user is '${u:-<empty>}'; waiting ${CONSOLE_USER_WAIT_INTERVAL}s..."
        sleep "${CONSOLE_USER_WAIT_INTERVAL}"
        waited=$((waited + CONSOLE_USER_WAIT_INTERVAL))
        ;;
      *)
        echo "$u"
        return 0
        ;;
    esac
  done
  return 1
}

CONSOLE_USER="$(wait_for_console_user)" || {
  log "Timed out after ${CONSOLE_USER_WAIT_MAX}s waiting for a real console user."
  exit 1
}
CONSOLE_UID="$(id -u "$CONSOLE_USER")"

trap 'rm -f "$EMAIL_FILE"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { log "Missing: $1"; exit 1; }; }
need curl; need sed; need tr; need grep; need mktemp; need head; need xargs; need tee; need stat

[[ -z "${API_KEY:-}" ]] && { log "API_KEY is empty."; exit 1; }
[[ -z "${SYSTEM_ID:-}" ]] && { log "SYSTEM_ID is empty."; exit 1; }

HDR=(-H "x-api-key: ${API_KEY}" -H "Accept: application/json")
[[ -n "${ORG_ID:-}" ]] && HDR+=(-H "x-org-id: ${ORG_ID}")

lower() { tr '[:upper:]' '[:lower:]'; }

# JSON-escape using only bash parameter expansion (no jq / python).
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

log "Console user: ${CONSOLE_USER} (uid: ${CONSOLE_UID})"
log "System ID: ${SYSTEM_ID}"
log "JC Base URL: ${JC_BASE}"

# -------- UI HELPERS --------
escape_applescript() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

show_user_error() {
  local msg
  msg="$(escape_applescript "$1")"
  launchctl asuser "$CONSOLE_UID" osascript \
    -e "display dialog \"JumpCloud Binding Failed:

${msg}

Contact IT.\" buttons {\"OK\"} default button \"OK\" with icon stop" >/dev/null 2>&1 || true
}

show_user_success() {
  local msg
  msg="$(escape_applescript "$1")"
  launchctl asuser "$CONSOLE_UID" osascript \
    -e "display dialog \"JumpCloud Binding Successful:

${msg}\" buttons {\"OK\"} default button \"OK\" with icon note" >/dev/null 2>&1 || true
}

# -------- EMAIL PROMPT --------
prompt_for_email() {
  log "Prompting user for email..."
  local empty_count=0
  while true; do
    set +e
    EMAIL="$(launchctl asuser "$CONSOLE_UID" osascript \
      -e 'text returned of (display dialog "Enter your JumpCloud email address:" default answer "" buttons {"OK"} default button "OK")')"
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
      log "Email entry canceled by user."
      show_user_error "Email entry was canceled."
      exit 1
    fi

    EMAIL="$(printf '%s' "$EMAIL" | tr -d '\r\n' | xargs)"

    if [[ -z "${EMAIL:-}" ]]; then
      empty_count=$((empty_count + 1))
      if (( empty_count >= MAX_EMPTY_EMAIL_RETRIES )); then
        log "Too many empty email submissions; aborting."
        show_user_error "No email entered after ${MAX_EMPTY_EMAIL_RETRIES} attempts."
        exit 1
      fi
      continue
    fi

    # Basic format sanity check (not RFC 5322, but catches typos).
    if ! [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      log "Invalid email format: ${EMAIL}"
      continue
    fi

    printf '%s\n' "$EMAIL" > "$EMAIL_FILE"
    log "Email captured: ${EMAIL}"
    break
  done
}

# -------- CURL WITH RETRY --------
# Retries on network error (curl rc != 0) or HTTP 5xx.
# Results are returned via the globals CURL_CODE and CURL_BODY. We don't
# use caller-named output vars (printf -v) because bash's dynamic scoping
# makes them collide with same-named locals inside this function — that
# silently produced an empty HTTP code on the last run.
# Usage: curl_with_retry <curl args...>
CURL_CODE=""
CURL_BODY=""
curl_with_retry() {
  local __tmp __code __attempt=1
  __tmp="$(mktemp)"
  while (( __attempt <= API_MAX_TRIES )); do
    __code="$(curl -sS -o "$__tmp" -w '%{http_code}' "$@" || echo "000")"
    if [[ "$__code" != "000" ]] && ! [[ "$__code" =~ ^5 ]]; then
      break
    fi
    log "API attempt ${__attempt} returned HTTP ${__code}; retrying in ${API_RETRY_SLEEP}s..."
    sleep "${API_RETRY_SLEEP}"
    __attempt=$((__attempt + 1))
  done
  CURL_CODE="$__code"
  CURL_BODY="$(cat "$__tmp")"
  rm -f "$__tmp"
}

# -------- FETCH USER BY EMAIL ONLY --------
fetch_user_by_email() {
  local email="$1"
  log "Fetching JumpCloud user by email: ${email}"
  curl_with_retry -G "${JC_BASE}/api/systemusers" \
    --data-urlencode "filter=email:eq:${email}" \
    --data-urlencode "fields=_id" \
    --data-urlencode "fields=username" \
    --data-urlencode "fields=email" \
    "${HDR[@]}"
  if ! [[ "$CURL_CODE" =~ ^2 ]]; then
    log "User lookup failed (HTTP ${CURL_CODE}): ${CURL_BODY}"
    show_user_error "User lookup failed (HTTP ${CURL_CODE})."
    exit 1
  fi
  printf '%s' "$CURL_BODY"
}

# -------- GET CURRENT SYSTEM DESCRIPTION (for append, not clobber) --------
get_system_description() {
  local sid="$1"
  curl_with_retry -X GET "${JC_BASE}/api/systems/${sid}" "${HDR[@]}"
  if ! [[ "$CURL_CODE" =~ ^2 ]]; then
    printf ''
    return
  fi
  printf '%s' "$CURL_BODY" | tr -d '\n' \
    | sed -n -E 's/.*"description"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)".*/\1/p' \
    | head -n1
}

# -------- UPDATE USERNAME STRICT + FAILURE LOGGING --------
# Sends new_username verbatim (no case transforms). Uses JSON body, not -F.
update_system_username_strict() {
  local user_id="$1" new_username="$2" email="$3"
  local esc payload code_snapshot body_snapshot
  esc="$(json_escape "$new_username")"
  payload="{\"systemUsername\":\"${esc}\"}"

  log "Updating systemUsername for user_id=${user_id} to '${new_username}' (preserving original case)"
  curl_with_retry -X PUT "${JC_BASE}/api/systemusers/${user_id}" \
    "${HDR[@]}" -H "Content-Type: application/json" -d "$payload"

  if [[ "$CURL_CODE" =~ ^(200|204)$ ]]; then
    log "systemUsername update succeeded (HTTP $CURL_CODE)"
    return 0
  fi

  # Snapshot before the next curl call overwrites CURL_CODE / CURL_BODY.
  code_snapshot="$CURL_CODE"
  body_snapshot="$CURL_BODY"
  log "systemUsername update FAILED (HTTP $code_snapshot): $body_snapshot"

  # Append a failure breadcrumb to the existing description rather than
  # clobbering it.
  local existing safe_msg append combined esc_desc
  existing="$(get_system_description "$SYSTEM_ID")"
  safe_msg="$(printf '%s' "$body_snapshot" | tr -d '\n' | cut -c1-300)"
  append="[$(date '+%Y-%m-%dT%H:%M:%SZ')] systemUsername update failed | LocalUser: ${CONSOLE_USER} | JCUsername: ${JC_USERNAME} | UserEmail: ${email} | HTTP ${code_snapshot} | Error: ${safe_msg}"
  if [[ -n "$existing" ]]; then
    combined="${existing}"$'\n'"${append}"
  else
    combined="${append}"
  fi
  esc_desc="$(json_escape "$combined")"

  curl_with_retry -X PUT "${JC_BASE}/api/systems/${SYSTEM_ID}" \
    "${HDR[@]}" -H "Content-Type: application/json" \
    -d "{\"description\":\"${esc_desc}\"}"
  log "Failure breadcrumb write: HTTP ${CURL_CODE}"

  show_user_error "Username update failed. Please contact IT."
  exit 1
}

# -------- SET PRIMARY USER --------
set_primary_user() {
  local user_id="$1" system_id="$2"

  log "Setting user_id=${user_id} as primary user on system_id=${system_id}"
  curl_with_retry -X PUT "${JC_BASE}/api/systems/${system_id}" \
    "${HDR[@]}" -H "Content-Type: application/json" \
    -d "{\"primarySystemUser\":{\"id\":\"${user_id}\"}}"

  if [[ "$CURL_CODE" =~ ^(200|204)$ ]]; then
    log "Primary user set succeeded (HTTP $CURL_CODE)"
    return 0
  fi

  log "Primary user set FAILED (HTTP $CURL_CODE): $CURL_BODY"
  show_user_error "Setting primary user failed (HTTP $CURL_CODE)."
  exit 1
}

# -------- BIND USER --------
associate_user_system() {
  local user_id="$1" system_id="$2" body_json

  log "Binding user_id=${user_id} to system_id=${system_id}"

  body_json=$(cat <<JSON
{
  "attributes": { "sudo": { "enabled": true, "withoutPassword": false } },
  "op": "add",
  "type": "system",
  "id": "${system_id}"
}
JSON
)

  curl_with_retry -X POST "${JC_BASE}/api/v2/users/${user_id}/associations" \
    "${HDR[@]}" -H "Content-Type: application/json" -d "${body_json}"

  if [[ "$CURL_CODE" =~ ^(200|204|409)$ ]]; then
    log "Bind succeeded (HTTP $CURL_CODE)"
    return 0
  fi

  log "Bind FAILED (HTTP $CURL_CODE): $CURL_BODY"
  show_user_error "Binding failed (HTTP $CURL_CODE)."
  exit 1
}

# ===================== MAIN FLOW =====================

log "===== Starting main workflow ====="
log "System ID: ${SYSTEM_ID}"

# -------- SERVICE ACCOUNT SECURE TOKEN CHECK --------
# Only proceed with the email prompt if _jumpcloudserviceaccount exists
# AND has Secure Token ENABLED. Any other result (missing account, DISABLED)
# exits cleanly without prompting the user.
JC_SVC_ACCOUNT="_jumpcloudserviceaccount"
SVC_TOKEN_STATUS="$(sysadminctl -secureTokenStatus "$JC_SVC_ACCOUNT" 2>&1)"
log "Service account token check: ${SVC_TOKEN_STATUS}"

if ! echo "$SVC_TOKEN_STATUS" | grep -q "ENABLED"; then
  log "Skipping prompt — ${JC_SVC_ACCOUNT} either does not exist or lacks Secure Token."
  exit 1
fi

log "Service account Secure Token confirmed ENABLED. Proceeding..."

# 1) Ask for email
prompt_for_email
EMAIL="$(head -n1 "$EMAIL_FILE")"
EMAIL_L="$(printf '%s' "$EMAIL" | lower)"
log "Normalized email: ${EMAIL_L}"

# 2) Fetch only this user
USER_JSON="$(fetch_user_by_email "$EMAIL_L")"

USER_ID="$(echo "$USER_JSON" | sed -n -E 's/.*"_id"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{24})".*/\1/p' | head -n1)"
JC_USERNAME="$(echo "$USER_JSON" | sed -n -E 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"

if [[ -z "${USER_ID:-}" ]]; then
  log "No JumpCloud user found with email: ${EMAIL_L}"
  show_user_error "No JumpCloud user found with this email."
  exit 1
fi

log "Resolved JC user_id: ${USER_ID}"
log "Resolved JC username: ${JC_USERNAME}"

# Case-insensitive comparison ONLY — used to decide whether an update is
# needed. The value actually PUT to JumpCloud is always the unmodified
# $CONSOLE_USER (original case preserved).
LOCAL_L="$(printf '%s' "$CONSOLE_USER" | lower)"
JC_L="$(printf '%s' "$JC_USERNAME" | lower)"
log "Local username (for compare, lower): ${LOCAL_L}"
log "JC username (for compare, lower): ${JC_L}"
log "Local username (as sent to JC, original case): ${CONSOLE_USER}"

# 3) Compare usernames
if [[ "$LOCAL_L" == "$JC_L" ]]; then
  log "Usernames match. Proceeding to bind."
  associate_user_system "$USER_ID" "$SYSTEM_ID"
  set_primary_user "$USER_ID" "$SYSTEM_ID"
  show_user_success "Please log out and log back in to complete the binding process."
  log "Workflow completed successfully."
  exit 0
fi

log "Usernames do not match. Updating systemUsername then binding..."
# 4) Update username strictly — pass CONSOLE_USER verbatim (no case changes)
update_system_username_strict "$USER_ID" "$CONSOLE_USER" "$EMAIL"

# 5) Bind and set primary user after successful update
associate_user_system "$USER_ID" "$SYSTEM_ID"
set_primary_user "$USER_ID" "$SYSTEM_ID"
show_user_success "Please log out and log back in to complete the binding process."
log "Workflow completed successfully."
