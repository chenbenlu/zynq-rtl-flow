#!/usr/bin/env bash
# =============================================================================
# Sequential equivalence check (SEC).
#
# Proves that two revisions of the RTL implement the same sequential behaviour
# — same outputs for every input sequence — rather than merely passing the same
# directed tests. Backed by Yosys from oss-cad-suite.
#
#   make sec GOLDEN=HEAD                    # working tree vs last commit
#   make sec GOLDEN=HEAD~3 REVISED=HEAD     # two commits
#   make sec GOLDEN=../golden_rtl           # against an out-of-tree checkout
#
# Engines (SEC_ENGINE):
#   eqy    (default) Yosys eqy — partitions both designs at matching register
#          boundaries and discharges each partition to SAT. Fast, and the right
#          tool when the revision keeps the state encoding (retiming, operator
#          rewrites, decode restructuring).
#   miter  Sequential miter + k-induction via sby. Handles designs whose state
#          encoding differs, at the cost of needing the proof to converge.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/rtl_sources.sh

GOLDEN="${GOLDEN:-}"
REVISED="${REVISED:-}"
TOP="${TOP:-$RTL_TOP}"
ENGINE="${SEC_ENGINE:-eqy}"
DEPTH="${SEC_DEPTH:-20}"
OUT="$ROOT/sim/sec"

# oss-cad-suite ships its own verilator/cocotb-config, so it is deliberately
# kept off the global PATH (that would shadow the pinned Verilator v5.042).
# Pull it in here, where only the equivalence tools run.
if [[ -n "${OSS_CAD_SUITE:-}" && -d "$OSS_CAD_SUITE/bin" ]]; then
  PATH="$OSS_CAD_SUITE/bin:$PATH"
fi

if [[ -z "$GOLDEN" ]]; then
  cat >&2 <<'USAGE'
sec: GOLDEN is required — the reference design to prove against.
     A git revision or a directory containing rtl/.

       make sec GOLDEN=HEAD
       make sec GOLDEN=HEAD~3 REVISED=HEAD
       make sec GOLDEN=../golden_rtl SEC_ENGINE=miter

     REVISED defaults to the working tree.
USAGE
  exit 2
fi

need=(yosys)
[[ "$ENGINE" == "eqy" ]] && need+=(eqy)
[[ "$ENGINE" == "miter" ]] && need+=(sby)
for tool in "${need[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "sec: '$tool' not found. Install oss-cad-suite (see docker/Dockerfile)" >&2
    echo "     or set OSS_CAD_SUITE=/path/to/oss-cad-suite." >&2
    exit 127
  fi
done

# Materialise a source spec — a git revision, a directory, or "" for the
# working tree — into $2, and echo the space-separated source paths.
materialise() {
  local spec="$1" dest="$2" src
  rm -rf "$dest"
  mkdir -p "$dest"
  if [[ -z "$spec" ]]; then
    cp -a rtl "$dest/"
  elif [[ -d "$spec" ]]; then
    if [[ -d "$spec/rtl" ]]; then cp -a "$spec/rtl" "$dest/"; else mkdir -p "$dest/rtl" && cp -a "$spec"/*.sv "$dest/rtl/"; fi
  elif git rev-parse --verify --quiet "$spec^{commit}" >/dev/null; then
    git archive "$spec" rtl | tar -x -C "$dest"
  else
    echo "sec: cannot resolve '$spec' as a git revision or a directory" >&2
    exit 2
  fi
  for src in "${RTL_SOURCES[@]}"; do
    [[ -f "$dest/$src" ]] || { echo "sec: '$spec' is missing $src" >&2; exit 2; }
    printf '%s ' "$dest/$src"
  done
}

rm -rf "$OUT"
mkdir -p "$OUT"
GOLD_SRCS="$(materialise "$GOLDEN" "$OUT/gold")"
GATE_SRCS="$(materialise "$REVISED" "$OUT/gate")"

echo ">> SEC top=$TOP engine=$ENGINE depth=$DEPTH"
echo ">>   gold: ${GOLDEN}"
echo ">>   gate: ${REVISED:-<working tree>}"

if [[ "$ENGINE" == "eqy" ]]; then
  cat > "$OUT/sec.eqy" <<EOC
[options]

[gold]
read -sv $GOLD_SRCS
prep -top $TOP

[gate]
read -sv $GATE_SRCS
prep -top $TOP

[strategy sat]
use sat
depth $DEPTH
EOC
  eqy -f -d "$OUT/work" "$OUT/sec.eqy"

elif [[ "$ENGINE" == "miter" ]]; then
  # Both DUTs use synchronous reset with no RTL init value, so an unconstrained
  # miter starts the two copies in *different* arbitrary states and the basecase
  # fails at t=0 for reasons that have nothing to do with equivalence. Zero-init
  # both sides to pin them to a common start state — which also matches how a
  # Zynq FPGA actually brings registers up after configuration.
  cat > "$OUT/miter.ys" <<EOC
read_verilog -sv $GOLD_SRCS
prep -top $TOP -flatten
rename $TOP gold
design -stash gold_d

read_verilog -sv $GATE_SRCS
prep -top $TOP -flatten
rename $TOP gate
design -stash gate_d

design -copy-from gold_d -as gold gold
design -copy-from gate_d -as gate gate
miter -equiv -flatten -make_assert -make_outputs gold gate miter
prep -top miter
setundef -init -zero
write_rtlil $OUT/miter.il
EOC
  yosys -q -s "$OUT/miter.ys"

  cat > "$OUT/sec.sby" <<EOC
[options]
mode prove
depth $DEPTH

[engines]
smtbmc yices

[script]
read_rtlil miter.il
prep -top miter

[files]
$OUT/miter.il
EOC
  sby -f -d "$OUT/work" "$OUT/sec.sby"

else
  echo "sec: unknown SEC_ENGINE '$ENGINE' (expected 'eqy' or 'miter')" >&2
  exit 2
fi

echo "SEC: designs are sequentially equivalent."
echo ">> Report: $OUT/work/"
