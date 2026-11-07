# Ripping copy-protected discs over RiftLink: test log and status

> These notes describe technical behaviour. Read the legal note in the README first: circumventing copy protection can be unlawful, also for private copies.

## Status

- **The first version of this file was wrong. Do not rely on it.** It claimed that reading fails because the disc is mounted on the client. Tests show identical failures unmounted.
- **One real cause was found and is worked around:** the client kernel disables the DVD key ioctls for drives behind iSCSI, so libdvdcss never authenticates. RiftLink builds a small preload library ("DVD fix") that does the authentication itself.
- **With the fix, discs the drive can read rip completely over the cable**: Ice Age 1 (4.7 GiB, all parts, no error messages), LEGO Ninjago Movie (more than 6 GiB, no error messages). Das Kleine Gespenst (13 title sets) starts without errors in three runs but was never run to the end.
- **The Robbi Tobbi disc really has unreadable sectors:** `ddrescue` on the client reports read errors for it (10 after 1.3 GB). The drive cannot read them (`L-EC uncorrectable error`), so `dvdbackup` and `cp` stop there. This is not an authentication problem.
- **Still open:** disc changes and the "ghost disc" (below), what happens when the server connection drops, the speed over WiFi/Tailscale, whether the fix is really needed when the tool is started outside the fix shell, and why `scrambled sector` once reappeared.

## Setup

- Client `trafktux`: Arch Linux, kernel `7.2.14-arch1-1`, `open-iscsi`. Server `archlinux`.
- Drives as seen on the client: `sr0` HL-DT-ST DVDRAM GH24NS95, `sr1` PLEXTOR BD-R PX-B950SA. Target portal `192.168.100.1:3260` (direct cable link through a USB Ethernet interface), later also `100.66.119.9` (Tailscale over a phone hotspot).
- Server exports the drives with LIO and a PSCSI backstore, client uses `iscsi_tcp`. Request size on the client limited to 64 KB.

## Test log

| # | Test | Result |
|---|---|---|
| 1 | Speed test (`dd`) on a protected disc | Stops after about 900 KB at sector 1792: `Read of scrambled sector without authentication`. Raw reads cannot authenticate, so this says nothing about the link. |
| 2 | `dvdbackup`, disc mounted by udisks | Errors from the first block of `VTS_01_0.VOB`. Kernel log: `scrambled sector`. |
| 3 | Same, after `udisksctl unmount` | Identical errors at identical blocks. **Mounting is not the cause.** |
| 4 | `read_ahead_kb` set to 0 (request size 64 KB) | No change. |
| 5 | libdvdcss debug output | `could not get "copyright" information`; all title keys are `00:00:00:00:00`. |
| 6 | Raw SCSI with `sg_raw` on `/dev/sr1` | `READ DVD STRUCTURE` (copyright) works: CSS protected. `REPORT KEY` hands out an authentication ID (AGID). **The link transports these commands fine.** |
| 7 | `/proc/sys/dev/cdrom/info`, `dmesg` | `Can read DVD: 0` for both drives, `scsi-1 drive` in the kernel log. |
| 8 | `sg_modes -p 0x2a` and SCSI logging at login | `MODE SENSE(10)` returns the capability page. The kernel sends `Mode Sense(6)` (`1a 00 2a 00 80 00`) at attach, the drive answers `Invalid command operation code`, the kernel falls back to `scsi-1 drive` and disables the DVD ioctls. |
| 9 | Kernel-side switches | `/proc/scsi/device_info` entry (not listed afterwards), `default_dev_flags=32768`, delete and rescan: no effect. `blacklist` shows `INVALID_BIT(15)`: the old `USE_10_BYTE_MS` flag does not exist in kernel 7.2.14. **No kernel-side switch found.** |
| 10 | DVD fix check, kernel alone vs. with fix | Kernel alone: `Invalid argument` for the copyright query and the authentication. With the fix: both work. |
| 11 | `dvdbackup` with the fix, libdvdcss debug | `authentication established`, `ASF=1`, real title keys for all 6 title sets (before: only zeros). |
| 12 | Full rip with the fix (Robbi Tobbi Disc 1) | Menu (82 MiB) and the first about 3 MiB of the film are read. Then `Fehler beim Lesen von VTS_01_1.VOB bei Block 1684` and onwards. Kernel log: only `L-EC uncorrectable error` / `Medium Error [deferred]`, no `scrambled sector`. Single commands take 6 to 27 seconds. |
| 13 | VLC through the fix, same disc, menu and start of the film | Works, 0 `L-EC` and 0 `scrambled sector` lines. VLC skips or retries unreadable spots. |
| 14 | File manager copy of `VTS_01_1.VOB`, same disc | Read past 85 MiB at about 2.2 MiB/s, then an I/O error. |
| 15 | Drive speed lowered with `SET CD SPEED` | Same failure at the same place. Whether the drive applied the limit was not verified. |
| 16 | LEGO Ninjago Movie (2018), `dvdbackup` with the fix | Complete copy, 4 title sets, more than 6 GiB, no error messages. `dmesg` was not checked. |
| 17 | Ice Age 1 (new disc), first attempt | Reported: only read errors, the speed test quit with an error. **No logs were recorded.** See test 20. |
| 18 | Reported observations | After a restart the first disc once worked without any disc change; changing the disc sometimes made things work, mostly worse. A later test showed `scrambled sector` again (details not recorded). |
| 19 | Reported: WiFi mode "always worked" | Not verified in these tests, see test 25. |
| 20 | Cable, Ice Age 1 right after start, `dvdbackup` in the fix shell | **Complete rip**, 4.7 GiB, all 12 parts, no error messages. |
| 21 | Same disc, four more runs (aborted by hand at 3, 25, 46 and 69 percent) | No errors. Also works while the disc is mounted in the file manager or from the menu, and a file manager copy read about 500 MB. |
| 22 | Same disc taken out and put back by hand | `dvdbackup` works right away. |
| 23 | Robbi Tobbi disc put in by hand | The new disc is recognised, fails at block 1684 (about 3 MiB). On the server the transfer rate dropped to 0.0 MB/s at about 3 MB, then only read errors. Another run: `Error cracking CSS key` for `VTS_06_0` and `VTS_06_1`, rate 0.0 MB/s, unmounting took very long. |
| 24 | Das Kleine Gespenst (13 title sets), cable | Three runs start without errors (aborted at 118, 143, 327 MiB). |
| 25 | WiFi hotspot via Tailscale, both PCs on the same hotspot (device speed test of the hotspot: 45 MB/s down, 26 MB/s up) | Works with Das Kleine Gespenst but slow: 1.6 MB/s at best, usually lower (typed "0.3-5"), key retrieval 7 to 8 s per title set (55 s in total) instead of under 1 s on the cable. Best case seen: 2.2 MB/s (Ice Age menu copy). |
| 26 | Disc swapped while mounted from the menu (udisks) | `dvdbackup` kept reading the old disc (structure of Das Kleine Gespenst). After the client unmounted it in the file manager, the new disc was recognised. |
| 27 | Disc ejected at the drive while the client had it mounted | Reported: the client keeps a phantom disc. VLC on it: the drive is attached again but not mounted, VLC cannot read it. |
| 28 | `ddrescue -n` on the client (cable, fix shell), Robbi disc | 7483 MB disc. After 22 min: 1332 MB rescued (17.8 %), **10 read errors**, 640 kB non-trimmed, 1.0 MB/s average, 1.4 MB/s current. |

