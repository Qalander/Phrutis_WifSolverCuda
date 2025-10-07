#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WIFSOLVER="./wifSolver"                 # your compiled binary
WIF_LIST="Arbeitsblatt.txt"  # one WIF pattern with X per line
ADDRESS="1PfNh5fRcE9JKDmicD2Rh3pexGwce1LqyU"        # target BTC address
FIXED_N=41                                                # <-- always use -n 41
DEVICE_ID=""                                              # leave empty to use default GPU; set e.g. "1" to pass -d 1
EXTRA_ARGS=""                                             # e.g. "-turbo 3 -ftime 30"
STOP_ON_HIT=1                                             # 1 = stop on first success; 0 = continue
CHECKPOINT_FILE=".wif_batch_wiflist.chk"
SHOW_EVERY=20
# ==========================

have(){ command -v "$1" >/dev/null 2>&1; }
run_with_tty(){
  if have script;   then script -q -f -c "$(printf '%q ' "$@")" /dev/null
  elif have unbuffer; then unbuffer -p -- "$@"
  else "$@"; fi
}

[[ -x "$WIFSOLVER" ]] || { echo "Error: $WIFSOLVER not executable"; exit 1; }
[[ -f "$WIF_LIST"   ]] || { echo "Error: $WIF_LIST not found"; exit 1; }

TOTAL=$(awk '{gsub(/\r$/,"")} /^[[:space:]]*$/ {next} /^[[:space:]]*#/ {next} {c++} END{print c+0}' "$WIF_LIST")
(( TOTAL>0 )) || { echo "No candidates in $WIF_LIST"; exit 1; }

ts="$(date +%Y%m%d_%H%M%S)"
LOG="run_${ts}.log"
FOUND="found.txt"
: > "$LOG"

START_IDX=1
[[ -f "$CHECKPOINT_FILE" ]] && read -r START_IDX < "$CHECKPOINT_FILE" || true
[[ -z "${START_IDX:-}" ]] && START_IDX=1

echo "=== WifSolver batch started $(date) ===" | tee -a "$LOG"
echo "ADDRESS=$ADDRESS  TOTAL=$TOTAL  RESUME_FROM=$START_IDX  N=$FIXED_N" | tee -a "$LOG"
[[ -n "$DEVICE_ID" ]] && echo "Using device -d $DEVICE_ID" | tee -a "$LOG"

batch_start=$(date +%s)
idx=0
line_no=0
hits=0

awk '
  { gsub(/\r$/,"") }
  /^[[:space:]]*$/ {next}
  /^[[:space:]]*#/ {next}
  { print }
' "$WIF_LIST" | while IFS= read -r pattern; do
  line_no=$((line_no+1))
  (( line_no < START_IDX )) && continue
  idx=$line_no

  # progress line
  if (( (idx-START_IDX)%SHOW_EVERY == 0 )); then
    now=$(date +%s); elapsed=$((now-batch_start))
    done_ct=$((idx-START_IDX)); (( done_ct<1 )) && done_ct=1
    spc=$(awk -v e="$elapsed" -v d="$done_ct" 'BEGIN{ printf("%.3f", e/d) }')
    pct=$(awk -v i="$idx" -v t="$TOTAL" 'BEGIN{ printf("%.2f", (i*100.0)/t) }')
    rem=$(( TOTAL-idx ))
    eta_h=$(awk -v r="$rem" -v s="$spc" 'BEGIN{ printf("%.2f", (r*s)/3600.0) }')
    echo -e "\n[Batch] idx=$idx/$TOTAL (${pct}%) avg=${spc}s/cand ETA~${eta_h}h" | tee -a "$LOG"
  fi

  echo ">>> [$idx] -wif '$pattern'  (using -n $FIXED_N)" | tee -a "$LOG"

  cmd=( "$WIFSOLVER" -wif "$pattern" -n "$FIXED_N" -a "$ADDRESS" )
  [[ -n "$DEVICE_ID" ]] && cmd+=( -d "$DEVICE_ID" )
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=( $EXTRA_ARGS ); cmd+=( "${extra[@]}" )
  fi

  ( set +e; run_with_tty "${cmd[@]}" 2>&1 | tee -a "$LOG"; exit 0 )

  # detect success
  if tail -n 400 "$LOG" | grep -q "WIF key"; then
    hits=$((hits+1))
    {
      echo "----- Hit @ $(date) (line $idx) -----"
      tail -n 500 "$LOG" | grep -E "WIF key|Private key|BTC address|Address"
      echo
    } | tee -a "$FOUND"
    echo $((idx+1)) > "$CHECKPOINT_FILE"
    (( STOP_ON_HIT==1 )) && { echo "Stopping on first hit."; exit 0; }
  fi

  echo $((idx+1)) > "$CHECKPOINT_FILE"
done

echo "=== Done. processed=$idx / $TOTAL, hits=$hits ===" | tee -a "$LOG"
exit $(( hits>0 ? 0 : 1 ))