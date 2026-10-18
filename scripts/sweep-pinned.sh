#!/usr/bin/env bash
# RESP sweep using pinned-per-owner load (works for N>=1). Drives each node to saturation.
#   sweep-pinned.sh <label> <nnodes>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
LABEL="$1"; N="$2"; SECS="${3:-18}"
OUT="$HERE/../results/matrix.tsv"; mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "label\tnodes\tpeak_ops\tpoint\tnode_cpu_mem\tserver_bound" > "$OUT"

LADDER=("64 8 50" "64 8 100" "64 8 200")   # conns-per-client ladder; each point = 1 memtier/node
best_ops=0; best_point=""; best_cpu=""; best_bound="no"
echo "===== PINNED SWEEP $LABEL (nodes=$N) ====="
for entry in "${LADDER[@]}"; do
  read -r PIPE THR CONN <<< "$entry"
  line=$(bash "$HERE/run-point-pinned.sh" "$N" "$PIPE" "$THR" "$CONN" "$SECS")
  echo "$line"
  ops=$(echo "$line" | sed -n 's/.*AGG_OPS=\([0-9]*\).*/\1/p'); [ -z "$ops" ] && ops=0
  cpu=$(echo "$line" | sed -n 's/.*=> AGG_OPS=[0-9]* | \(.*\)/\1/p')
  mincpu=$(echo "$cpu" | grep -oE '[0-9]+%' | tr -d '%' | sort -n | head -1); [ -z "$mincpu" ] && mincpu=0
  bound=$([ "$mincpu" -ge 88 ] && echo "yes" || echo "no")
  if { [ "$bound" = "yes" ] && [ "$best_bound" != "yes" ]; } || \
     { [ "$bound" = "$best_bound" ] && [ "$ops" -gt "$best_ops" ]; }; then
    best_ops=$ops; best_point="pipe$PIPE thr$THR conn$CONN"; best_cpu="$cpu"; best_bound=$bound
  fi
done
flag=$([ "$best_bound" = "yes" ] && echo "server-bound" || echo "CLIENT-BOUND(not saturated)")
echo -e "$LABEL\t$N\t$best_ops\t$best_point\t$best_cpu\t$flag" >> "$OUT"
echo ">>> PEAK $LABEL (N=$N): $best_ops ops/s  [$best_point]  $best_cpu  ($flag)"