## What is established

- The kernel disables the DVD ioctls for these drives (tests 5 to 10); the DVD fix makes the authentication work (10, 11, 13, 20 to 24).
- The SCSI commands pass through iSCSI and PSCSI (test 6). Good discs rip completely over the cable (16, 20).
- Mounting, read-ahead and the drive speed are not the cause of the Robbi failures (3, 4, 15). The read errors are reported by the drive and `ddrescue` sees them too (12, 28).
- A mount that stays while the disc is changed keeps showing the old disc (26). The background watcher now removes such mounts, see below.

## Damaged discs

If `dmesg` shows `L-EC uncorrectable error` / `Medium Error` at the same sectors every time and `ddrescue` reports read errors for them, the drive cannot read those sectors. `dvdbackup` reports such spots and pads them with zeros, `cp` and file managers stop with an I/O error, VLC skips them. For such a disc use `ddrescue` (the image keeps the unreadable parts as gaps), try the other drive, or try the disc on the server without RiftLink to compare.

## Open, not tested

- **Server connection dropped** (server stopped or cable pulled): what happens to the mount, the drive entry and programs that read from it (ghost disc theory). The menu now shows the session state and the background log records it.
- **Request size after disc changes:** the kernel might reset the 64 KB limit when a disc is changed. The background watcher puts it back and logs every case ("request size had been reset to ... KB"). Manual check after a swap: `cat /sys/block/sr1/queue/max_sectors_kb`.
- **WiFi speed:** with 64 KB requests and little read-ahead the speed is roughly 64 KB divided by the round-trip time, so 1.6 MB/s would mean about 40 ms and 0.3 MB/s about 200 ms. Not measured. The internet speed of the hotspot says nothing about the delay between the two PCs. Check `ping -c 10 <server>`, `tailscale ping <server>` and `tailscale status` (direct connection or relay).
- **Is the fix needed?** Run the same disc with a tool started outside the fix shell. Without the fix `scrambled sector` is expected.
- **When `scrambled sector` appears again:** note whether the tool was started through the fix, whether the disc was changed, and the output of `dmesg | grep 'Add. Sense' | sort | uniq -c`.

## Background watcher (client)

Runs while the client is connected, also while a shell is open. Every 2 seconds: keeps disc-change polling on, removes a mount whose disc was removed or replaced, puts the request size back to 64 KB, notes the iSCSI session state. The menu entry **Show what RiftLink corrected in the background** shows `/run/RiftLink-watch.log`.

## How to rip now

1. Connect as usual. RiftLink builds the DVD fix at start (`gcc` is installed if missing).
2. **Open a shell with the DVD fix** and run `dvdbackup -i /dev/srN -M -p -o <folder>` there, or use `/run/RiftLink/run-with-fix <program> <arguments>`.
3. **Check the DVD fix** shows in a few seconds whether the authentication works (it recognises empty drives, CDs and Blu-rays).
4. If a disc behaves oddly after failed attempts, clear stale keys: `rm -rf ~/.dvdcss`.

