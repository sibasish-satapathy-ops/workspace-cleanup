#!/usr/bin/env bash
#
# Deletes stale folders that sit directly inside a "workspace" directory
# and reports how much storage was (or would be) freed.
#
# Usage:
#   ./cleanup_workspace.sh <folder-path>   -> check/delete that single folder
#   ./cleanup_workspace.sh all             -> check/delete every path in the CSV
#
# Optional environment variables:
#   DRY_RUN=1          only print what would be deleted, delete nothing
#                      (dry runs are allowed at any time of day)
#   SKIP_ENVS=prod,uat comma-separated environments to leave untouched
#   CSV_FILE=...       CSV to read in "all" mode (default: workspace_paths.csv)
#   DAYS=10            age threshold in days (default: 10)
#   BLOCK_START=7      hour (0-23) when the blocked window starts (default: 7  = 07:00)
#   BLOCK_END=22       hour (0-23) when the blocked window ends   (default: 22 = 22:00)
#                      The script refuses to delete between BLOCK_START and BLOCK_END
#                      (server local time), i.e. it only runs from 22:00 to 07:00.
#   RUN_MINS=5         maximum run time in minutes (default: 0 = no limit).
#                      Once the time is up the script finishes the folder it is
#                      currently working on, does NOT start a new one, prints the
#                      summary and exits gracefully (exit code 0).
#   LOG_DIR=...        log directory (default: /home/buildpiper/.log/cleanup)
#   LOG_KEEP=20        number of execution logs to keep (default: 20); older
#                      log files in LOG_DIR are deleted automatically.
#
# .env support:
#   All the variables above can also be set in a .env file. By default the script
#   reads ".env" from the same directory as the script; use ENV_FILE=/path/to/.env
#   to point somewhere else (the script exits if an explicitly given file is missing).
#   Format: KEY=VALUE per line, "#" comments and blank lines allowed, values may be
#   quoted. The file is parsed, never executed, and only the variables listed above
#   are accepted. Precedence: variables already set in the shell/cron environment
#   win over the .env file, which wins over the built-in defaults.
#
# Logging:
#   Every execution writes its output (also shown on screen) to
#   $LOG_DIR/cleanup_workspace.log_<YYYYmmdd_HHMMSS>
#   (Runs refused because of the blocked time window are not logged, so they
#   cannot push useful logs out of the retention window.)

# ---------------- .env loading (must run before the defaults below) ----------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE_EXPLICIT="${ENV_FILE:+1}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
ENV_ALLOWED="DRY_RUN SKIP_ENVS CSV_FILE DAYS BLOCK_START BLOCK_END RUN_MINS LOG_DIR LOG_KEEP"
ENV_LOAD_MSG=""

