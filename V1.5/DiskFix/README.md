# DiskFix

**Read copy-protected DVDs on drives where the kernel cannot do the key handshake.**

> **Legal note.** DiskFix contains no keys and downloads none. Circumventing copy protection can be unlawful, also for private copies (in Austria and Germany the private copy exception does not cover it). This is not legal advice, check your own situation.

DiskFix is the "disc reading" half that RiftLink used to carry. It is a separate script, `DiskFix.sh`, so that it works for drives behind RiftLink **and** for drives plugged into the PC directly.

## Two ways to use it

1. **Run it** (`bash DiskFix.sh`): a menu to check a drive, check a Blu-ray key entry and open a shell with the fix. It needs no arguments.
2. **Let another script use it.** Archive&Restore sources `DiskFix.sh` (it has to sit in the same folder) and runs every archive command through `FixRun <device> <command...>`. `FixRun` tests the drive first and preloads the library only when the kernel really cannot do the handshake, so normal drives are left alone.

Nothing is installed permanently. The library lives in `/run/DiskFix/` (as root) or in `$XDG_RUNTIME_DIR/DiskFix/` (as a normal user) and is removed when the script ends. `gcc` is needed to build it; it is installed with pacman if missing.

## Why a fix is needed

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

DiskFix works around it with a small preload library (`dvdfix.so`). It sends the same authentication commands as the kernel would, directly to the drive. It is built from source embedded in the script when it is needed and removed on exit.

- Menu entry **Check the disk fix on a drive** runs the first authentication steps on a drive, once without and once with the fix, and tells you whether it works. It recognises empty drives, CDs and Blu-rays and says so instead of failing.
- Menu entry **Open a shell with the disk fix** starts your shell with the library preloaded. Everything started from it (`dvdbackup`, `vobcopy`, VLC, ...) can read protected discs.
- Other programs: `<runtime folder>/run-with-fix <program> <arguments>` (`/run/DiskFix/` as root, otherwise `$XDG_RUNTIME_DIR/DiskFix/`).
- Debug output of the library: `DISKFIX_DEBUG=1`.

With the fix, discs the drive can read rip completely over the cable. `L-EC uncorrectable error` / `Medium Error` in `dmesg` are read errors reported by the drive itself, not authentication problems: `dvdbackup` reports such spots and pads them with zeros, `ddrescue` also reports read errors for the disc tested so far. In at least one earlier test `scrambled sector` appeared again, which is not explained yet. All tests, results and open questions are in `NOTES-Ripping-Protected-Discs.md`.

Blu-rays do not need the fix: `libbluray` and `libaacs` talk to the drive directly. The menu entry **Check a Blu-ray** computes the disc ID and tells you whether your own `~/.config/aacs/KEYDB.cfg` has an entry with keys for it (it also points out missing packages and a wrong file name case). It only looks the disc up in that file; DiskFix never downloads keys. See the Blu-ray part of the notes.

Programs started outside the shell (for example from a launcher or a file manager) do not use the fix.

---


## Files

| File | Purpose |
|---|---|
| `DiskFix.sh` | The whole tool |
