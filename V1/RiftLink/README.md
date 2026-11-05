# RiftLink

**Plug optical drives into one PC, use them on another.**

RiftLink is the "external drives" half of **UrlstoneDiskArchiver**. It shares the DVD/Blu-ray drives of one Linux PC (the *server*) with a second Linux PC (the *client*) over the network. On the client, the drives show up as normal local optical drives (`/dev/sr0`, `/dev/sr1`, ...), so ripping tools, VLC, file managers and everything else just work, without knowing the drives are somewhere else.

It is a single interactive Bash script. No arguments, no daemon, nothing permanent: when you quit, every change it made is reverted.

> Tested on Arch Linux only.

---

## How it works

RiftLink uses **iSCSI with a pass-through (PSCSI) backstore**:

- The server exports each drive through the in-kernel LIO target (`targetcli`). PSCSI forwards the *real SCSI commands* to the drive instead of just raw blocks.
- The client connects with `open-iscsi`. The kernel creates a genuine SCSI optical drive for each LUN.

That is why eject, disc-change detection and the authentication commands used by DVD/Blu-ray readers work. A plain block-device export (for example NBD) cannot do this.

---

## Requirements

| | Server (has the drives) | Client (wants the drives) |
|---|---|---|
| OS | Arch Linux | Arch Linux |
| Packages | `targetcli-fb` | `open-iscsi`, `udisks2`, `gcc` |
| Kernel modules | `target_core_mod`, `target_core_pscsi`, `iscsi_target_mod` | `iscsi_tcp` |
| Rights | root (the script asks for sudo) | root (the script asks for sudo) |

The script installs missing packages itself (pacman first, AUR as fallback for `targetcli-fb`). `gcc` is only used to build the small DVD fix library at every client start (see *Ripping protected discs*).

You also need a network path between the two PCs. A direct cable is strongly recommended, see below.

---

## Usage

Run the same script on **both** PCs:

```bash
sudo bash RiftLink.sh
```

Everything is done in the menu (arrow keys or `j`/`k`, Enter to select, Space to toggle, `q` to go back).

**1. Server PC**

1. Choose **Server**.
2. Select the drives to share.
3. Choose how the PCs are connected (see *Choosing the link*) and pick the network interface.
4. A status screen shows clients and throughput. Press `q` to stop sharing.

**2. Client PC**

1. Choose **Client**.
2. Choose the same connection type and the matching interface.
3. For a direct link, enter the same address pair as on the server. For an existing network, enter the server's IP.
4. In the menu: mount (read-only), unmount, eject, speed test, copy a DVD to a folder, check the DVD fix, open a shell with the DVD fix, or disconnect.

Quitting either side (menu entry, `q` or Ctrl+C) reverts everything.

> Start the **server first**. The client waits up to 60 seconds for it.

---

## Choosing the link

Speed depends almost entirely on the link, not on RiftLink.

| Link | Notes |
|---|---|
| **Direct cable link** | Recommended. A cable between the two PCs, with private addresses that RiftLink assigns temporarily. |
| **Existing network** | Works over WiFi, LAN or a VPN such as Tailscale. Convenient, but latency matters a lot for optical drives: at 100+ ms, reads crawl and video playback shows artifacts. |

### Cable options

Two PCs cannot simply be joined with a USB A-to-A cable. USB is master/slave: the PC ports are all "host" ports, and two hosts cannot talk to each other (an A-to-A cable can even damage hardware). You need something that makes the link look like a network card:

- **USB4 / Thunderbolt cable**: the kernel creates a `thunderbolt0` network interface. Fastest option. *(Not tested yet.)*
- **Ethernet cable**: between the two network ports, or with a **USB Ethernet adapter** on one side. Gigabit is plenty: an optical drive reads at roughly 10 to 60 MB/s, far below what the link delivers.
- **USB host-to-host bridge cable** (chip in the cable): may work, depends on the chip and kernel driver. RiftLink tries to load `plusb`. Usually not faster than Gigabit Ethernet.

