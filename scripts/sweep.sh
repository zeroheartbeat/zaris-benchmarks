#!/usr/bin/env bash
# Drive a load ladder for one cell until the SERVER throughput flattens, record the peak.
#   sweep.sh <label> <seed_priv> <nnodes> [secs]
# Appends a row to results/matrix.tsv and prints every ladder point (full transparency).
# A point counts as "server-bound" when the busiest node CPU >= 88%. The recorded peak is
# the highest aggregate ops/sec among server-bound points; if none reach 88%, the peak is the
# highest overall and is flagged CLIENT-BOUND (honest: we could not saturate the server).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
LABEL="$1"; SEED="$2"; N="$3"; SECS="${4:-18}"
OUT="$HERE/../results/matrix.tsv"
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "label\tnodes\tpeak_ops\tpoint\tnode_cpu_mem\tserver_bound" > "$OUT"

# ladder scales with node count (more nodes need more offered load to saturate)
case "$N" in
  1) LADDER=("64 8 50 1" "64 8 100 1" "64 8 100 2") ;;
  2) LADDER=("64 8 100 2" "64 8 100 3" "64 8 150 3" "64 8 200 3") ;;
  *) LADDER=("64 8 100 3" "64 8 150 3" "64 8 200 3" "64 8 300 3") ;;
esac

best_ops=0; best_point=""; best_cpu=""; best_bound="no"
echo "===== SWEEP $LABEL (nodes=$N) ====="
for entry in "${LADDER[@]}"; do
  read -r PIPE THR CONN NCLI <<< "$entry"
  line=$(bash "$HERE/run-point.sh" "$SEED" "$N" "$PIPE" "$THR" "$CONN" "$SECS" "$NCLI")
  echo "$line"
  ops=$(echo "$line" | sed -n 's/.*AGG_OPS=\([0-9]*\).*/\1/p')
  cpu=$(echo "$line" | sed -n 's/.*=> AGG_OPS=[0-9]* | \(.*\)/\1/p')
  # busiest node CPU among n0..n(N-1)
  maxcpu=$(echo "$cpu" | grep -oE '[0-9]+%' | tr -d '%' | sort -rn | head -1)
  [ -z "$maxcpu" ] && maxcpu=0; [ -z "$ops" ] && ops=0
  bound=$([ "$maxcpu" -ge 88 ] && echo "yes" || echo "no")
  # prefer server-bound peaks; among same boundness, highest ops wins
  if { [ "$bound" = "yes" ] && [ "$best_bound" != "yes" ]; } || \
     { [ "$bound" = "$best_bound" ] && [ "$ops" -gt "$best_ops" ]; }; then
    best_ops=$ops; best_point="$entry"; best_cpu="$cpu"; best_bound=$bound
  fi
done
flag=$([ "$best_bound" = "yes" ] && echo "server-bound" || echo "CLIENT-BOUND(not saturated)")
echo -e "$LABEL\t$N\t$best_ops\t$best_point\t$best_cpu\t$flag" >> "$OUT"
echo ">>> PEAK $LABEL: $best_ops ops/s  [$best_point]  $best_cpu  ($flag)"
