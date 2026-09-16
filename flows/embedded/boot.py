# =============================================================================
# Generate the PS-side boot components from the exported hardware handoff.
# Driven by flows/embedded/boot.sh.
#
# XSCT is disabled in 2026.1, so the classic `app create -template {Zynq MP
# FSBL}` recipe has nothing left to run it. This is the Vitis Python console
# (UG1400) that replaced it: one platform component carries the boot BSP, and
# is_pmufw_req plus generate_dtb yield FSBL, the PMU firmware and the system
# device tree together.
# =============================================================================
import os
import shutil
import sys

import vitis

# stdout is redirected to a file (see boot.sh), which makes it block-buffered —
# a run that dies mid-build would otherwise take every line of diagnosis with it.
def say(message):
    print(message, flush=True)


xsa = os.environ["XSA"]
workspace = os.environ["BOOT_WS"]
out_dir = os.environ["BOOT_DIR"]
cpu = os.environ.get("BOOT_CPU", "psu_cortexa53_0")
name = os.environ["BOOT_COMPONENT"]

client = vitis.create_client()
client.set_workspace(workspace)

component = client.create_platform_component(
    name=name,
    hw_design=xsa,
    os="standalone",
    cpu=cpu,
    is_pmufw_req=True,
    generate_dtb=True,
)
component.build()

export = os.path.join(workspace, name, "export", name)
elf_src = os.path.join(export, "sw", "boot")
sdt_src = os.path.join(export, "hw", "sdt")

# build() reports by returning, not by producing: a BSP that was configured and
# never compiled looks like success until bootgen is handed nothing.
missing = [
    p
    for p in (os.path.join(elf_src, "fsbl.elf"), os.path.join(elf_src, "pmufw.elf"))
    if not os.path.isfile(p)
]
if missing:
    sys.exit("boot BSP did not build — missing: " + ", ".join(missing))

for elf in ("fsbl.elf", "pmufw.elf"):
    shutil.copy2(os.path.join(elf_src, elf), os.path.join(out_dir, elf))
    say("component: " + os.path.join(out_dir, elf))

# The device tree is a set of sources that include one another, so the whole
# directory travels rather than the top-level .dts alone.
if os.path.isdir(sdt_src):
    sdt_dst = os.path.join(out_dir, "sdt")
    shutil.rmtree(sdt_dst, ignore_errors=True)
    shutil.copytree(sdt_src, sdt_dst)
    say("component: " + sdt_dst + "/ (system device tree sources)")
else:
    say("warning: no device tree at " + sdt_src)
