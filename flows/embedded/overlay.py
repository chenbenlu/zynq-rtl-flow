# =============================================================================
# Turn the generated PL device tree into a loadable overlay.
# Driven by flows/embedded/overlay.sh.
#
# The node definitions are not written by hand: pl.dtsi comes from the hardware
# handoff, which comes from the block design, so the accelerator's address and
# the DMA's parameters have exactly one source. Hand-copying them here would put
# a second, silently divergent copy of the address map in the repository.
# =============================================================================
import collections
import re
import sys

# stream_client_ip is the accelerator's module name, which is how the generated
# tree identifies its node. It arrives as an argument rather than being written
# here: which module is the accelerator belongs to the flow that built the
# design, and an environment serving a contract has no one accelerator to name.
src, dst, firmware, stream_client_ip = sys.argv[1:5]

# Labels the booted kernel's own device tree exports under __symbols__. A
# reference to anything else resolves against nothing and the overlay is
# rejected at load, reported as the overlay failing to apply rather than as the
# symbol it could not find. Checked here so that a generator which starts
# emitting a new reference stops the build instead of the board.
RESOLVABLE = {"amba", "fpga_full", "gic", "zynqmp_clk", "zynqmp_reset"}

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


def split_node(block):
    """A node block split into its own property text and its sub-node blocks."""
    body = block[block.index("{") + 1 : block.rindex("}")]
    children = child_nodes(body)
    own = body
    for child in children:
        own = own.replace(child, "")
    return own, children


def property_value(text, name):
    match = re.search(r"\b%s\s*=\s*([^;]*);" % name, text)
    return match.group(1) if match else None


# What the two transformations below need to know about an AXI DMA channel: the
# `interrupt-names` entry the owning IP node carries for it, the cell a `dmas`
# entry selects it with, and the name a driver asks for it under. One table, so
# that a third kind of channel cannot be taught to one site and not the other.
DmaChannel = collections.namedtuple("DmaChannel", "interrupt cell name")

DMA_CHANNELS = {
    "xlnx,axi-dma-mm2s-channel": DmaChannel("mm2s_introut", 0, "tx"),
    "xlnx,axi-dma-s2mm-channel": DmaChannel("s2mm_introut", 1, "rx"),
}


def interrupt_specs(own, names):
    """The node's interrupt specifiers, one per entry in interrupt-names.

    Not one per <...> group: the generator writes every cell of a
    multi-interrupt property inside a single group, so a DMA with both channels
    connected emits `interrupts = < 0 89 4 0 90 4 >` and splitting on the
    brackets finds one interrupt where the node declares two. How wide a
    specifier is belongs to the interrupt parent and is not in this file, so it
    comes from there being exactly one per name.
    """
    cells = re.sub(r"[<>,]", " ", property_value(own, "interrupts") or "").split()
    if not names or len(cells) % len(names):
        return []
    width = len(cells) // len(names)
    return [" ".join(cells[i : i + width]) for i in range(0, len(cells), width)]


# An AXI DMA channel is a sub-node of the IP that owns it and shares that IP's
# interrupt, but the generator numbers the two independently: with only mm2s
# connected the IP node gets the line the block design actually drives and the
# channel node gets the next one along, which nothing drives. The driver takes
# the channel's, so it probes and then waits on a wire that never moves — a
# completion timeout, not a probe failure, and nothing in it names the device
# tree. The IP node's number is the trustworthy one because interrupt-names ties
# it to the port on the block design, so each channel takes the entry named for
# its direction rather than a number restated here.
def align_channel_interrupts(block):
    own, children = split_node(block)
    names = re.findall(r'"([^"]*)"', property_value(own, "interrupt-names") or "")
    by_name = dict(zip(names, interrupt_specs(own, names)))
    if not by_name:
        return block

    for child in children:
        compatible = property_value(child, "compatible")
        if compatible is None:
            continue
        wanted = next(
            (DMA_CHANNELS[c].interrupt for c in DMA_CHANNELS if '"%s"' % c in compatible),
            None,
        )
        if wanted is None:
            continue
        if wanted not in by_name:
            sys.exit(
                "%s wants the %s interrupt and the IP node does not carry one"
                % (child.split("{")[0].strip(), wanted)
            )
        fixed = re.sub(
            r"\binterrupts\s*=\s*[^;]*;",
            "interrupts = <%s>;" % by_name[wanted].strip(),
            child,
            count=1,
        )
        block = block.replace(child, fixed)
    return block


