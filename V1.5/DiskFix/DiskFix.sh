#!/usr/bin/env bash
# DiskFix (part of UrlstoneDiskArchiver)
# Lets protected DVDs be read on drives where the kernel cannot do the DVD key handshake
# (drives behind iSCSI from RiftLink, some adapters). A small preload library does the
# authentication itself, directly through SG_IO.
#
# Two ways to use it:
#   - Run it for a menu: check a drive, check a Blu-ray key entry, open a shell with the fix.
#   - Source it from another script (Archive&Restore does) and call FixRun <device> <command...>.
#
# Nothing is installed permanently: the library lives in a runtime folder and is removed on exit.
# It contains no keys and downloads none. Circumventing copy protection can be unlawful, also
# for private copies. Check your own situation.

FixDir=""
FixLib=""
FixCheck=""
FixRunner=""
FixReady=0
FixSudo=()
FixUsedRoot=0
SysBlock="/sys/class/block"
DiscMount=""
DiscMountTemp=0
KeyState=""
DiscId=""
PickedDev=""
DriveDevs=()
MenuChoice=0
KeyName=""
CleanupStack=()

Bold=$'\e[1m'; Dim=$'\e[2m'; Reverse=$'\e[7m'; Reset=$'\e[0m'
Red=$'\e[31m'; Green=$'\e[32m'; Yellow=$'\e[33m'

FixHas() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# Helpers for standalone use. A script that sources this file
# already has them and keeps its own.
# ------------------------------------------------------------

DefineStandaloneHelpers() {
    Info() { printf '%s[*]%s %s\n' "$Green" "$Reset" "$*"; }
    Warn() { printf '%s[!]%s %s\n' "$Yellow" "$Reset" "$*"; }
    Fail() { printf '%s[x]%s %s\n' "$Red" "$Reset" "$*"; }

    Pause() {
        printf '\n%sPress any key to continue...%s' "$Dim" "$Reset"
        IFS= read -rsn1
        printf '\n'
    }

    Defer() { CleanupStack+=("$*"); }

    Cleanup() {
        local I
        trap - EXIT INT TERM
        printf '\e[?25h\n'
        for (( I = ${#CleanupStack[@]} - 1; I >= 0; I-- )); do
            eval "${CleanupStack[$I]}" >/dev/null 2>&1
        done
    }

    Header() {
        printf '\e[H\e[2J'
        printf '%s DiskFix %s| read protected discs on any drive%s\n' "$Bold" "$Dim" "$Reset"
        printf '%s----------------------------------------------%s\n\n' "$Dim" "$Reset"
    }

    ReadKey() {
        local Key Rest Rc
        IFS= read -rsn1 ${KeyTimeout:+-t "$KeyTimeout"} Key; Rc=$?
        if (( Rc > 128 )); then KeyName=Tick; return; fi
        (( Rc )) && { KeyName=Quit; return; }
        case $Key in
            $'\e')
                Rest=""
                read -rsn2 -t 0.05 Rest
                case $Rest in
                    '[A') KeyName=Up ;;
                    '[B') KeyName=Down ;;
                    '')   KeyName=Quit ;;
                    *)    KeyName=Other ;;
                esac ;;
            '')    KeyName=Enter ;;
            ' ')   KeyName=Space ;;
            q|Q)   KeyName=Quit ;;
            k)     KeyName=Up ;;
            j)     KeyName=Down ;;
            *)     KeyName=Other ;;
        esac
    }

    Menu() {
        local Title=$1; shift
        local Items=("$@") Count=$# Selected=0 I
        printf '\e[?25l'
        while true; do
            Header
            printf '%b\n\n' "$Title"
            for I in "${!Items[@]}"; do
                if (( I == Selected )); then
                    printf '  %s> %s %s\n' "$Reverse" "${Items[$I]}" "$Reset"
                else
                    printf '    %s\n' "${Items[$I]}"
                fi
            done
            printf '\n%s  Up/Down: move   Enter: select   q: back%s\n' "$Dim" "$Reset"
            ReadKey
            case $KeyName in
                Up)    Selected=$(( (Selected + Count - 1) % Count )) ;;
                Down)  Selected=$(( (Selected + 1) % Count )) ;;
                Enter) MenuChoice=$Selected; printf '\e[?25h'; return 0 ;;
                Quit)  printf '\e[?25h'; return 1 ;;
            esac
        done
    }

    DriveLabel() {
        local Dev=$1 Name=${1##*/} Model Mp Disc Label
        Model=$(cat "$SysBlock/$Name/device/vendor" "$SysBlock/$Name/device/model" 2>/dev/null | xargs)
        Mp=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
        if (( $(cat "$SysBlock/$Name/size" 2>/dev/null || echo 0) == 0 )); then
            Disc="  [no disc]"
        else
            Label=$(lsblk -dno LABEL "$Dev" 2>/dev/null | xargs)
            Disc="  [disc: ${Label:-unlabeled}]"
        fi
        printf '%s  %s%s%s' "$Dev" "${Model:-unknown drive}" "$Disc" "${Mp:+  [mounted: $Mp]}"
    }

    DetectDrives() {
        local Dev
        DriveDevs=()
        for Dev in /dev/sr*; do
            [[ -b $Dev ]] && DriveDevs+=("$Dev")
        done
    }
}

