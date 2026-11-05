# Ripping copy-protected discs over RiftLink

**Short version: start the ripping tool from "Open a shell with the DVD fix" in the client menu.**

## The problem

Without the fix, ripping tools such as `dvdbackup` fail on copy-protected DVDs with errors like:

```
libdvdcss error: CSS error: could not get "copyright" information
Fehler beim Lesen von VTS_01_0.VOB bei Block 1
```

The client kernel log shows:

```
Add. Sense: Read of scrambled sector without authentication
```

## What we know

- Disc, drive and cable are fine. The same disc reads locally on the server.
- The failure is the same with the disc mounted and unmounted.
- With SCSI logging on the client (`echo 13824 > /proc/sys/dev/scsi/logging_level`) the login shows:

  ```
  CDB: Mode Sense(6) 1a 00 2a 00 80 00
  Add. Sense: Invalid command operation code
  [sr0] scsi-1 drive
  ```

  The kernel asks for the drive's capabilities with the 6-byte command, the drive rejects it, and the kernel falls back to a "scsi-1 drive" without DVD support (`Can read DVD: 0` in `/proc/sys/dev/cdrom/info`).
- Without DVD support the kernel refuses the DVD ioctls that libdvdcss uses for authentication. The same commands sent as raw SCSI (`sg_raw`) work over the link, including the copyright query and requesting an authentication ID.
- The device flag that used to force 10-byte `MODE SENSE` (`USE_10_BYTE_MS`, `0x8000`) no longer exists in current kernels, so it cannot be set through `/proc/scsi/device_info` or `default_dev_flags`.

Earlier notes blamed mounted discs. That did not hold up: the same errors appear unmounted.

## What to do

1. Connect as usual. RiftLink builds the DVD fix at start (needs `gcc`, installed automatically).
2. Menu entry **Copy a DVD to a folder** does everything: it starts `dvdbackup` with the fix and reports read errors at the end.
3. Optional: **Check the DVD fix** must say "The fix works". For other tools use **Open a shell with the DVD fix**, or by hand:
   ```bash
   dvdbackup -i /dev/sr1 -M -p -o <output folder>
   ```
   A single program without a shell: `/run/RiftLink/run-with-fix <program> <arguments>`.
4. If a rip fails, clear stale keys from earlier failed attempts and try again: `rm -rf ~/.dvdcss`.

If the check fails, run it again with `RIFTLINK_DVDFIX_DEBUG=1` (the menu entry does this on failure) and look at the commands marked `[dvdfix]`.

## Damaged discs

If `dmesg` shows `L-EC uncorrectable error` / `Medium Error` at the same sectors every time (and no `scrambled sector` lines), the drive cannot read that spot of the disc. A second protected disc (7 GiB, 4 title sets) ripped over RiftLink without a single error, while a scratched 2013 disc failed at the same spot in every run. `dvdbackup` reports such spots and pads them with zeros; VLC and file managers tolerate or retry them. Clean the disc or try the other drive.

## Notes

- Mounting is fine for browsing data discs, audio CDs and backups.
- The raw `dd` speed test cannot read scrambled sectors on a protected disc. Use a non-protected disc for it.
- Make sure the request-size limit is active (`cat /sys/block/sr1/queue/max_sectors_kb` should print `64`). Without it, large reads fail for a different reason, see the main README.

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