# The generator models no connection between two PL IPs, so nothing in the tree
# says the DMA's stream feeds the accelerator — and without a `dmas` property on
# the client the kernel offers no way to ask for that channel. The fact is the
# block design's, not a number restated here: there is one AXI DMA and one
# accelerator, and the stream runs between them. Anything else is a design this
# rule no longer describes, so it stops the build rather than guessing.
#
# Which directions it gets is the block design's answer too. An accelerator that
# reports through registers leaves the DMA's S2MM channel unconnected and the
# generator then emits no sub-node for it, so the channels present in the tree
# are exactly the ones the driver may ask for.
def link_dma_client(nodes):
    def labelled(block):
        match = re.match(r"\s*([A-Za-z_][\w-]*)\s*:", block)
        return match.group(1) if match else None

    dmas = [b for b in nodes if '"xlnx,axi-dma' in (property_value(b, "compatible") or "")]
    clients = [
        b
        for b in nodes
        if (property_value(b, "xlnx,ip-name") or "") == '"%s"' % stream_client_ip
    ]
    if not dmas and not clients:
        return nodes
    if len(dmas) != 1 or len(clients) != 1:
        sys.exit(
            "expected one AXI DMA and one %s to connect the stream between; found"
            " %d and %d" % (stream_client_ip, len(dmas), len(clients))
        )

    label = labelled(dmas[0])
    if label is None:
        sys.exit("the AXI DMA node carries no label to reference it by")

    _, children = split_node(dmas[0])
    channels = sorted(
        (
            DMA_CHANNELS[compatible]
            for child in children
            for compatible in DMA_CHANNELS
            if '"%s"' % compatible in (property_value(child, "compatible") or "")
        ),
        key=lambda channel: channel.cell,
    )
    if not channels:
        sys.exit("the AXI DMA node carries no channel sub-node to connect")

    client = clients[0]
    indent = re.match(r"(\s*)", client.splitlines()[1]).group(1)
    linked = client.replace(
        "{",
        "{\n%sdmas = %s;\n%sdma-names = %s;"
        % (
            indent,
            ", ".join("<&%s %d>" % (label, c.cell) for c in channels),
            indent,
            ", ".join('"%s"' % c.name for c in channels),
        ),
        1,
    )
    return [linked if b is client else b for b in nodes]


# The PL nodes are spliced directly into the live tree's AXI bus rather than kept
# inside pl.dtsi's amba_pl container. An overlay that adds a bus node gets one
# platform device for the bus and none for what is inside it: the kernel creates
# a device per added node and does not recurse into a simple-bus it has just been
# handed. Nested, the accelerator is in the device tree and on no bus; flattened,
# each node is an added node in its own right and gets its device.
nodes = child_nodes(node_body(body, "amba_pl"))
if not any("@" in block.split("{")[0] for block in nodes):
    sys.exit("no addressable nodes under amba_pl — check what the generator emitted")

# The generated tree parents its interrupts on `imux`, a proxy interrupt
# controller the system device tree defines so one tree can serve the A53, R5 and
# PMU domains: it maps every interrupt 1:1 onto whichever GIC the domain has. A
# booted Linux on the A53 has no such node, only `gic`. The specifier is already
# the GIC's three-cell form and the map it passes through is the identity, so
# this is the same interrupt, named the way the running kernel knows it.
nodes = [block.replace("<&imux>", "<&gic>") for block in nodes]
nodes = [align_channel_interrupts(block) for block in nodes]
nodes = link_dma_client(nodes)

defined = {
    label
    for block in nodes
    for label in re.findall(r"^\s*([A-Za-z_][\w-]*)\s*:", block, re.MULTILINE)
}
unresolved = sorted(
    {label for block in nodes for label in re.findall(r"&([A-Za-z_][\w-]*)", block)}
    - RESOLVABLE
    - defined
)
if unresolved:
    sys.exit(
        "the generated tree references labels the board's device tree does not\n"
        "export, so the overlay would be rejected at load: " + ", ".join(unresolved)
    )

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
