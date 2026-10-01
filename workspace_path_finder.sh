#!/usr/bin/env bash
#
# Walks:
#   <BASE_DIR>/<env>/<dynamic>/service/<dynamic>/workspace/<dynamic-folder>
# and writes one CSV row per <dynamic-folder> found.
#
# Usage:  ./list_workspace_paths.sh [output.csv]
#
# Settings are read from a .env file (default: .env next to this script).
# Use a different file with:  ENV_FILE=/path/to/file.env ./list_workspace_paths.sh
#
# Supported keys in the .env file:
#   BASE_DIR      base directory (default: /home/buildpiper/.codebase/workspaces)
#   SKIP_ENVS     comma-separated environments to leave out of the CSV, e.g. prod,uat
#   CSV_FILE      output CSV path (default: workspace_paths.csv); the command-line
#                 argument, if given, overrides it
#   BLOCK_START   hour (0-23) when the blocked window starts (default: 7  = 07:00)
#   BLOCK_END     hour (0-23) when the blocked window ends   (default: 22 = 22:00)
#                 The script refuses to run between BLOCK_START and BLOCK_END
#                 (server local time), i.e. it only runs from 22:00 to 07:00.
#
# Precedence (highest first): command-line argument (CSV only) > variables already
# exported in the shell > .env file > built-in defaults.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVS=(prod dev uat staging qa)

# ---------------- .env loader ----------------
# Reads KEY=VALUE lines WITHOUT executing them (no `source`), and only accepts the
# keys listed below. Handles comments, blank lines, "export ", quotes and CRLF endings.
# Variables already set in the environment are not overwritten.
load_env_file() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"          # trim leading whitespace
    [[ -z "$line" || "$line" == \#* ]] && continue   # blank or comment
    line="${line#export }"
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"; key="${key//[[:space:]]/}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"             # trim leading whitespace

    if [[ "$val" =~ ^\"([^\"]*)\" ]] || [[ "$val" =~ ^\'([^\']*)\' ]]; then
      val="${BASH_REMATCH[1]}"                       # quoted value: keep what is inside the quotes
    else
      val="${val%%[[:space:]]#*}"                    # unquoted: drop trailing " # comment"
      val="${val%"${val##*[![:space:]]}"}"           # trim trailing whitespace
    fi

    case "$key" in
      BASE_DIR|SKIP_ENVS|CSV_FILE|BLOCK_START|BLOCK_END)
        if [ -z "${!key+x}" ]; then printf -v "$key" '%s' "$val"; fi ;;
    esac
  done < "$file"
}

if [ -n "${ENV_FILE:-}" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: ENV_FILE not found: $ENV_FILE"
    exit 1
  fi
else
  ENV_FILE="$SCRIPT_DIR/.env"
fi

if [ -f "$ENV_FILE" ]; then
  load_env_file "$ENV_FILE"
  echo "Loaded settings from $ENV_FILE"
else
  echo "No .env file found at $ENV_FILE, using defaults"
fi

BASE_DIR="${BASE_DIR:-/home/buildpiper/.codebase/workspaces}"
SKIP_ENVS="${SKIP_ENVS:-}"
BLOCK_START="${BLOCK_START:-7}"
BLOCK_END="${BLOCK_END:-22}"
OUTPUT_CSV="${1:-${CSV_FILE:-workspace_paths.csv}}"

# ---------------- helpers ----------------

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

# Values now come from a file, so validate them before use
validate_settings() {
  local h
  for h in "$BLOCK_START" "$BLOCK_END"; do
    if ! [[ "$h" =~ ^[0-9]+$ ]] || [ "$h" -gt 23 ]; then
      echo "ERROR: BLOCK_START and BLOCK_END must be whole hours between 0 and 23 (got '$h')"
      exit 1
    fi
  done

  # Reject typos in SKIP_ENVS (e.g. "Prod" or "production") so a skip is never silently ignored
  local e v ok list
  IFS=',' read -ra list <<< "${SKIP_ENVS// /}"
  for e in "${list[@]}"; do
    [ -z "$e" ] && continue
    ok=0
    for v in "${ENVS[@]}"; do [ "$e" = "$v" ] && ok=1; done
    if [ $ok -eq 0 ]; then
      echo "ERROR: unknown environment '$e' in SKIP_ENVS. Valid values: ${ENVS[*]}"
      exit 1
    fi
  done

  if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: BASE_DIR does not exist: $BASE_DIR"
    exit 1
  fi
}

# ---------------- checks ----------------
validate_settings

# Checked before the CSV is touched, so a blocked run never overwrites an existing file
if in_blocked_window; then
  printf 'Not allowed to run now (%s). Execution is blocked between %02d:00 and %02d:00. Exiting.\n' \
    "$(date +%H:%M)" "$BLOCK_START" "$BLOCK_END"
  exit 1
fi

[ -n "$SKIP_ENVS" ] && echo "Skipping environments: ${SKIP_ENVS// /}"

# ---------------- main ----------------
shopt -s nullglob   # unmatched globs expand to nothing instead of themselves

echo "environment,project,service,workspace_folder,full_path" > "$OUTPUT_CSV"

count=0
for env in "${ENVS[@]}"; do
  if is_env_skipped "$env"; then
    echo "Skipping env: $env"
    continue
  fi

  for project_dir in "$BASE_DIR/$env"/*/; do
    project=$(basename "$project_dir")

    for service_dir in "${project_dir}service"/*/; do
      service=$(basename "$service_dir")
      ws_dir="${service_dir}workspace"

      [ -d "$ws_dir" ] || continue          # skip if no workspace dir (e.g. only deployment_name)

      for folder in "$ws_dir"/*/; do        # trailing / => directories only (skips pre_hooks_output.json)
        folder_name=$(basename "$folder")
        full_path="${folder%/}"
        echo "\"$env\",\"$project\",\"$service\",\"$folder_name\",\"$full_path\"" >> "$OUTPUT_CSV"
        count=$((count + 1))
      done
    done
  done
done

echo "Done. $count path(s) written to $OUTPUT_CSV"
