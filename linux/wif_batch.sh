#!/usr/bin/env bash
set -euo pipefail

# ======= CONFIG =======
WIFSOLVER="./wifSolver"                  # compiled binary (Linux)
PART1_FILE="part1_list.txt"              # huge list (one Base58 per line)
PART2="5bCRZhiS5sEGMpmcRZdpAhmWLRfMmutGmPHtjVob" # your fixed tail
ADDRESS="1PfNh5fRcE9JKDmicD2Rh3pexGwce1LqyU"
GPU_ID="0"
EXTRA_ARGS=""                            # e.g. "-t 4096"
STOP_ON_HIT=1                            # 1 = stop on first success
TIMEOUT_SECONDS=0                        # 0 = no per-run timeout
CHECKPOINT_FILE=".wif_batch.chk"         # stores next candidate index (1-based)
SHOW_EVERY=50                            # print batch progress line every N candidates
# ===== END CONFIG =====

# --- prerequisites / helpers ---
if [[ ! -x "$WIFSOLVER" ]]; then echo "Error: $WIFSOLVER not executable."; exit 1; fi
if [[ ! -f "$PART1_FILE" ]]; then echo "Error: missing $PART1_FILE"; exit 1; fi

# total candidates (skip blanks and #)
TOTAL=$(grep -vE '^\s*(#|$)' "$PART1_FILE" | wc -l | awk '{print $1}')
if (( TOTAL == 0 )); then echo "No candidates in $PART1_FILE"; exit 1; fi

ts="$(date +%Y%m%d_%H%M%S)"
LOG="run_${ts}.log"
FOUND="found.txt"
: > "$LOG"

# smallest possible TTY wrapper that preserves live status
_have() { command -v "$1" >/dev/null 2>&1; }
run_with_tty() {
  # $@ is the command array
  if _have script; then
    # script is in bsdutils; present on most systems
    script -q -f -c "$(printf '%q ' "$@")" /dev/null
  elif _have unbuffer; then
    unbuffer -p -- "$@"
  else
    # no tty wrapper available; warn once
    if [[ -z "${_TTY_WARNED:-}" ]]; then
      echo "[!] Live status may not render (install 'bsdutils' or 'expect' for script/unbuffer)" | tee -a "$LOG"
      _TTY_WARNED=1
    fi
    "$@"
  fi
}

# resume
START_INDEX=1
if [[ -f "$CHECKPOINT_FILE" ]]; then
  read -r START_INDEX < "$CHECKPOINT_FILE" || START_INDEX=1
  [[ -z "$START_INDEX" ]] && START_INDEX=1
fi

echo "=== WifSolver batch started $(date) ===" | tee -a "$LOG"
echo "GPU=$GPU_ID ADDRESS=$ADDRESS PART2=$PART2 TOTAL=$TOTAL RESUME_FROM=$START_INDEX" | tee -a "$LOG"

# Pre-load candidates into an array (handles big files fine; ~164k lines is small)
# Keep only non-empty, non-comment lines
mapfile -t CANDIDATES < <(grep -vE '^\s*(#|$)' "$PART1_FILE" | sed 's/\r$//')

# timer for ETA
batch_start=$(date +%s)
processed=0
hits=0

# Main loop (1-based index across filtered candidates)
for (( idx=START_INDEX; idx<=TOTAL; idx++ )); do
  part1="${CANDIDATES[idx-1]}"
  ((processed++))

  # batch progress headline (every SHOW_EVERY)
  if (( processed % SHOW_EVERY == 1 || SHOW_EVERY == 1 )); then
    now=$(date +%s)
    elapsed=$(( now - batch_start ))
    # avoid div by zero
    if (( processed > 1 )); then
      # average seconds per candidate
      spc=$(awk -v e="$elapsed" -v p="$processed" 'BEGIN{ printf("%.3f", e/(p-1)) }')
    else
      spc="N/A"
    fi
    remain=$(( TOTAL - (idx-1) ))
    if [[ "$spc" != "N/A" ]]; then
      eta_sec=$(awk -v r="$remain" -v s="$spc" 'BEGIN{ printf("%.0f", r*s) }')
      eta_h=$(awk -v x="$eta_sec" 'BEGIN{ printf("%.2f", x/3600.0) }')
    else
      eta_h="N/A"
    fi
    pct=$(awk -v i="$idx" -v t="$TOTAL" 'BEGIN{ printf("%.2f", (i-1)*100.0/t) }')
    echo -e "\n[Batch] idx=$idx/$TOTAL (${pct}%) | processed=$processed | avg=${spc}s/cand | ETA~${eta_h}h" | tee -a "$LOG"
  fi

  echo ">>> [$idx] Trying part1=$part1" | tee -a "$LOG"

  # Build solver command
  cmd=( "$WIFSOLVER" -part1 "$part1" -part2 "$PART2" -a "$ADDRESS" -gpuId "$GPU_ID" )
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=( $EXTRA_ARGS )
    cmd+=( "${extra[@]}" )
  fi

  # Run with TTY so the solver shows its live status; still tee to log
  if (( TIMEOUT_SECONDS > 0 )); then
    runout="$(timeout --preserve-status "$TIMEOUT_SECONDS" bash -c '
      run_with_tty() { if command -v script >/dev/null; then script -q -f -c "$(printf "%q " "$@")" /dev/null;
        elif command -v unbuffer >/dev/null; then unbuffer -p -- "$@"; else "$@"; fi
      }
      run_with_tty "$@"
    ' _ "${cmd[@]}" 2>&1 | tee -a "$LOG")" || true
  else
    runout="$(run_with_tty "${cmd[@]}" 2>&1 | tee -a "$LOG")" || true
  fi

  # Detect success
  if grep -q "WIF key" <<<"$runout"; then
    ((hits++))
    {
      echo "----- Hit @ $(date) (part1=$part1, idx=$idx/$TOTAL) -----"
      grep -E "WIF key|Private key|BTC address|Address" <<<"$runout"
      echo
    } | tee -a "$FOUND"
    echo "$((idx+1))" > "$CHECKPOINT_FILE"   # next index
    if (( STOP_ON_HIT == 1 )); then
      echo "Stopping on first hit. See $FOUND and $LOG"
      exit 0
    fi
  fi

  # Save checkpoint for resume
  echo "$((idx+1))" > "$CHECKPOINT_FILE"
done

echo "=== Done. Processed $processed candidates, hits=$hits ===" | tee -a "$LOG"
exit $(( hits>0 ? 0 : 1 ))
