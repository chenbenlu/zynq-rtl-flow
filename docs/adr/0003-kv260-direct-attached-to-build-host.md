# The KV260 is direct-attached to the build host's second NIC

The board needs to be reachable from the build host so bitstreams and firmware
overlays can be pushed to it. Rather than giving it a port on the lab router, it
is cabled straight into a second, previously unused NIC on the build host, on a
private point-to-point segment that exists only between those two machines.

The router has no free port — all eight are in use — so putting the board on the
server VLAN would mean displacing something. The obvious fallback, the
workstation VLAN, has a default-deny rule on server-to-workstation traffic,
which blocks exactly the direction this flow needs: the build host pushing files
*to* the board. Direct attachment sidesteps both, needs no firewall change, and
cannot affect any existing service on a network that has no redundant switch.

## Consequences

The board has no route to the internet and no route to anything but the build
host; installing packages on it means the build host routes or proxies for it,
or the files are carried by hand. The board must sit physically beside the build
host. The private segment is configured on the build host and is not described
anywhere in the lab's network-as-code repo, so `scripts/provision-board-net.sh` is
where it is written down.

That script does not name the NIC, and neither does this record. An interface
name is not what identifies the segment — the address on it is, and `eth0` is
the host's lab link, which is also how the host is administered. Bringing the
link up therefore takes `NIC=` from whoever cabled it; tearing it down finds the
interface by the address it carries and refuses to touch any other.