On a direct cable link RiftLink picks a free private range (`192.168.N.x`) and suggests two addresses. Accept the suggestion on the server, and enter the **same pair** on the client.

---

## What RiftLink changes, and what stays

Everything is undone on exit, in reverse order.

| Change | Reverted on exit |
|---|---|
| IP address on the cable interface, interface brought up | yes |
| NetworkManager told to ignore the cable interface | yes (set back to managed) |
| iSCSI target, backstores, portal (kept in kernel memory only, never saved) | yes |
| `targetcli` auto-save preference (disabled while running) | yes |
| `iscsid` started | yes (stopped again if RiftLink started it) |
| iSCSI node record and login session | yes |
| Mounts | yes |
| `/run/RiftLink/` (DVD fix library, built from source embedded in the script) | yes |
| Generated initiator name (only if none existed) | yes |
| Loaded kernel modules | no (not persistent across reboots) |
| Installed packages | no |

The only thing kept on disk is the address you typed in, so it is pre-filled next time:

```
~/.local/share/TrafkHopEntertainment/UrlstoneDiskArchiver/RiftLink.conf
```

---

## Important details

- **Drives are locked on the server while shared.** PSCSI takes exclusive ownership. Quit RiftLink on the server to use the drives locally again.
- **No authentication on the iSCSI target.** The portal is bound only to the link address you chose, so in *direct* mode only the cable partner can reach it. In *existing network* mode **anyone who can reach that address and port 3260 can use the drives.** Use it on networks you trust.
- **Protected discs need the DVD fix.** Start the ripping tool from the menu entry *Open a shell with the DVD fix*, or prefix any program with `/run/RiftLink/run-with-fix`. See *Ripping protected discs*.
- **Request size is limited to 64 KB on the client.** This is essential, see *Troubleshooting*. RiftLink sets it automatically after every login.
- **Mounting** uses `udisksctl` as your normal user, so the drive appears in file managers like Thunar. If that fails, it falls back to a read-only mount under `/mnt/RiftLink/`.
- **Firewall:** the server must allow TCP port 3260 on the link interface.

---

## Troubleshooting

### Reads fail, `dvdbackup`/ripping tools report read errors, server log shows `pSCSI: failed to append bio`

The most important gotcha. The client's iSCSI driver announces a huge maximum request size (about 32 MB), but the real drive behind the server's PSCSI backend only accepts small requests. Big reads fail with `Not Ready / Logical unit communication failure` on the client. Tools then write zeroes instead of data, which looks like fast progress but is garbage.

RiftLink fixes this by limiting requests on the client right after login:

```bash
cat /sys/block/sr1/queue/max_sectors_kb    # should print 64
```

If you log in manually (without RiftLink), set it yourself, for every iSCSI drive:

```bash
echo 64 | sudo tee /sys/block/sr1/queue/max_sectors_kb
echo 64 | sudo tee /sys/block/sr1/queue/read_ahead_kb
```

The value is reset on every new login. If 64 is still too large for your drive, try 32.

### The speed test stops after a few MB (`dd` I/O error)

On copy-protected discs, raw reads fail at the scrambled sectors. The kernel says `Read of scrambled sector without authentication` (`dmesg | tail`). That is expected and not a link problem. Test with a non-protected disc, or with the tool you actually use for reading the disc (e.g. `dvdbackup`, VLC, MakeMKV).

### Clearing a stale key cache

If a reader keeps failing after earlier broken attempts, remove its cached keys, for example `rm -rf ~/.dvdcss`.

### Video plays as colored smear

The link is too slow for the disc's data rate (a DVD needs roughly 1 MB/s or more). Use a direct cable link, or copy the disc first and play the copy.

### The drive does not show up in Thunar

Mount it from the RiftLink menu (it uses udisks). If udisks is not installed on the client, RiftLink installs it on start.

### "An old iSCSI session to this target already exists"

Use **Remove leftovers of old setups** from the main menu, then try again.

### Kernel log: `iSCSI Login negotiation failed`

