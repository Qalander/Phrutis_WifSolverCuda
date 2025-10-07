#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WIFSOLVER="./wifSolver"                 # your compiled binary
WIF_LIST="Arbeitsblatt.txt"  # one WIF pattern with X per line
ADDRESS="1PfNh5fRcE9JKDmicD2Rh3pexGwce1LqyU"        # target BTC address
DEVICE_ID=""                            # leave empty to use default GPU (no -d); set e.g. "1" to use -d 1
EXTRA_ARGS=""                           # e.g. "-turbo 3 -ftime 30"
STOP_ON_HIT=1                           # 1 = stop on first success; 0 = continue
CHECKPOINT_FILE=".wif_batch_wiflist.chk"
SHOW_EVERY=20                           # print batch progress every N lines
# ==========================

# ---- helpers ----
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

# ---- sanity ----
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

echo "=== WifSolver batch started $(date) ==="                  | tee -a "$LOG"
echo "ADDRESS=$ADDRESS TOTAL=$TOTAL RESUME_FROM=$START_IDX"    | tee -a "$LOG"
[[ -n "$DEVICE_ID" ]] && echo "Using device -d $DEVICE_ID"     | tee -a "$LOG"

batch_start=$(date +%s)
idx=0
line_no=0
hits=0

# stream through the file; skip blanks/comments; resume from START_IDX
awk '
  { gsub(/\r$/,"") }
  /^[[:space:]]*$/ {next}
  /^[[:space:]]*#/ {next}
  { print }
' "$WIF_LIST" | \
while IFS= read -r pattern; do
  line_no=$((line_no+1))
  (( line_no < START_IDX )) && continue

  idx=$line_no

  # find first X (1-based index)
  pos=$(awk -v s="$pattern" '
    BEGIN{
      n=split(s,a,"");
      for(i=1;i<=n;i++){
        if(a[i]=="X" || a[i]=="x"){ print i; exit }
      }
      print 0
    }')
  if (( pos==0 )); then
    echo "Skipping line $idx (no X found): $pattern" | tee -a "$LOG"
    echo $((idx+1)) > "$CHECKPOINT_FILE"
    continue
  fi

  # progress line
  if (( (idx-START_IDX)%SHOW_EVERY == 0 )); then
    now=$(date +%s); elapsed=$((now-batch_start))
    done_ct=$((idx-START_IDX))
    pct=$(awk -v i="$idx" -v t="$TOTAL" 'BEGIN{printf("%.2f", (i*100.0)/t)}')
    spc=$(awk -v e="$elapsed" -v d="$done_ct" 'BEGIN{ if(d>0) printf("%.3f", e/d); else print "N/A" }')
    rem=$(( TOTAL-idx ))
    eta_h=$(awk -v r="$rem" -v s="$spc" 'BEGIN{ if(s=="N/A") print "N/A"; else printf("%.2f", (r*s)/3600.0) }')
    echo -e "\n[Batch] idx=$idx/$TOTAL (${pct}%) avg=${spc}s/cand ETA~${eta_h}h" | tee -a "$LOG"
  fi

  echo ">>> [$idx] -wif '$pattern'  (first X at n=$pos)" | tee -a "$LOG"

  # build command
  cmd=( "$WIFSOLVER" -wif "$pattern" -n "$pos" -a "$ADDRESS" )
  [[ -n "$DEVICE_ID" ]] && cmd+=( -d "$DEVICE_ID" )
  if [[ -n "$EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=( $EXTRA_ARGS ); cmd+=( "${extra[@]}" )
  fi

  # run with pseudo-TTY so live status shows; also tee to log
  ( set +e; run_with_tty "${cmd[@]}" 2>&1 | tee -a "$LOG"; exit 0 )

  # detect success by scanning recent log lines
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
