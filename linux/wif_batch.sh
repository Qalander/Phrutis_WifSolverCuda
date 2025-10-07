#!/usr/bin/env bash
set -euo pipefail

# ===== CONFIG =====
WIFSOLVER="./wifSolver"                 # compiled binary
PART1_FILE="part1_list.txt"             # one Base58 per line; blanks/# ignored
PART2="5bCRZhiS5sEGMpmcRZdpAhmWLRfMmutGmPHtjVob"   # your fixed tail
ADDRESS="1PfNh5fRcE9JKDmicD2Rh3pexGwce1LqyU"
DEVICE_ID=""                            # leave empty to use default GPU 0; set e.g. "1" to pass -d 1
EXTRA_ARGS=""                           # e.g. "-t 4096"
STOP_ON_HIT=1                           # 1 stop on first success; 0 keep going
TIMEOUT_SECONDS=0                       # 0 = no per-run timeout
CHECKPOINT_FILE=".wif_batch.chk"        # 1-based index to resume from
SHOW_EVERY=50                           # batch progress line every N candidates
# ===== END CONFIG =====

[[ -x "$WIFSOLVER" ]] || { echo "Error: $WIFSOLVER not executable"; exit 1; }
[[ -f "$PART1_FILE" ]] || { echo "Error: $PART1_FILE not found"; exit 1; }

TOTAL=$(grep -vE '^\s*(#|$)' "$PART1_FILE" | wc -l | awk '{print $1}')
(( TOTAL>0 )) || { echo "No candidates in $PART1_FILE"; exit 1; }

ts="$(date +%Y%m%d_%H%M%S)"
LOG="run_${ts}.log"
FOUND="found.txt"
: > "$LOG"

have(){ command -v "$1" >/dev/null 2>&1; }
run_with_tty(){
  if have script; then
    script -q -f -c "$(printf '%q ' "$@")" /dev/null
  elif have unbuffer; then
    unbuffer -p -- "$@"
  else
    "$@"
  fi
}

START_INDEX=1
if [[ -f "$CHECKPOINT_FILE" ]]; then
  read -r START_INDEX < "$CHECKPOINT_FILE" || START_INDEX=1
  [[ -z "${START_INDEX:-}" ]] && START_INDEX=1
fi
(( START_INDEX>=1 && START_INDEX<=TOTAL+1 )) || START_INDEX=1

echo "=== WifSolver batch started $(date) ===" | tee -a "$LOG"
echo "ADDRESS=$ADDRESS  PART2=$PART2  TOTAL=$TOTAL  RESUME_FROM=$START_INDEX" | tee -a "$LOG"
[[ -n "$DEVICE_ID" ]] && echo "Using GPU device -d $DEVICE_ID" | tee -a "$LOG"

batch_start=$(date +%s)
processed=0
hits=0
idx=$START_INDEX

# Stream lines starting at START_INDEX
awk -v skip="$START_INDEX" '
  { sub(/\r$/,"") }
  /^[[:space:]]*$/ {next}
  /^[[:space:]]*#/ {next}
  { kept[++n]=$0 }
  END{ for(i=skip;i<=n;i++) print kept[i] }
' "$PART1_FILE" | while IFS= read -r part1; do
  processed=$((processed+1))

  if (( processed==1 || processed % SHOW_EVERY == 0 )); then
    now=$(date +%s); elapsed=$((now-batch_start))
    if (( processed>1 )); then
      spc=$(awk -v e="$elapsed" -v p="$processed" 'BEGIN{printf("%.3f", e/(p-1))}')
      remain=$(( TOTAL-(idx-1) ))
      eta=$(awk -v r="$remain" -v s="$spc" 'BEGIN{printf("%.0f", r*s)}')
      eta_h=$(awk -v x="$eta" 'BEGIN{printf("%.2f", x/3600.0)}')
    else spc="N/A"; eta_h="N/A"; fi
    pct=$(awk -v i="$idx" -v t="$TOTAL" 'BEGIN{printf("%.2f", (i-1)*100.0/t)}')
    echo -e "\n[Batch] idx=$idx/$TOTAL (${pct}%) processed=$processed avg=${spc}s/cand ETA~${eta_h}h" | tee -a "$LOG"
  fi

  echo ">>> [$idx] part1=$part1" | tee -a "$LOG"

  cmd=( "$WIFSOLVER" -part1 "$part1" -part2 "$PART2" -a "$ADDRESS" )
  [[ -n "$DEVICE_ID" ]] && cmd+=( -d "$DEVICE_ID" )
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=( $EXTRA_ARGS ); cmd+=( "${extra[@]}" )
  fi

  if (( TIMEOUT_SECONDS > 0 )); then
    ( set +e
      timeout --preserve-status "$TIMEOUT_SECONDS" bash -c '
        have(){ command -v "$1" >/dev/null 2>&1; }
        if have script; then script -q -f -c "$(printf "%q " "$@")" /dev/null;
        elif have unbuffer; then unbuffer -p -- "$@";
        else "$@"; fi
      ' _ "${cmd[@]}" 2>&1 | tee -a "$LOG"
      exit 0
    )
  else
    ( set +e
      run_with_tty "${cmd[@]}" 2>&1 | tee -a "$LOG"
      exit 0
    )
  fi

  # detect success by checking the last chunk of this run in the log
  if tail -n 300 "$LOG" | grep -q "WIF key"; then
    hits=$((hits+1))
    {
      echo "----- Hit @ $(date) (idx=$idx/$TOTAL, part1=$part1) -----"
      tail -n 400 "$LOG" | grep -E "WIF key|Private key|BTC address|Address"
      echo
    } | tee -a "$FOUND"
    echo $((idx+1)) > "$CHECKPOINT_FILE"
    if (( STOP_ON_HIT == 1 )); then
      echo "Stopping on first hit. See $FOUND and $LOG"
      exit 0
    fi
  fi

  echo $((idx+1)) > "$CHECKPOINT_FILE"
  idx=$((idx+1))
done

echo "=== Done. processed=$processed / $TOTAL, hits=$hits ===" | tee -a "$LOG"
exit $(( hits>0 ? 0 : 1 ))