# Parses KEY=VALUE lines (no code execution). Variables already set in the
# environment are NOT overridden; unknown keys are ignored.
load_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ -n "$ENV_FILE_EXPLICIT" ]; then
      echo "ERROR: ENV_FILE not found: $ENV_FILE"
      exit 1
    fi
    ENV_LOAD_MSG="No .env file at $ENV_FILE - using defaults"
    return
  fi

  local line key val v loaded="" kept_env="" ignored=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"                          # CRLF files
    line="${line#"${line%%[![:space:]]*}"}"       # trim leading space
    line="${line%"${line##*[![:space:]]}"}"       # trim trailing space
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"

    if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
      val="${val:1:${#val}-2}"                    # "double quoted"
    elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
      val="${val:1:${#val}-2}"                    # 'single quoted'
    else
      val="${val%%[[:space:]]#*}"                 # strip inline " # comment"
      val="${val%"${val##*[![:space:]]}"}"
    fi

    if [[ " $ENV_ALLOWED " != *" $key "* ]]; then
      ignored="$ignored $key"
      continue
    fi
    if [ -n "${!key+x}" ]; then                   # already set by the caller -> keep it
      kept_env="$kept_env $key"
      continue
    fi
    printf -v "$key" '%s' "$val"
    export "$key"
    loaded="$loaded $key"
  done < "$ENV_FILE"

  ENV_LOAD_MSG="Loaded settings from $ENV_FILE:${loaded:- (none)}"
  [ -n "$kept_env" ] && ENV_LOAD_MSG="$ENV_LOAD_MSG | kept from environment:$kept_env"
  [ -n "$ignored" ]  && ENV_LOAD_MSG="$ENV_LOAD_MSG | ignored unknown keys:$ignored"
}

load_env_file

BASE_DIR="/home/buildpiper/.codebase/workspaces"
CSV_FILE="${CSV_FILE:-workspace_paths.csv}"
DAYS="${DAYS:-10}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_ENVS="${SKIP_ENVS:-}"
BLOCK_START="${BLOCK_START:-7}"
BLOCK_END="${BLOCK_END:-22}"
RUN_MINS="${RUN_MINS:-0}"
LOG_DIR="${LOG_DIR:-/home/buildpiper/.log/cleanup}"
LOG_KEEP="${LOG_KEEP:-20}"
LOG_PREFIX="cleanup_workspace.log_"
MINS=$((DAYS * 1440))
FREED_KB=0
VALID_ENVS="prod dev uat staging qa"
START_EPOCH=$(date +%s)
DEADLINE=0
STOP_REQUESTED=0

# Only paths of exactly this shape are ever allowed to be deleted:
#   BASE/<env>/<dynamic>/service/<dynamic>/workspace/<folder>
PATH_REGEX="^${BASE_DIR}/(prod|dev|uat|staging|qa)/[^/]+/service/[^/]+/workspace/[^/]+$"

# ---------------- helpers ----------------

# KB -> human readable (e.g. 1536 -> "1.50 MB")
human() {
  awk -v k="$1" 'BEGIN{ s=k*1024; split("B KB MB GB TB",u," "); i=1;
       while (s>=1024 && i<5) { s/=1024; i++ } printf "%.2f %s", s, u[i] }'
}

# Free space (KB) on the filesystem holding BASE_DIR
avail_kb() { df -Pk "$BASE_DIR" 2>/dev/null | awk 'NR==2{print $4}'; }

