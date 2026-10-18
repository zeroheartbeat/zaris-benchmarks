#!/usr/bin/env bash
# Native-protocol sweep (mixed 1:1). Drives concurrency/clients until node CPU saturates.
#   sweep-native.sh <label> <seed_priv> <nnodes>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"
LABEL="$1"; SEED="$2"; N="$3"
OUT="$HERE/../results/matrix.tsv"; mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "label\tnodes\tpeak_ops\tpoint\tnode_cpu_mem\tserver_bound" > "$OUT"

# entries: CONC OPS NCLI PROCS  (total native generators = NCLI*PROCS; ~3 needed to saturate one node)
case "$N" in
  1) LADDER=("2048 4000000 3 1" "4096 4000000 3 1" "2048 4000000 3 2") ;;
  2) LADDER=("2048 5000000 3 2" "3072 6000000 3 2" "2048 6000000 3 3") ;;
  *) LADDER=("3072 7000000 3 3" "2048 7000000 3 4" "4096 8000000 3 3") ;;
esac

best_ops=0; best_point=""; best_cpu=""; best_bound="no"
echo "===== NATIVE SWEEP $LABEL (nodes=$N) ====="
for entry in "${LADDER[@]}"; do
  read -r CONC OPS NCLI PROCS <<< "$entry"
  line=$(bash "$HERE/run-point-native.sh" "$SEED" "$N" "$CONC" "$OPS" "$NCLI" "$PROCS")
  echo "$line"
  ops=$(echo "$line" | sed -n 's/.*MIX_OPS=\([0-9]*\).*/\1/p'); [ -z "$ops" ] && ops=0
  cpu=$(echo "$line" | sed -n 's/.*=> MIX_OPS=[0-9]* | \(.*\)/\1/p')
  maxcpu=$(echo "$cpu" | grep -oE '[0-9]+%' | tr -d '%' | sort -rn | head -1); [ -z "$maxcpu" ] && maxcpu=0
  bound=$([ "$maxcpu" -ge 88 ] && echo "yes" || echo "no")
  if { [ "$bound" = "yes" ] && [ "$best_bound" != "yes" ]; } || \
     { [ "$bound" = "$best_bound" ] && [ "$ops" -gt "$best_ops" ]; }; then
    best_ops=$ops; best_point="conc$CONC x${NCLI}cli x${PROCS}proc"; best_cpu="$cpu"; best_bound=$bound
  fi
done
flag=$([ "$best_bound" = "yes" ] && echo "server-bound" || echo "CLIENT-BOUND(not saturated)")
echo -e "$LABEL\t$N\t$best_ops\t$best_point\t$best_cpu\t$flag" >> "$OUT"
echo ">>> PEAK $LABEL: $best_ops ops/s  [$best_point]  $best_cpu  ($flag)"
