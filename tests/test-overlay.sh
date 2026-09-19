#!/usr/bin/env bash
# =============================================================================
# Behavioural tests for flows/embedded/overlay.py.
#
# The real input comes out of the hardware handoff, which needs the AMD
# toolchain and a routed design, so the transformations that decide whether the
# board accepts the overlay cannot be checked by running the flow. The generated
# tree is the only thing the script reads, so a tree is what gets stubbed: two
# fixtures in the shape the generator emits, one per accelerator, and the
# assertions read the .dtso back. No toolchain, no container, no board.
#
#   bash tests/test-overlay.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/flows/embedded/overlay.py}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0

check() {
  local name="$1" ok="$2"
  if [[ "$ok" == yes ]]; then
    echo "  ok   $name"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    fail=$((fail + 1))
  fi
}

# How the IP node spells a property holding two interrupts. `flat` is what a
# 2026.1 tree was measured to carry — every cell in one <...> group, not one
# group per interrupt; `grouped` is the same property written the other way.
SPEC_STYLE=flat

# The generated tree, in the shape the device-tree generator emits it: one
# amba_pl container, the accelerator, and the DMA with a sub-node per connected
# channel. The channel interrupts are deliberately the numbers the generator
# invents rather than the ones the block design drives — aligning them is the
# transformation under test.
pl_dtsi() {
  local ip="$1" compat="$2" channels="$3" out="$4"
  local names specs

  if [[ "$channels" == s2mm ]]; then
    names='"mm2s_introut", "s2mm_introut"'
    if [[ "$SPEC_STYLE" == grouped ]]; then
      specs='<0 89 4>, <0 90 4>'
    else
      specs='< 0 89 4 0 90 4 >'
    fi
  else
    names='"mm2s_introut"'
    specs='<0 89 4>'
  fi

  cat > "$out" <<DTSI
/dts-v1/;
/ {
	amba_pl: amba_pl@0 {
		#address-cells = <2>;
		#size-cells = <2>;
		compatible = "simple-bus";
		ranges;
		accel: $ip@a0000000 {
			clock-names = "aclk";
			clocks = <&zynqmp_clk 71>;
			compatible = "$compat";
			reg = <0x0 0xa0000000 0x0 0x10000>;
			xlnx,ip-name = "$ip";
		};
		axi_dma_0: dma@a0010000 {
			#dma-cells = <1>;
			clock-names = "s_axi_lite_aclk", "m_axi_mm2s_aclk";
			clocks = <&zynqmp_clk 71>, <&zynqmp_clk 71>;
			compatible = "xlnx,axi-dma-7.1", "xlnx,axi-dma-1.00.a";
			interrupt-names = $names;
			interrupt-parent = <&imux>;
			interrupts = $specs;
			reg = <0x0 0xa0010000 0x0 0x1000>;
			xlnx,ip-name = "axi_dma";
			dma-channel@a0010000 {
				compatible = "xlnx,axi-dma-mm2s-channel";
				interrupt-parent = <&imux>;
				interrupts = <0 101 4>;
				xlnx,datawidth = <0x10>;
			};
DTSI

  if [[ "$channels" == s2mm ]]; then
    cat >> "$out" <<'DTSI'
			dma-channel@a0010030 {
				compatible = "xlnx,axi-dma-s2mm-channel";
				interrupt-parent = <&imux>;
				interrupts = <0 102 4>;
				xlnx,datawidth = <0x08>;
			};
DTSI
  fi

  cat >> "$out" <<'DTSI'
		};
	};
};
DTSI
}

# The interrupt specifier of the first node whose text mentions `want`.
channel_interrupt() {
  python3 - "$1" "$2" <<'PY'
import re, sys
text, want = open(sys.argv[1]).read(), sys.argv[2]
at = text.index(want)
print(re.search(r"interrupts\s*=\s*<([^>]*)>", text[at:]).group(1).strip())
PY
}