# True (0) if the current hour is inside the blocked window [BLOCK_START, BLOCK_END)
in_blocked_window() {
  local h=$((10#$(date +%H)))
  if [ "$BLOCK_START" -le "$BLOCK_END" ]; then
    [ "$h" -ge "$BLOCK_START" ] && [ "$h" -lt "$BLOCK_END" ]
  else   # window wraps past midnight
    [ "$h" -ge "$BLOCK_START" ] || [ "$h" -lt "$BLOCK_END" ]
  fi
}

# True (0) if the given environment is in SKIP_ENVS
is_env_skipped() {
  [[ ",${SKIP_ENVS// /}," == *",$1,"* ]]
}

# Reject typos in SKIP_ENVS (e.g. "Prod" or "production") so a skip is never silently ignored
validate_skip_envs() {
  local e v ok
  IFS=',' read -ra list <<< "${SKIP_ENVS// /}"
  for e in "${list[@]}"; do
    [ -z "$e" ] && continue
    ok=0
    for v in $VALID_ENVS; do [ "$e" = "$v" ] && ok=1; done
    if [ $ok -eq 0 ]; then
      echo "ERROR: unknown environment '$e' in SKIP_ENVS. Valid values: ${VALID_ENVS// /, }"
      exit 1
    fi
  done
}

# Validate RUN_MINS / LOG_KEEP and compute the deadline
validate_numbers() {
  if ! [[ "$RUN_MINS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: RUN_MINS must be a whole number of minutes (got '$RUN_MINS')"
    exit 1
  fi
  if ! [[ "$LOG_KEEP" =~ ^[0-9]+$ ]] || [ "$LOG_KEEP" -lt 1 ]; then
    echo "ERROR: LOG_KEEP must be a whole number >= 1 (got '$LOG_KEEP')"
    exit 1
  fi
  [ "$RUN_MINS" -gt 0 ] && DEADLINE=$((START_EPOCH + RUN_MINS * 60))
}

# True (0) when the user-defined run time is used up or a stop signal was received
time_up() {
  [ "$STOP_REQUESTED" -eq 1 ] && return 0
  [ "$DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]
}

# Ctrl-C / kill: finish the current folder, then exit gracefully
on_signal() {
  STOP_REQUESTED=1
  echo "Signal received - will stop after the current folder finishes."
}

# Create the log file for this run, tee all output into it, and rotate old logs
setup_logging() {
  if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    echo "WARNING: cannot create log directory $LOG_DIR - continuing without file logging"
    return
  fi
  LOG_FILE="$LOG_DIR/${LOG_PREFIX}$(date +%Y%m%d_%H%M%S)"
  if ! : >> "$LOG_FILE" 2>/dev/null; then
    echo "WARNING: cannot write $LOG_FILE - continuing without file logging"
    return
  fi

  # Rotation: keep only the newest LOG_KEEP logs (timestamp in the name sorts chronologically).
  # Only regular files matching the log prefix inside LOG_DIR are ever removed.
  local old
  while IFS= read -r old; do
    [ -f "$old" ] && rm -f -- "$old"
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "${LOG_PREFIX}*" | sort -r | tail -n +$((LOG_KEEP + 1)))

  # From here on, everything printed goes to screen AND the log file
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "===== cleanup_workspace started $(date '+%Y-%m-%d %H:%M:%S') | args: $* | DRY_RUN=$DRY_RUN | RUN_MINS=$RUN_MINS | DAYS=$DAYS ====="
  echo "Log file: $LOG_FILE (keeping last $LOG_KEEP logs)"
}

# Returns: 0 = something changed in last $DAYS days (recent)
#          1 = nothing changed (stale)
#          2 = could not inspect the folder (e.g. permission denied) -> unknown
# Checks both mtime (content change) and ctime (rename/copy/chmod), so folders
# whose files kept an old timestamp (cp -p, rsync -t, tar) are not wrongly treated as stale.
recently_updated() {
  local out rc
  out=$(find "$1" \( -mmin "-$MINS" -o -cmin "-$MINS" \) -print -quit 2>/dev/null)
  rc=$?
  [ -n "$out" ] && return 0   # found a recent file -> recent
  [ $rc -ne 0 ] && return 2   # find had errors -> cannot be sure, do NOT delete
  return 1
}

# Result codes: 0 = deleted (or would be), 1 = skipped/error,
#               2 = recently updated,      3 = environment skipped,
#               4 = run time is up (nothing was touched)
process_path() {
  local target="${1%/}"    # strip trailing slash

  # ---- run-time limit: never START a new folder after the deadline ----
  if time_up; then
    return 4
  fi

  # ---- safety checks ----
  if [[ "$target" == *".."* ]] || ! [[ "$target" =~ $PATH_REGEX ]]; then
    echo "SKIP (path not in expected format, refusing to touch): $target"
    return 1
  fi

  # ---- environment skip list ----
  local env="${target#"$BASE_DIR"/}"
  env="${env%%/*}"
  if is_env_skipped "$env"; then
    echo "SKIP-ENV ($env is in SKIP_ENVS): $target"
    return 3
  fi

  if [ -L "$target" ]; then
    echo "SKIP (is a symlink): $target"
    return 1
  fi
  if [ ! -d "$target" ]; then
    echo "SKIP (folder does not exist): $target"
    return 1
  fi

  # ---- age check ----
  recently_updated "$target"
  case $? in
    0) echo "KEEP (updated in last $DAYS days): $target"; return 2 ;;
    2) echo "SKIP (cannot read folder fully, not deleting): $target"; return 1 ;;
  esac

  # ---- size (before delete) ----
  local size_kb
  size_kb=$(du -sk -- "$target" 2>/dev/null | cut -f1)
  size_kb=${size_kb:-0}

  # ---- last chance to stop before the (irreversible) delete ----
  if time_up; then
    return 4
  fi

  # ---- delete ----
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN (would delete, $(human "$size_kb")): $target"
    FREED_KB=$((FREED_KB + size_kb))
  else
    if rm -rf -- "$target"; then
      echo "DELETED ($(human "$size_kb")): $target"
      FREED_KB=$((FREED_KB + size_kb))
    else
      echo "ERROR deleting: $target"
      return 1
    fi
  fi
  return 0
}

print_storage_report() {
  echo "-----"
  if [ "$DRY_RUN" = "1" ]; then
    echo "Storage that WOULD be freed: $(human "$FREED_KB")"
  else
    local after; after=$(avail_kb)
    echo "Storage freed (sum of deleted folders): $(human "$FREED_KB")"
    if [ -n "$BEFORE_KB" ] && [ -n "$after" ]; then
      echo "Disk free space before: $(human "$BEFORE_KB")"
      echo "Disk free space after : $(human "$after")"
      echo "Actual change on disk : $(human $((after - BEFORE_KB)))"
    fi
  fi
}

print_footer() {
  local elapsed=$(( $(date +%s) - START_EPOCH ))
  echo "Elapsed time: $((elapsed / 60))m $((elapsed % 60))s"
  echo "===== cleanup_workspace finished $(date '+%Y-%m-%d %H:%M:%S') ====="
}

# ---------------- main ----------------
if [ $# -ne 1 ]; then
  echo "Usage: $0 <folder-path | all>"
  exit 1
fi

validate_skip_envs
validate_numbers

# ---- time window check (dry runs are exempt) ----
if [ "$DRY_RUN" != "1" ] && in_blocked_window; then
  printf 'Not allowed to run now (%s). Deletion is blocked between %02d:00 and %02d:00. Exiting.\n' \
    "$(date +%H:%M)" "$BLOCK_START" "$BLOCK_END"
  exit 1
fi

# ---- start logging (creates the log file, rotates old ones) ----
setup_logging "$@"
trap on_signal INT TERM
[ -n "$ENV_LOAD_MSG" ] && echo "$ENV_LOAD_MSG"

[ -n "$SKIP_ENVS" ] && echo "Skipping environments: ${SKIP_ENVS// /}"
[ "$RUN_MINS" -gt 0 ] && echo "Run time limit: $RUN_MINS minute(s) (until $(date -d "@$DEADLINE" '+%H:%M:%S'))"

BEFORE_KB=$(avail_kb)

if [ "$1" != "all" ]; then
  # Mode 1: single folder
  process_path "$1"
  rc=$?
  if [ $rc -eq 2 ]; then
    echo "The folder is updated in last $DAYS days. Exiting."
    print_footer
    exit 0
  fi
  if [ $rc -eq 3 ]; then
    echo "Environment is excluded via SKIP_ENVS. Exiting."
    print_footer
    exit 0
  fi
  if [ $rc -eq 4 ]; then
    echo "Run time limit reached before the folder was processed. Exiting gracefully."
    print_footer
    exit 0
  fi
  [ $rc -eq 0 ] && print_storage_report
  print_footer
  exit $rc
fi

# Mode 2: all paths from CSV
if [ ! -f "$CSV_FILE" ]; then
  echo "CSV file not found: $CSV_FILE"
  print_footer
  exit 1
fi

deleted=0; kept=0; env_skipped=0; skipped=0; timed_out=0
while IFS= read -r path; do
  [ -z "$path" ] && continue

  # Long runs: stop if the blocked window begins while we are working
  if [ "$DRY_RUN" != "1" ] && in_blocked_window; then
    printf 'Blocked window (%02d:00-%02d:00) started at %s. Stopping early.\n' \
      "$BLOCK_START" "$BLOCK_END" "$(date +%H:%M)"
    break
  fi

  process_path "$path"
  case $? in
    0) deleted=$((deleted + 1)) ;;
    2) kept=$((kept + 1)) ;;
    3) env_skipped=$((env_skipped + 1)) ;;
    4) timed_out=1
       if [ "$STOP_REQUESTED" -eq 1 ]; then
         echo "Stop requested. Exiting gracefully."
       else
         echo "Run time limit of $RUN_MINS minute(s) reached. Exiting gracefully."
       fi
       break ;;
    *) skipped=$((skipped + 1)) ;;
  esac
done < <(tail -n +2 "$CSV_FILE" | sed -E 's/.*,"([^"]*)"$/\1/')   # skip header, take last (full_path) column

echo "-----"
echo "Summary: deleted=$deleted, kept(recent)=$kept, skipped(env)=$env_skipped, skipped/errors=$skipped"
[ "$timed_out" -eq 1 ] && echo "Note: stopped early - remaining paths in the CSV were not processed."
print_storage_report
print_footer
exit 0
