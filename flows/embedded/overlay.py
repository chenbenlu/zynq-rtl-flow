# =============================================================================
# Turn the generated PL device tree into a loadable overlay.
# Driven by flows/embedded/overlay.sh.
#
# The node definitions are not written by hand: pl.dtsi comes from the hardware
# handoff, which comes from the block design, so the accelerator's address and
# the DMA's parameters have exactly one source. Hand-copying them here would put
# a second, silently divergent copy of the address map in the repository.
# =============================================================================
import sys

src, dst, firmware = sys.argv[1], sys.argv[2], sys.argv[3]

body = open(src).read()


def node_body(text, label):
    """The text between the braces of the first node whose line mentions label."""
    start = text.index(label)
    open_at = text.index("{", start)
    depth, i = 1, open_at + 1
    while depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return text[open_at + 1 : i - 1]


def child_nodes(text):
    """The sub-node blocks of a node body, dropping that node's own properties.

    The container's properties must not travel: they describe amba_pl, and this
    overlay splices its children somewhere else. Line-based because the device
    tree generator emits one property per line and opens every node on its own.
    """
    blocks, buf, depth = [], [], 0
    for line in text.splitlines():
        if depth == 0:
            if line.rstrip().endswith("{"):
                depth, buf = 1, [line]
            continue
        buf.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            blocks.append("\n".join(buf))
    return blocks


# The PL nodes are spliced directly into the live tree's AXI bus rather than kept
# inside pl.dtsi's amba_pl container. An overlay that adds a bus node gets one
# platform device for the bus and none for what is inside it: the kernel creates
# a device per added node and does not recurse into a simple-bus it has just been
# handed. Nested, the accelerator is in the device tree and on no bus; flattened,
# each node is an added node in its own right and gets its device.
nodes = child_nodes(node_body(body, "amba_pl"))
if not any("@" in block.split("{")[0] for block in nodes):
    sys.exit("no addressable nodes under amba_pl — check what the generator emitted")

with open(dst, "w") as fh:
    fh.write("/dts-v1/;\n/plugin/;\n\n")
    fh.write('&fpga_full {\n\tfirmware-name = "%s";\n};\n\n' % firmware)
    # Restated rather than inherited: inside an overlay fragment dtc cannot see
    # the live tree, so without these it warns that it is guessing. Both match
    # /axi on the board, and the reg entries in pl.dtsi are written for them.
    fh.write("&amba {\n\t#address-cells = <2>;\n\t#size-cells = <2>;\n\n")
    fh.write("\n\n".join(nodes))
    fh.write("\n};\n")

print("overlay source: " + dst)
for block in nodes:
    print("  node: " + block.split("{")[0].strip())