run_overlay() {
  local ip="$1" compat="$2" channels="$3" top="$4"
  pl_dtsi "$ip" "$compat" "$channels" "$WORK/pl.dtsi"
  rm -f "$WORK/out.dtso"
  python3 "$SCRIPT" "$WORK/pl.dtsi" "$WORK/out.dtso" "xilinx/app/app.bit.bin" "$top" \
          > "$WORK/stdout" 2> "$WORK/stderr"
}

echo "-- an accelerator that reports through registers (MM2S only)"

run_overlay sparse_cnn_axi xlnx,sparse-cnn-axi-1.0 mm2s sparse_cnn_axi
rc=$?
check "the flow completes" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
check "the amba_pl container does not travel" \
      "$(! grep -q 'simple-bus' "$WORK/out.dtso" && echo yes || echo no)"
check "the children are spliced onto the live tree's bus" \
      "$(grep -q '^&amba {' "$WORK/out.dtso" && echo yes || echo no)"
check "no interrupt is parented on imux" \
      "$(! grep -q 'imux' "$WORK/out.dtso" && echo yes || echo no)"
check "the mm2s channel takes the line the block design drives" \
      "$([[ "$(channel_interrupt "$WORK/out.dtso" mm2s-channel)" == "0 89 4" ]] \
         && echo yes || echo no)"
check "the accelerator is given the DMA's transmit channel" \
      "$(grep -q 'dmas = <&axi_dma_0 0>;' "$WORK/out.dtso" && echo yes || echo no)"
check "and no channel it has no port for" \
      "$(grep -q 'dma-names = "tx";' "$WORK/out.dtso" && echo yes || echo no)"

echo "-- an accelerator that answers on a stream (MM2S and S2MM)"

run_overlay relu_axi xlnx,relu-axi-1.0 s2mm relu_axi
rc=$?
check "the flow completes" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
check "the mm2s channel takes its own line" \
      "$([[ "$(channel_interrupt "$WORK/out.dtso" mm2s-channel)" == "0 89 4" ]] \
         && echo yes || echo no)"
check "the s2mm channel takes its own line, not the next number along" \
      "$([[ "$(channel_interrupt "$WORK/out.dtso" s2mm-channel)" == "0 90 4" ]] \
         && echo yes || echo no)"
check "the accelerator is given both channels" \
      "$(grep -q 'dmas = <&axi_dma_0 0>, <&axi_dma_0 1>;' "$WORK/out.dtso" \
         && echo yes || echo no)"
check "named the way the driver asks for them" \
      "$(grep -q 'dma-names = "tx", "rx";' "$WORK/out.dtso" && echo yes || echo no)"

echo "-- the same two interrupts, one <...> group each"

SPEC_STYLE=grouped
run_overlay relu_axi xlnx,relu-axi-1.0 s2mm relu_axi
rc=$?
SPEC_STYLE=flat
check "the flow completes" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
check "the s2mm channel still takes the second of them" \
      "$([[ "$(channel_interrupt "$WORK/out.dtso" s2mm-channel)" == "0 90 4" ]] \
         && echo yes || echo no)"

echo "-- the accelerator is named by the flow, not by this script"

run_overlay relu_axi xlnx,relu-axi-1.0 s2mm sparse_cnn_axi
rc=$?
check "a tree holding a different accelerator stops the build" \
      "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "and says which one it went looking for" \
      "$(grep -q 'sparse_cnn_axi' "$WORK/stderr" && echo yes || echo no)"

echo "-- references the board's device tree cannot resolve"

pl_dtsi sparse_cnn_axi xlnx,sparse-cnn-axi-1.0 mm2s "$WORK/pl.dtsi"
sed -i 's/<&zynqmp_clk 71>/<\&pl_clk0 0>/' "$WORK/pl.dtsi"
python3 "$SCRIPT" "$WORK/pl.dtsi" "$WORK/out.dtso" "xilinx/app/app.bit.bin" sparse_cnn_axi \
        > "$WORK/stdout" 2> "$WORK/stderr"
rc=$?
check "an unexportable label stops the build rather than the board" \
      "$([[ $rc -ne 0 ]] && echo yes || echo no)"
check "and the message names the label" \
      "$(grep -q 'pl_clk0' "$WORK/stderr" && echo yes || echo no)"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