if ! declare -F Menu >/dev/null; then DefineStandaloneHelpers; fi

# Run a command as the normal user when started through sudo
if ! declare -F RunAsUser >/dev/null; then
    RunAsUser() {
        if [[ $EUID -eq 0 && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            sudo -u "$SUDO_USER" "$@"
        else
            "$@"
        fi
    }
fi

# ------------------------------------------------------------
# Build the preload library
# ------------------------------------------------------------

# Root uses /run/DiskFix, a normal user the runtime folder of the session
ResolveFixDir() {
    if [[ $EUID -eq 0 ]]; then
        FixDir="/run/DiskFix"
    else
        FixDir=${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/DiskFix}
        FixDir=${FixDir:-/tmp/DiskFix-$EUID}
        FixSudo=(sudo)
    fi
    FixLib="$FixDir/dvdfix.so"
    FixCheck="$FixDir/dvdfix-check"
    FixRunner="$FixDir/run-with-fix"
}

BuildDvdFix() {
    local Log
    FixReady=0
    ResolveFixDir
    # Already built by an earlier call: use it
    if [[ -r $FixLib && -x $FixCheck && -x $FixRunner ]]; then FixReady=1; return 0; fi
    if ! FixHas gcc; then
        Info "Installing gcc (used to build the disk fix)..."
        if FixHas pacman; then
            "${FixSudo[@]}" pacman -S --needed --noconfirm gcc || return 1
        else
            Fail "gcc is needed to build the disk fix. Please install it."
            return 1
        fi
    fi
    mkdir -p "$FixDir" && chmod 755 "$FixDir" || return 1
    Defer "rm -rf '$FixDir'"

    cat > "$FixDir/dvdfix.c" <<'FixSourceEnd'
// DiskFix
// Re-implements the kernel's DVD_READ_STRUCT and DVD_AUTH ioctls on top of
// SG_IO. The client kernel disables these ioctls for drives it classifies as
// "scsi-1 drive" (which happens over iSCSI/PSCSI and on some adapters), so libdvdcss cannot
// authenticate. Raw SCSI commands still work, so we send them ourselves.
// Preload it: LD_PRELOAD=<runtime folder>/dvdfix.so dvdbackup ...
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/cdrom.h>
#include <scsi/sg.h>

#define UNSUPPORTED (-2)

static int (*RealIoctl)(int, unsigned long, ...);
static int Debug = -1;

static void Log(const char *Fmt, ...)
{
    va_list Ap;
    if (Debug < 0) Debug = getenv("DISKFIX_DEBUG") != NULL;
    if (!Debug) return;
    fputs("[dvdfix] ", stderr);
    va_start(Ap, Fmt);
    vfprintf(stderr, Fmt, Ap);
    va_end(Ap);
    fputc('\n', stderr);
}

// Send one SCSI command. Commands that change drive state (SEND KEY) need a
// writable descriptor, otherwise the kernel's command filter rejects them for
// normal users, so a second descriptor is opened for those.
static int Sg(int Fd, int NeedWrite, unsigned char *Cdb, int CdbLen,
              void *Buf, unsigned int Len, int Dir)
{
    struct sg_io_hdr H;
    unsigned char Sense[32];
    char Path[64];
    int Use = Fd, Rw = -1, Ret, Saved;

    if (NeedWrite) {
        snprintf(Path, sizeof Path, "/proc/self/fd/%d", Fd);
        Rw = open(Path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (Rw >= 0) Use = Rw;
        else Log("cannot reopen fd %d read-write: %s", Fd, strerror(errno));
    }

    memset(&H, 0, sizeof H);
    memset(Sense, 0, sizeof Sense);
    H.interface_id = 'S';
    H.cmd_len = (unsigned char)CdbLen;
    H.cmdp = Cdb;
    H.dxfer_direction = Dir;
    H.dxferp = Buf;
    H.dxfer_len = Len;
    H.sbp = Sense;
    H.mx_sb_len = sizeof Sense;
    H.timeout = 30000;

    Ret = RealIoctl(Use, SG_IO, &H);
    Saved = errno;
    if (Ret == 0 && (H.status || H.host_status || (H.driver_status & 0x07))) {
        Log("cdb %02x failed: status=%02x host=%02x driver=%02x sense=%02x/%02x/%02x",
            Cdb[0], H.status, H.host_status, H.driver_status,
            Sense[2] & 0x0f, Sense[12], Sense[13]);
        Ret = -1;
        Saved = EIO;
    } else if (Ret < 0) {
        Log("cdb %02x: SG_IO failed: %s", Cdb[0], strerror(Saved));
    }
    if (Rw >= 0) close(Rw);
    errno = Saved;
    return Ret;
}

// REPORT KEY (0xA4): drive -> host
static int ReportKey(int Fd, int Agid, int Type, int Len, unsigned int Lba, unsigned char *Buf)
{
    unsigned char Cdb[12] = { 0xa4 };
    Cdb[2] = Lba >> 24; Cdb[3] = Lba >> 16; Cdb[4] = Lba >> 8; Cdb[5] = Lba;
    Cdb[9] = Len;
    Cdb[10] = Type | (Agid << 6);
    memset(Buf, 0, 16);
    return Sg(Fd, 0, Cdb, 12, Buf, Len, Len ? SG_DXFER_FROM_DEV : SG_DXFER_NONE);
}

// SEND KEY (0xA3): host -> drive
static int SendKey(int Fd, int Agid, int Type, int Len, unsigned char *Buf)
{
    unsigned char Cdb[12] = { 0xa3 };
    Cdb[9] = Len;
    Cdb[10] = Type | (Agid << 6);
    return Sg(Fd, 1, Cdb, 12, Buf, Len, SG_DXFER_TO_DEV);
}

static int FixReadStruct(int Fd, dvd_struct *S)
{
    unsigned char Cdb[12] = { 0xad };
    static unsigned char Buf[2048 + 4];
    int Len, Ret;

    switch (S->type) {
    case DVD_STRUCT_COPYRIGHT:
        Len = 8;
        Cdb[6] = S->copyright.layer_num;
        Cdb[7] = S->type;
        Cdb[8] = Len >> 8;
        Cdb[9] = Len & 0xff;
        Ret = Sg(Fd, 0, Cdb, 12, Buf, Len, SG_DXFER_FROM_DEV);
        if (Ret == 0) {
            S->copyright.cpst = Buf[4];
            S->copyright.rmi = Buf[5];
            Log("copyright: cpst=%d rmi=%d", Buf[4], Buf[5]);
        }
        return Ret;
    case DVD_STRUCT_DISCKEY:
        Len = sizeof S->disckey.value + 4;
        Cdb[7] = S->type;
        Cdb[8] = Len >> 8;
        Cdb[9] = Len & 0xff;
        Cdb[10] = S->disckey.agid << 6;
        Ret = Sg(Fd, 0, Cdb, 12, Buf, Len, SG_DXFER_FROM_DEV);
        if (Ret == 0) memcpy(S->disckey.value, Buf + 4, sizeof S->disckey.value);
        return Ret;
    default:
        return UNSUPPORTED;
    }
}

static int FixAuth(int Fd, dvd_authinfo *A)
{
    unsigned char Buf[16];
    int Ret;

    switch (A->type) {
    case DVD_LU_SEND_AGID:
        Ret = ReportKey(Fd, A->lsa.agid, 0, 8, 0, Buf);
        if (Ret == 0) { A->lsa.agid = Buf[7] >> 6; Log("agid %d", A->lsa.agid); }
        return Ret;
    case DVD_LU_SEND_KEY1:
        Ret = ReportKey(Fd, A->lsk.agid, 2, 12, 0, Buf);
        if (Ret == 0) memcpy(A->lsk.key, Buf + 4, sizeof A->lsk.key);
        return Ret;
    case DVD_LU_SEND_CHALLENGE:
        Ret = ReportKey(Fd, A->lsc.agid, 1, 16, 0, Buf);
        if (Ret == 0) memcpy(A->lsc.chal, Buf + 4, sizeof A->lsc.chal);
        return Ret;
    case DVD_LU_SEND_TITLE_KEY:
        Ret = ReportKey(Fd, A->lstk.agid, 4, 12, (unsigned int)A->lstk.lba, Buf);
        if (Ret == 0) {
            A->lstk.cpm = (Buf[4] >> 7) & 1;
            A->lstk.cp_sec = (Buf[4] >> 6) & 1;
            A->lstk.cgms = (Buf[4] >> 4) & 3;
            memcpy(A->lstk.title_key, Buf + 5, sizeof A->lstk.title_key);
        }
        return Ret;
    case DVD_LU_SEND_ASF:
        Ret = ReportKey(Fd, A->lsasf.agid, 5, 8, 0, Buf);
        if (Ret == 0) A->lsasf.asf = Buf[7] & 1;
        return Ret;
    case DVD_HOST_SEND_CHALLENGE:
        memset(Buf, 0, sizeof Buf);
        Buf[1] = 0x0e;
        memcpy(Buf + 4, A->hsc.chal, sizeof A->hsc.chal);
        Ret = SendKey(Fd, A->hsc.agid, 1, 16, Buf);
        if (Ret == 0) A->type = DVD_LU_SEND_KEY1;
        return Ret;
    case DVD_HOST_SEND_KEY2:
        memset(Buf, 0, sizeof Buf);
        Buf[1] = 0x0a;
        memcpy(Buf + 4, A->hsk.key, sizeof A->hsk.key);
        Ret = SendKey(Fd, A->hsk.agid, 3, 12, Buf);
        A->type = (Ret == 0) ? DVD_AUTH_ESTABLISHED : DVD_AUTH_FAILURE;
        return Ret;
    case DVD_INVALIDATE_AGID:
        return ReportKey(Fd, A->lsa.agid, 0x3f, 0, 0, Buf);
    default:
        return UNSUPPORTED;
    }
}

int ioctl(int Fd, unsigned long Req, ...)
{
    va_list Ap;
    void *Arg;
    int Ret, RealErr, FixRet;
    dvd_struct SavedStruct;
    dvd_authinfo SavedAuth;

    va_start(Ap, Req);
    Arg = va_arg(Ap, void *);
    va_end(Ap);

    if (!RealIoctl) RealIoctl = (int (*)(int, unsigned long, ...))dlsym(RTLD_NEXT, "ioctl");
    if ((Req != DVD_READ_STRUCT && Req != DVD_AUTH) || !Arg)
        return RealIoctl(Fd, Req, Arg);

    // Let the kernel try first. Drives it accepts keep working unchanged.
    if (Req == DVD_READ_STRUCT) memcpy(&SavedStruct, Arg, sizeof SavedStruct);
    else memcpy(&SavedAuth, Arg, sizeof SavedAuth);
    Ret = RealIoctl(Fd, Req, Arg);
    if (Ret >= 0) return Ret;
    RealErr = errno;
    Log("kernel refused %s: %s, using SG_IO",
        Req == DVD_AUTH ? "DVD_AUTH" : "DVD_READ_STRUCT", strerror(RealErr));

    if (Req == DVD_READ_STRUCT) {
        memcpy(Arg, &SavedStruct, sizeof SavedStruct);
        FixRet = FixReadStruct(Fd, (dvd_struct *)Arg);
    } else {
        memcpy(Arg, &SavedAuth, sizeof SavedAuth);
        FixRet = FixAuth(Fd, (dvd_authinfo *)Arg);
    }
    if (FixRet == UNSUPPORTED || (FixRet < 0 && errno == ENOTTY)) {
        errno = RealErr;
        return -1;
    }
    return FixRet;
}
FixSourceEnd

    cat > "$FixDir/dvdfix-check.c" <<'FixCheckEnd'
// DiskFix check
// Asks a drive for the disc copyright info and an authentication ID, the same
// first steps libdvdcss does. Run it with and without LD_PRELOAD to compare.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/cdrom.h>

int main(int Argc, char **Argv)
{
    dvd_struct S;
    dvd_authinfo A;
    int Fd, Failed = 0;

    if (Argc < 2) { fprintf(stderr, "usage: %s /dev/srN\n", Argv[0]); return 2; }
    Fd = open(Argv[1], O_RDONLY | O_NONBLOCK);
    if (Fd < 0) { printf("cannot open %s: %s\n", Argv[1], strerror(errno)); return 2; }

    memset(&S, 0, sizeof S);
    S.type = DVD_STRUCT_COPYRIGHT;
    S.copyright.layer_num = 0;
    if (ioctl(Fd, DVD_READ_STRUCT, &S) < 0) {
        printf("copyright query : FAILED (%s)\n", strerror(errno));
        Failed = 1;
    } else {
        printf("copyright query : ok (%s)\n",
               S.copyright.cpst == 1 ? "CSS protected" : S.copyright.cpst == 0 ? "not protected" : "other protection");
    }

    memset(&A, 0, sizeof A);
    A.type = DVD_LU_SEND_AGID;
    A.lsa.agid = 0;
    if (ioctl(Fd, DVD_AUTH, &A) < 0) {
        printf("authentication  : FAILED (%s)\n", strerror(errno));
        Failed = 1;
    } else {
        printf("authentication  : ok (got ID %d)\n", A.lsa.agid);
        A.type = DVD_INVALIDATE_AGID;
        ioctl(Fd, DVD_AUTH, &A);
    }
    close(Fd);
    return Failed;
}
FixCheckEnd

    Log=$(gcc -O2 -shared -fPIC -o "$FixLib" "$FixDir/dvdfix.c" -ldl 2>&1) ||
        { Fail "Building the disk fix failed:"; echo "$Log"; return 1; }
    Log=$(gcc -O2 -o "$FixCheck" "$FixDir/dvdfix-check.c" 2>&1) ||
        { Fail "Building the disk check failed:"; echo "$Log"; return 1; }
    rm -f "$FixDir"/*.c

    printf '#!/usr/bin/env bash\nexec env LD_PRELOAD="%s${LD_PRELOAD:+:$LD_PRELOAD}" "$@"\n' \
        "$FixLib" > "$FixRunner"
    chmod 755 "$FixLib" "$FixCheck" "$FixRunner"
    FixReady=1
}

# Build the fix if it is not there yet. Returns 1 if it cannot be built.
EnsureFix() {
    (( FixReady )) && return 0
    BuildDvdFix
}

# ------------------------------------------------------------
# Disc detection
# ------------------------------------------------------------

# none, bluray, dvd, cd, unknown
DiscKind() {
    local Name=${1##*/} P
    if (( $(cat "$SysBlock/$Name/size" 2>/dev/null || echo 0) == 0 )); then echo none; return; fi
    P=$(udevadm info -q property -n "$1" 2>/dev/null)
    if grep -q '^ID_CDROM_MEDIA_BD=1' <<< "$P"; then echo bluray
    elif grep -q '^ID_CDROM_MEDIA_DVD=1' <<< "$P"; then echo dvd
    elif grep -q '^ID_CDROM_MEDIA_CD=1' <<< "$P"; then echo cd
    else echo unknown; fi
}

# Finer: none, blank, bd, dvd, cd-audio, cd-mixed, cd-data, unknown.
# The media flags are only valid after the drive has spun up, so it retries for a few seconds.
DiscType() {
    local Dev=${1:-/dev/sr0} Name=${1##*/} P Audio Data Try Size
    Size=$(cat "$SysBlock/$Name/size" 2>/dev/null || echo 0)
    udevadm settle 2>/dev/null
    P=$(udevadm info -q property -n "$Dev" 2>/dev/null) || { echo unknown; return; }
    if ! grep -q '^ID_CDROM_MEDIA=1' <<< "$P"; then
        (( Size == 0 )) && { echo none; return; }
        for Try in 1 2 3 4 5; do
            sleep 1
            P=$(udevadm info -q property -n "$Dev" 2>/dev/null)
            grep -q '^ID_CDROM_MEDIA=1' <<< "$P" && break
        done
        grep -q '^ID_CDROM_MEDIA=1' <<< "$P" || { echo none; return; }
    fi
    grep -q '^ID_CDROM_MEDIA_STATE=blank' <<< "$P" && { echo blank; return; }
    if grep -q '^ID_CDROM_MEDIA_BD=1' <<< "$P"; then echo bd
    elif grep -q '^ID_CDROM_MEDIA_DVD=1' <<< "$P"; then echo dvd
    elif grep -q '^ID_CDROM_MEDIA_CD=1' <<< "$P"; then
        Audio=$(sed -n 's/^ID_CDROM_MEDIA_TRACK_COUNT_AUDIO=//p' <<< "$P")
        Data=$(sed -n 's/^ID_CDROM_MEDIA_TRACK_COUNT_DATA=//p' <<< "$P")
        if   (( ${Audio:-0} > 0 && ${Data:-0} == 0 )); then echo cd-audio
        elif (( ${Audio:-0} > 0 )); then echo cd-mixed
        else echo cd-data; fi
    else echo unknown; fi
}

# Mount a disc read-only. Sets DiscMount; DiscMountTemp=1 when this call did the mount.
MountDisc() {
    local Dev=$1
    DiscMount=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
    DiscMountTemp=0
    [[ -n $DiscMount ]] && return 0
    if [[ $EUID -eq 0 ]]; then
        DiscMount=$(mktemp -d /run/DiskFix-mnt.XXXXXX) || return 1
        mount -o ro,nosuid,nodev "$Dev" "$DiscMount" 2>/dev/null || { rmdir "$DiscMount"; DiscMount=""; return 1; }
    elif FixHas udisksctl; then
        udisksctl mount -b "$Dev" --options ro >/dev/null 2>&1 || return 1
        DiscMount=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
        [[ -n $DiscMount ]] || return 1
    else
        return 1
    fi
    DiscMountTemp=1
}

UnmountDisc() {
    [[ $DiscMountTemp == 1 && -n $DiscMount ]] || return 0
    if [[ $EUID -eq 0 ]]; then
        umount "$DiscMount" 2>/dev/null || umount -l "$DiscMount" 2>/dev/null
        rmdir "$DiscMount" 2>/dev/null
    else
        udisksctl unmount -b "$1" >/dev/null 2>&1
    fi
    DiscMount=""; DiscMountTemp=0
}

# What is on a DVD or Blu-ray: dvd-video, bd, bd-aacs, uhd, data, unreadable
DiscContent() {
    local Dev=$1 Result=data
    MountDisc "$Dev" || { echo unreadable; return; }
    if [[ -d $DiscMount/VIDEO_TS ]]; then
        Result=dvd-video
    elif [[ -d $DiscMount/BDMV ]]; then
        Result=bd
        [[ -d $DiscMount/AACS ]] && Result=bd-aacs
        [[ $(head -c 8 "$DiscMount/BDMV/index.bdmv" 2>/dev/null) == BDMV0300 ]] && Result=uhd
    fi
    UnmountDisc "$Dev"
    echo "$Result"
}

# ------------------------------------------------------------
# Blu-ray key entry (only looks into the user's own KEYDB.cfg, nothing is downloaded)
# ------------------------------------------------------------

KeydbPath() {
    local User=${SUDO_USER:-${USER:-root}} Home
    Home=$(getent passwd "$User" | cut -d: -f6)
    echo "${Home:-$HOME}/.config/aacs/KEYDB.cfg"
}

# Sets KeyState (ok, no-entry, no-keys, no-file, lowercase, no-aacs, no-mount) and DiscId.
BlurayKeyState() {
    local Dev=$1 Db Entry
    KeyState=""; DiscId=""
    MountDisc "$Dev" || { KeyState=no-mount; return 1; }
    [[ -r $DiscMount/AACS/Unit_Key_RO.inf ]] && DiscId=$(sha1sum "$DiscMount/AACS/Unit_Key_RO.inf" | cut -d' ' -f1)
    UnmountDisc "$Dev"
    [[ -n $DiscId ]] || { KeyState=no-aacs; return 0; }
    Db=$(KeydbPath)
    if [[ ! -f $Db ]]; then
        if [[ -f ${Db%/*}/keydb.cfg ]]; then KeyState=lowercase; else KeyState=no-file; fi
        return 0
    fi
    Entry=$(grep -i -m1 "^0x$DiscId" "$Db")
    if [[ -z $Entry ]]; then KeyState=no-entry
    elif grep -q -E '\| (V|U|K) \|' <<< "$Entry"; then KeyState=ok
    else KeyState=no-keys; fi
}

# ------------------------------------------------------------
# Use the fix
# ------------------------------------------------------------

# FixRun <device> <command...>
# Runs the command as the normal user. The fix is preloaded only when the kernel cannot do the
# key handshake on that drive (decided on every call, it takes a moment). If the user cannot
# read the device, the command runs through sudo and FixUsedRoot is set (outputs are root's then).
FixRun() {
    local Dev=$1; shift
    local Preload=""
    if [[ -b $Dev ]]; then
        if EnsureFix 2>/dev/null; then
            if RunAsUser "$FixCheck" "$Dev" >/dev/null 2>&1; then
                Preload=""
            elif RunAsUser env LD_PRELOAD="$FixLib" "$FixCheck" "$Dev" >/dev/null 2>&1; then
                Preload="$FixLib${LD_PRELOAD:+:$LD_PRELOAD}"
            fi
        fi
        if [[ ! -r $Dev && $EUID -ne 0 ]]; then
            FixUsedRoot=1
            if [[ -n $Preload ]]; then "${FixSudo[@]}" env LD_PRELOAD="$Preload" "$@"; else "${FixSudo[@]}" "$@"; fi
            return
        fi
    fi
    if [[ -n $Preload ]]; then RunAsUser env LD_PRELOAD="$Preload" "$@"; else RunAsUser "$@"; fi
}

# Pick a drive from all optical drives of this PC (local and RiftLink)
PickFixDrive() {
    local Labels=() I
    DetectDrives
    if (( ${#DriveDevs[@]} == 0 )); then
        Header; Fail "No optical drive found."; Pause; return 1
    fi
    if (( ${#DriveDevs[@]} == 1 )); then PickedDev=${DriveDevs[0]}; return 0; fi
    for I in "${!DriveDevs[@]}"; do Labels+=("$(DriveLabel "${DriveDevs[$I]}")"); done
    Menu "Select a drive" "${Labels[@]}" || return 1
    PickedDev=${DriveDevs[$MenuChoice]}
}

# Run the handshake test as the normal user, once without and once with the fix
CheckDvdFix() {
    local Dev=$1 Plain Fixed Rc1 Rc2
    Header
    if ! EnsureFix; then
        Fail "The disk fix is not available (build failed)."
        Pause; return
    fi
    case $(DiscKind "$Dev") in
        none)   Warn "There is no disc in $Dev."; Pause; return ;;
        bluray) Info "This is a Blu-ray. The DVD fix does not apply: libbluray and libaacs talk to the drive directly."
                Info "Use 'Check a Blu-ray' for the key entry."
                Pause; return ;;
        cd)     Info "This is a CD. The DVD fix only matters for copy-protected DVDs."; Pause; return ;;
    esac
    Info "Testing $Dev as your normal user, like dvdbackup would run."
    Plain=$(RunAsUser "$FixCheck" "$Dev" 2>&1); Rc1=$?
    Fixed=$(RunAsUser env LD_PRELOAD="$FixLib" "$FixCheck" "$Dev" 2>&1); Rc2=$?
    printf '\n%sKernel only:%s\n%s\n' "$Bold" "$Reset" "$Plain"
    printf '\n%sWith the disk fix:%s\n%s\n\n' "$Bold" "$Reset" "$Fixed"
    if (( Rc1 == 0 )); then
        Info "The kernel already handles this drive. The fix is not needed."
    elif (( Rc2 == 0 )); then
        Info "The fix works. Archive&Restore uses it automatically; for other tools open a shell with the fix."
    else
        Fail "The fix did not work either. Details of the failing commands:"
        RunAsUser env LD_PRELOAD="$FixLib" DISKFIX_DEBUG=1 "$FixCheck" "$Dev" 2>&1 |
            grep -F '[dvdfix]'
        Warn "No disc in the drive? Is it readable for your user (group 'optical')?"
    fi
    Pause
}

# Blu-ray: does the user's KEYDB.cfg have an entry for the disc in the drive?
CheckBluray() {
    local Dev=$1 Pkg Missing=""
    Header
    case $(DiscKind "$Dev") in
        none)   Warn "There is no disc in $Dev."; Pause; return ;;
        bluray) ;;
        *)      Info "This is not a Blu-ray. The key check only applies to Blu-rays."; Pause; return ;;
    esac
    BlurayKeyState "$Dev"
    [[ -n $DiscId ]] && Info "Disc ID: $DiscId"
    case $KeyState in
        no-mount)  Fail "Could not read the disc (mount failed)." ;;
        no-aacs)   Warn "No AACS/Unit_Key_RO.inf on this disc. It is not AACS-protected or has an unusual layout." ;;
        lowercase) Warn "Found keydb.cfg in lowercase. libaacs ignores it, the name must be KEYDB.cfg." ;;
        no-file)   Warn "No $(KeydbPath). Without it libaacs cannot decrypt the disc." ;;
        no-entry)  Warn "$(KeydbPath) has no entry for this disc, so libaacs cannot decrypt it." ;;
        no-keys)   Warn "An entry exists but contains no keys, libaacs cannot decrypt the disc with it." ;;
        ok)        Info "An entry with keys exists, libaacs can use it." ;;
    esac
    if FixHas pacman; then
        for Pkg in libbluray libaacs; do
            pacman -Qq "$Pkg" >/dev/null 2>&1 || Missing+=" $Pkg"
        done
        [[ -n $Missing ]] && Warn "Not installed:$Missing   (sudo pacman -S$Missing)"
    fi
    Pause
}

OpenFixShell() {
    local User=${SUDO_USER:-${USER:-root}} Shell Home
    if ! EnsureFix; then
        Header; Fail "The disk fix is not available (build failed)."; Pause; return
    fi
    Shell=$(getent passwd "$User" | cut -d: -f7)
    Home=$(getent passwd "$User" | cut -d: -f6)
    [[ -x $Shell ]] || Shell=/bin/bash
    Header
    Info "Starting $Shell with the disk fix. Everything started from it can read protected discs."
    printf '\n  Example:  dvdbackup -i /dev/srN -M -p -o ~/rip\n'
    printf '  (Blu-rays do not need the fix: mpv --bluray-device=/dev/srN bluray://longest)\n'
    printf '  Without a shell:  %s <program> <arguments>\n' "$FixRunner"
    printf '  Type exit to come back.\n'
    Pause
    printf '\e[?25h'
    (cd "${Home:-$HOME}" && RunAsUser env LD_PRELOAD="$FixLib" DISKFIX_ACTIVE=1 "$Shell" -i)
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

DiskFixMenu() {
    Header
    Info "Preparing the disk fix..."
    EnsureFix || { Warn "The disk fix could not be built (gcc missing?). The checks below will say so."; Pause; }
    while true; do
        Menu "Disk fix: read protected discs on drives where the kernel cannot do the key handshake" \
            "Check the disk fix on a drive (protected DVDs)" \
            "Check a Blu-ray (key entry in KEYDB.cfg)" \
            "Open a shell with the disk fix (dvdbackup, vobcopy, ...)" || return 0
        case $MenuChoice in
            0) PickFixDrive && CheckDvdFix "$PickedDev" ;;
            1) PickFixDrive && CheckBluray "$PickedDev" ;;
            2) OpenFixShell ;;
        esac
    done
}

DiskFixMain() {
    trap Cleanup EXIT
    trap 'exit 130' INT TERM
    DiskFixMenu
}

# Run the menu only when the file is started directly, not when another script sources it
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then DiskFixMain; fi
