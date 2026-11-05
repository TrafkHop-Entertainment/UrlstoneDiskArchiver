# Disc types, backup strategy, tools and scope

Companion to `NOTES-Ripping-Protected-Discs.md`, which only covers *reading* protected discs. This file covers everything around it. Nothing here was tested over RiftLink itself.

## 1. Detect the disc type automatically

Never ask the user what is in the drive. Ask udev first (cheap, no mounting), then look at the files.

```bash
detect_disc() {
  local dev=${1:-/dev/sr0} p audio data
  udevadm settle
  p=$(udevadm info --query=property --name="$dev" 2>/dev/null) || { echo unknown; return; }
  grep -q '^ID_CDROM_MEDIA=1' <<<"$p" || { echo empty; return; }
  grep -q '^ID_CDROM_MEDIA_STATE=blank' <<<"$p" && { echo blank; return; }
  if   grep -q '^ID_CDROM_MEDIA_BD=1'  <<<"$p"; then echo bd
  elif grep -q '^ID_CDROM_MEDIA_DVD=1' <<<"$p"; then echo dvd
  elif grep -q '^ID_CDROM_MEDIA_CD=1'  <<<"$p"; then
    audio=$(sed -n 's/^ID_CDROM_MEDIA_TRACK_COUNT_AUDIO=//p' <<<"$p")
    data=$(sed -n 's/^ID_CDROM_MEDIA_TRACK_COUNT_DATA=//p'  <<<"$p")
    if   [ "${audio:-0}" -gt 0 ] && [ "${data:-0}" -eq 0 ]; then echo cd-audio
    elif [ "${audio:-0}" -gt 0 ]; then echo cd-mixed
    else echo cd-data; fi
  else echo unknown; fi
}
```

Second step for `dvd` and `bd`: mount read-only (`udisksctl mount -b /dev/sr0`, the path is printed; or `findmnt -n -o TARGET /dev/sr0` if already mounted) and look at the top level:

| Found on disc | Meaning |
|---|---|
| `VIDEO_TS/` | DVD-Video (usually CSS protected, see the DVD sections above) |
| `BDMV/` | Blu-ray video |
| `BDMV/` + `AACS/` | Blu-ray with AACS protection (almost all commercial discs) |
| `BDMV/index.bdmv` starts with `BDMV0300` (`head -c 8`) | Ultra HD Blu-ray (AACS 2.0). Check this on a real UHD disc before relying on it |
| none of the above | plain data disc |

Notes:

- `ID_CDROM_MEDIA_*` is only valid after the drive has finished spinning up. `udevadm settle` plus a short retry loop (a few seconds) avoids "empty" false alarms.
- A CD-Extra / mixed-mode disc reports audio and data tracks. Treat it as `cd-audio` for the audio part and ask the user if the data session should be saved too.
- Do not call the Blu-ray tools on a DVD or the DVD tools on a Blu-ray. `dvdbackup` on a Blu-ray fails with `UDFFindFile /VIDEO_TS/VIDEO_TS.IFO failed` and can segfault.

## 2. What to do per disc type

| Disc | 1:1 backup | Play the backup | Notes |
|---|---|---|---|
| Audio CD | `cdrdao read-cd --read-raw --datafile disc.bin --device /dev/sr0 disc.toc` (exact image) or `cdparanoia -B` (WAV per track) | any player, or burn `disc.bin`/`disc.toc` with `cdrdao write` | Use a different drive if `cdparanoia` reports many skips |
| Data CD / DVD / BD | `ddrescue` to ISO (section 3) | `udisksctl loop-setup -r -f disc.iso`, then browse | No keys involved |
| DVD-Video, unprotected | `ddrescue` to ISO or `dvdbackup -M` | mpv/VLC on the folder or ISO (`dvd://`) | |
| DVD-Video, CSS | `dvdbackup` with the fix (see above) | mpv/VLC on the `VIDEO_TS` folder | Raw `ddrescue` of a CSS disc fails on scrambled sectors, that is why `dvdbackup` is used |
| Blu-ray, no AACS | `bluraybackup` (whole disc to a folder, section 4) or `ddrescue` to ISO (section 3) | `mpv --bluray-device=<folder or iso> bluray://longest` | Always the whole disc, never just the main title |
| Blu-ray, AACS | `bluraybackup` (the `dvdbackup` counterpart: **whole disc**, decrypted, needs a KEYDB entry) and/or `ddrescue` to ISO (bit-exact, stays encrypted, needs no keys) | see `NOTES-Ripping-Protected-Discs.md` (Blu-ray section) | Playback of either copy needs a KEYDB entry |
| Blu-ray with BD+ | `ddrescue` ISO always works; `bluraybackup` additionally needs `libbdplus` | needs `libbdplus` on top | Mostly discs from about 2008 to 2012. Not every BD+ generation is supported |
| Ultra HD Blu-ray | not supported | not supported | AACS 2.0 and drive firmware restrictions, `libaacs` cannot do it |

