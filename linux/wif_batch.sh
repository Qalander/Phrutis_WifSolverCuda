#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (edit as needed) ----------
WIFSOLVER="./wifSolver"   # compiled binary in current dir
PART1_FILE="part1_list.txt"   # one candidate per line (Base58). blanks/#comments ignored
PART2="5bCRZhiS5sEGMpmcRZdpAhmWLRfMmutGmPHtjVob" # from your screenshot
ADDRESS="1PfNh5fRcE9JKDmicD2Rh3pexGwce1LqyU"
GPU_ID="0"                    # choose GPU
STOP_ON_HIT=1                 # 1 = stop on first success, 0 = keep going
TIMEOUT_SECONDS=0             # 0 = no timeout; else kill each run after N seconds

# Any extra args you want to pass to WifSolverCuda (threads, etc.)
EXTRA_ARGS=""                 # e.g., "-t 4096"

# ---------- END CONFIG ----------
ts="$(date +%Y%m%d_%H%M%S)"
LOG="run_${ts}.log"
FOUND="found.txt"
: > "$LOG"

if [[ ! -x "$WIFSOLVER" ]]; then
  echo "Error: solver not executable at $WIFSOLVER" >&2
  exit 1
fi

if [[ ! -f "$PART1_FILE" ]]; then
  echo "Error: part1 list file not found: $PART1_FILE" >&2
  exit 1
fi

echo "=== WifSolver batch started $(date) ===" | tee -a "$LOG"
echo "Using GPU $GPU_ID, ADDRESS=$ADDRESS, PART2=$PART2" | tee -a "$LOG"

line_no=0
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  ((line_no++)) || true
  part1="${raw%$'\r'}"           # strip possible CR
  [[ -z "$part1" ]] && continue  # skip blank
  [[ "${part1:0:1}" == "#" ]] && continue  # skip comment

  echo -e "\n>>> [$line_no] Trying part1=$part1" | tee -a "$LOG"

  cmd=( "$WIFSOLVER" -part1 "$part1" -part2 "$PART2" -a "$ADDRESS" -gpuId "$GPU_ID" )
  # append extra args if any
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=( $EXTRA_ARGS )
    cmd+=( "${extra[@]}" )
  fi

  # optional timeout
  if (( TIMEOUT_SECONDS > 0 )); then
    runout="$(timeout --preserve-status "$TIMEOUT_SECONDS" "${cmd[@]}" 2>&1 | tee -a "$LOG")" || true
  else
    runout="$("${cmd[@]}" 2>&1 | tee -a "$LOG")" || true
  fi

  # detect success: line containing "WIF key"
  if grep -q "WIF key" <<<"$runout"; then
    echo "HIT with part1=$part1" | tee -a "$LOG"
    {
      echo "----- Hit @ $(date) (part1=$part1) -----"
      grep -E "WIF key|Private key|BTC address|Address" <<<"$runout"
      echo
    } | tee -a "$FOUND"
    if (( STOP_ON_HIT == 1 )); then
      echo "Stopping on first hit. See $FOUND and $LOG"
      exit 0
    fi
  fi

done < "$PART1_FILE"

echo "=== Finished list. No more candidates. ===" | tee -a "$LOG"
exit 1