Harmless. It is logged when the client probes whether the server port is open before logging in.

### The cable interface does not appear

Plug the cable into both PCs first, then use **Rescan interfaces**. For USB4/Thunderbolt the interface only appears once both sides are connected (a `thunderbolt0` interface).

### Checking the link speed

```bash
sudo ethtool <interface> | grep -i speed     # should say 1000Mb/s for Gigabit
lsusb -t                                     # a USB adapter should not sit on a 480M (USB 2.0) port
iperf3 -s -B <server-address>                # on the server
iperf3 -c <server-address>                   # on the client
```

---

## Ripping protected discs

Over iSCSI the client kernel cannot read the capability page of the drive: it sends a 6-byte `MODE SENSE`, which SATA/ATAPI drives reject (locally the SATA driver switches to the 10-byte variant, over iSCSI nothing does). The kernel then logs `scsi-1 drive` and switches off the DVD ioctls (`DVD_READ_STRUCT`, `DVD_AUTH`). libdvdcss needs exactly those to authenticate, so it never does, and the drive refuses scrambled sectors:

```
libdvdcss error: CSS error: could not get "copyright" information
Add. Sense: Read of scrambled sector without authentication
```

Mounting or unmounting does not matter for this. You can see the cause on the client:

```bash
grep 'Can read DVD' /proc/sys/dev/cdrom/info    # 0 for the iSCSI drives
sudo dmesg | grep 'scsi-1 drive'
```

RiftLink works around it with a small preload library (`dvdfix.so`). It sends the same authentication commands as the kernel would, directly to the drive. It is built from source embedded in the script at every client start and removed on exit.

- Menu entry **Copy a DVD to a folder** runs `dvdbackup` with the fix on the chosen drive (installing `dvdbackup` and `libdvdcss` if missing) and tells you at the end whether the drive reported read errors. This is the easiest way to rip.
- Menu entry **Check the DVD fix** runs the first authentication steps on a drive, once without and once with the fix, and tells you whether it works.
- Menu entry **Open a shell with the DVD fix** starts your shell with the library preloaded. Everything started from it (`dvdbackup`, `vobcopy`, VLC, ...) can read protected discs.
- Other programs: `/run/RiftLink/run-with-fix <program> <arguments>`.
- Debug output of the library: `RIFTLINK_DVDFIX_DEBUG=1`.

If a copy fails at the same place every time with `L-EC uncorrectable error` in `dmesg` (and no `scrambled sector` lines), the drive itself cannot read that spot of the disc, usually a scratch or dirt. This is not a link problem. Players such as VLC and file managers skip or retry such spots, `dvdbackup` reports them and fills the gap with zeros. Clean the disc, or try the other drive.

Programs started outside the shell (for example from a launcher or a file manager) do not use the fix.

---

## Cleaning up older setups

The main menu has **Remove leftovers of old setups**. It removes, on the PC you run it on:

- NBD server/client processes and units
- **all** iSCSI sessions and node records, and the iSCSI boot units
- the LIO targets of RiftLink and of the older DiskLink script, and the target boot unit
- empty `/mnt/dvd` and `/mnt/bluray` folders

Run it on both PCs when you switch from an older iSCSI/NBD setup.

---

## Performance

Measured on one setup (DVD drive, direct Gigabit cable link, USB Ethernet adapter on the client): reading over RiftLink was as fast as reading locally on the server, around 10 MB/s at the start of a DVD. The optical drive is the bottleneck, not the link. Over WiFi through a hotspot, the same drive managed about 0.3 to 0.6 MB/s.

---

## Files

| File | Purpose |
|---|---|
| `RiftLink.sh` | The whole tool |
| `~/.local/share/TrafkHopEntertainment/UrlstoneDiskArchiver/RiftLink.conf` | Remembered addresses (created at first run) |

---

## Notes for contributors

- One script, no external dependencies besides the packages listed above.
- Style: PascalCase for functions and variables, English only, general comments only.
- The script is not a daemon. Anything that changes system state must register its undo step with `Defer`.