A backup always means the **complete disc**: every file and every title, not only the main film. Never use `bluraybackup -m` (main title only) and never rely on `bluray://longest` for backups. `longest` is a *playback* shortcut and has nothing to do with backing up.

Important difference between DVD and Blu-ray: on a CSS DVD the drive refuses raw reads of scrambled sectors, so a raw copy fails. On an AACS Blu-ray the drive hands out the (still encrypted) data, so a raw ISO copy works and needs no keys. Playing straight from `/dev/sr1` and from the mounted disc both work on the test drive. A raw `ddrescue` run over RiftLink is still to be verified.

## 3. 1:1 image of Blu-ray and data discs (ISO)

```bash
# pass 1: fast, skip hard areas
sudo ddrescue -b 2048 -n -c 32 /dev/sr0 "$OUT/disc.iso" "$OUT/disc.map"
# pass 2: retry bad areas with direct access
sudo ddrescue -b 2048 -d -r3 -c 32 /dev/sr0 "$OUT/disc.iso" "$OUT/disc.map"
# check: exit code 0 means no bad areas left
ddrescuelog -D "$OUT/disc.map"
```

- This copies every sector of the disc, so it is always the whole disc. On an AACS Blu-ray the ISO stays encrypted. It is the exact image, but it is only playable with a KEYDB entry.
- Sector size is 2048 for every optical disc. `-c 32` keeps requests at 64 KiB, matching the RiftLink limit above. On a local drive the default cluster size is fine.
- The `.map` file makes the run resumable. Keep it next to the ISO until the check passes.
- Put every disc in its own folder (`<Restored>/<disc label>/`), so several discs can live side by side. Take the label from `blkid -s LABEL -o value /dev/sr0` and fall back to a timestamp if it is empty or already exists.
- Free space: a dual-layer Blu-ray is about 50 GB. Check `df` against `blockdev --getsize64 /dev/sr0` before starting.
- Do not delete a half-finished ISO on failure, resuming is the whole point.

## 4. Blu-ray folder backup with `bluraybackup` (the `dvdbackup` counterpart)

`bluraybackup` is to Blu-ray what `dvdbackup` is to DVD. It uses `libbluray` (plus `libaacs` and, for BD+ discs, `libbdplus`) and copies the **whole disc tree** into a folder, decrypted. Without a file argument it copies everything.

```bash
# whole disc into the current folder (default device /dev/sr0, default key file ~/.config/aacs/KEYDB.cfg)
bluraybackup -d /dev/sr0 -k ~/.config/aacs/KEYDB.cfg
# older 1.x versions use positional arguments instead:
bluraybackup /dev/sr0 ~/.config/aacs/KEYDB.cfg
```

- Package name `bluraybackup` (Debian/Ubuntu, in the Arch AUR). Needs `libbluray`, `libaacs`, and `libbdplus` for BD+ discs.
- Do not use `-m`: it copies only the main title.
- Passing a file path (relative to the disc root) extracts one file only. Not for backups.
- Needs a KEYDB entry for the disc. Without one it cannot decrypt. Use the `ddrescue` ISO from section 3 then.
- Upstream says it may not work with every disc, depends on the KEYDB and the BD+ generation, and that the copy may not be exact if `libbluray` reports errors. For a bit-exact result keep the `ddrescue` ISO as well.
- Not tested over RiftLink yet. Check `max_sectors_kb` (64) as for the other tools. Check afterwards that the output folder contains `BDMV/` and that `mpv --bluray-device=<folder> bluray://longest` starts (to verify on a real disc).
- Exit code 0 means the whole disc was copied, 1 means anything else.

## 5. KEYDB, certificates and legal scope

- The tool does **not** ship, download or update a key database and does not try host certificates or drive firmware tricks. If `~/.config/aacs/KEYDB.cfg` exists, `libaacs` and `bluraybackup` use it (see the reading notes). Without it the tool says where the file has to be placed, skips the decrypted copy and offers the encrypted `ddrescue` ISO instead.
- Reason: a 1:1 copy of a disc is one thing, supplying decryption keys for protected discs is another. A decrypted copy (`bluraybackup`) circumvents the protection, the encrypted ISO does not. In Austria and Germany the private copy exception does not allow circumventing an effective copy protection (UrhG §90c in Austria, §95a UrhG in Germany). This is not legal advice, check your own situation.
- Do not add host certificate (`HC`) lines to the KEYDB. Drives revoke them, it does not help, and it is the reason for the `revoked` warning above.
- Do not point users to MakeMKV or LibreDrive flashing as a default. Flashing drive firmware can brick the drive.