## Notes

- The raw `dd` speed test cannot read scrambled sectors on a protected disc. Use an unprotected disc for it.
- Check that the request-size limit is active: `cat /sys/block/sr1/queue/max_sectors_kb` prints `64`.
- Mounting is fine for browsing data discs, audio CDs and backups.

---

# Reading Blu-ray discs (AACS)

Blu-rays are not DVDs. `dvdbackup`, `libdvdcss` and the DVD fix above do not apply. Playback and reading go through `libbluray` and `libaacs`.

## Open the disc

Works with the raw device, the mounted disc or an ISO:

```bash
mpv --bluray-device=/dev/sr1 bluray://longest                    # main film, straight from the drive
mpv --bluray-device=/run/media/$USER/<LABEL> bluray://longest    # mounted disc
mpv --bluray-device=/path/to/disc.iso bluray://longest           # ISO file
mpv --bluray-device=/dev/sr1 bluray://                           # whole disc incl. menus (needs Java)
vlc bluray:///dev/sr1                                            # or: Media > Open Disc > Blu-ray, device /dev/sr1
```

`mpv --bluray-device=/dev/sr1` without a `bluray://` URL does nothing and just prints the usage text.

`bluray://longest` is for **playback only**. It is not a backup method. To back up a Blu-ray, always copy the whole disc, see the next section.

## Rules that matter

1. **Never open `BDMV/STREAM/*.m2ts` directly.** The files are encrypted, mpv says `Failed to recognize file format`. Only `bluray://` goes through `libbluray` and `libaacs`.
2. **mpv:** the path goes into `--bluray-device=`. `bluray:///path` is cut to `path` and fails with `Couldn't open Blu-ray device`. **VLC:** the path goes into the URL.
3. **`~/.config/aacs/KEYDB.cfg` is case sensitive.** `keydb.cfg` is silently ignored by `libaacs`.
4. **`Host key / Certificate ... has been revoked by your drive` is only a warning.** It concerns the drive handshake (bus encryption). With a KEYDB entry for the disc, `libaacs` does not need the handshake and playback starts anyway. Do not show it as an error.
5. Menu hangs: BD-J menus need Java (`jre-openjdk`). `bluray://longest` skips the menus.
6. `h264: top block unavailable` lines with a clean picture: ignore. Blocks or green flicker at the same spot every time: disc damage, see "Damaged discs" above.
7. Audio and subtitles: use the track list mpv prints at start. `--alang=deu --slang=deu` is more robust than fixed `--aid` / `--sid` numbers.

## Backing up a Blu-ray (whole disc)

Like `dvdbackup` for DVDs, but for Blu-ray: `bluraybackup` (needs `libbluray`, `libaacs`, and `libbdplus` for BD+ discs) copies the complete disc, decrypted, into a folder:

```bash
bluraybackup -d /dev/sr1 -k ~/.config/aacs/KEYDB.cfg
```

Run it in the output folder. Never use `-m` (main title only). Needs a KEYDB entry (next section). A bit-exact encrypted image of the whole disc without keys: `ddrescue` ISO, see `NOTES-Disc-Types-Backup-Tools.md` sections 3 and 4.

## Does the disc have a KEYDB entry?

The disc ID is the SHA1 of `AACS/Unit_Key_RO.inf`.

```bash
id=$(sha1sum "$MOUNT/AACS/Unit_Key_RO.inf" | cut -d' ' -f1)
grep -qi "0x$id" "$HOME/.config/aacs/KEYDB.cfg" && echo "KEYDB entry found" || echo "no KEYDB entry"
```

RiftLink does this check for you: client menu entry **Check a Blu-ray (key entry in KEYDB.cfg)**. It only looks in your own file and prints no keys.

No entry means playback will not work. `aacs_info <mountpoint> ~/.config/aacs/KEYDB.cfg` prints the disc ID and shows whether libaacs finds the keys.

## Errors

| Symptom | Cause | Fix |
|---|---|---|
| `UDFFindFile /VIDEO_TS/...` | DVD tool on a Blu-ray | use `bluray://` |
| `Failed to recognize file format` on `.m2ts` | encrypted file opened directly | `bluray://` |
| `Can't open .../KEYDB.cfg` | wrong file name case or path | `~/.config/aacs/KEYDB.cfg` |
| `No usable AACS libraries found` | `libaacs` missing or no entry for this disc | install `libaacs`, check entry |
| `Couldn't open Blu-ray device: run/...` | mpv with `bluray:///path` | `--bluray-device=/path bluray://longest` |
| Black screen or stuck menu | BD-J menu without Java | `jre-openjdk` or `bluray://longest` |
| Same sectors fail every run | scratched disc | clean it, try another drive |
| `bluraybackup` fails or the copy is incomplete | no KEYDB entry, BD+ generation not supported, or damaged disc | check entry, install `libbdplus`, fall back to the `ddrescue` ISO |
