# The Vivado container is given the build host's X socket

Vivado's GUI is needed for block design and for reading implementation reports,
and the build host is reached over RustDesk, which mirrors the host's own `:0`
display. So the container mounts `/tmp/.X11-unix` and sets `DISPLAY=:0`: the GUI
draws onto the host desktop and RustDesk shows it with no extra moving parts.
This requires relaxing X access control on the host (`xhost +local:`), which is
a deliberate security concession and not an oversight — it is recorded here so
that it is not "fixed" by someone who assumes otherwise.

## Consequences

Any process in the container can talk to the host's X server, which on a
single-user workstation is an acceptable trade but would not be on a shared one.
The host's X server runs with `-nolisten tcp`, so this works over the unix
socket only: it holds precisely because the container runs on the same machine
as the display, and it will not extend to running the container elsewhere.

## Considered options

**A VNC server inside the container.** Rejected because it adds a second remote
desktop path to maintain alongside RustDesk, and reaching it from the
workstation segment would require opening an inter-VLAN hole for an unencrypted
protocol.

**Installing Vivado's GUI on the host as well.** Rejected — two installations of
a 100 GB toolchain to avoid one mount.
