#!/usr/bin/env bash
# RiftLink (part of UrlstoneDiskArchiver)
# Share optical drives between two Arch PCs over iSCSI (PSCSI passthrough).
# Fully interactive. System changes are temporary and reverted on exit.
# Only user settings (addresses you typed in) are kept in the data folder.

TargetIqn="iqn.2026-10.org.trafkhop:urlstone-riftlink"
LegacyTargetIqn="iqn.2026-10.org.archlinux.desktop:optical"
LegacyInitiatorIqn="iqn.2026-10.org.archlinux.laptop:client"
Port=3260
PrefixLen=24
MountRoot="/mnt/RiftLink"
BackstorePrefix="RiftLink"
DataDir=""
ConfigFile=""
ServerAddr=""
ClientAddr=""
AskedAddr=""

CleanupStack=()
BackstoreNames=()
SharedDevs=()
DriveDevs=()
ClientDevs=()
IfaceNames=()
IfaceLabels=()
CheckedFlags=()
MenuChoice=0
KeyName=""
LinkIface=""
LinkMode=""
LocalAddr=""
PeerAddr=""
PickedDev=""
FixDir="/run/RiftLink"
FixLib="$FixDir/dvdfix.so"
FixCheck="$FixDir/dvdfix-check"
FixRunner="$FixDir/run-with-fix"
FixReady=0
SysBlock="/sys/class/block"
WatchLog="/run/RiftLink-watch.log"

Bold=$'\e[1m'; Dim=$'\e[2m'; Reverse=$'\e[7m'; Reset=$'\e[0m'
Red=$'\e[31m'; Green=$'\e[32m'; Yellow=$'\e[33m'

# ------------------------------------------------------------
# Basic helpers
# ------------------------------------------------------------

Info() { printf '%s[*]%s %s\n' "$Green" "$Reset" "$*"; }
Warn() { printf '%s[!]%s %s\n' "$Yellow" "$Reset" "$*"; }
Fail() { printf '%s[x]%s %s\n' "$Red" "$Reset" "$*"; }

Pause() {
    printf '\n%sPress any key to continue...%s' "$Dim" "$Reset"
    IFS= read -rsn1
    printf '\n'
}

Ask() {
    local Reply
    read -rp "$1 " Reply
    printf '%s' "$Reply"
}

# Register a command that runs (in reverse order) when the script ends
Defer() { CleanupStack+=("$*"); }

Cleanup() {
    local I
    trap - EXIT INT TERM
    printf '\e[?25h\n'
    Info "Reverting all changes..."
    for (( I = ${#CleanupStack[@]} - 1; I >= 0; I-- )); do
        eval "${CleanupStack[$I]}" >/dev/null 2>&1
    done
    Info "Done. The system is back in its original state."
}

EnsureRoot() {
    [[ $EUID -eq 0 ]] || exec sudo bash "$0"
}

Header() {
    printf '\e[H\e[2J'
    printf '%s RiftLink %s| optical drives over a direct link%s\n' "$Bold" "$Dim" "$Reset"
    printf '%s----------------------------------------------%s\n\n' "$Dim" "$Reset"
}

# ------------------------------------------------------------
# Persistent user settings (only addresses you typed in)
# ------------------------------------------------------------

ResolveDataDir() {
    local User=${SUDO_USER:-root} Home
    Home=$(getent passwd "$User" | cut -d: -f6)
    DataDir="$Home/.local/share/TrafkHopEntertainment/UrlstoneDiskArchiver"
    ConfigFile="$DataDir/RiftLink.conf"
    mkdir -p "$DataDir"
    [[ $User != root ]] && chown -R "$User:" "$Home/.local/share/TrafkHopEntertainment"
}

GetConfig() { grep -m1 "^$1=" "$ConfigFile" 2>/dev/null | cut -d= -f2-; }

SetConfig() {
    local Tmp
    Tmp=$(mktemp)
    grep -v "^$1=" "$ConfigFile" 2>/dev/null > "$Tmp"
    echo "$1=$2" >> "$Tmp"
    mv "$Tmp" "$ConfigFile"
    chmod 644 "$ConfigFile"
    [[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:" "$ConfigFile"
}

IsIpv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Find a private 192.168.N.x range that no existing route uses
SuggestFreeSubnet() {
    local N
    for N in $(seq 100 250); do
        if ! ip -4 route show | grep -q "^192\.168\.$N\."; then
            echo "192.168.$N"
            return
        fi
    done
}

# AskAddress <prompt> <ConfigKey> [fallback default]  -> sets AskedAddr, remembers the answer
AskAddress() {
    local Default Reply
    Default=$(GetConfig "$2")
    Default=${Default:-${3:-}}
    while true; do
        read -rp "$1 ${Default:+[$Default] }" Reply
        Reply=${Reply:-$Default}
        [[ -z $Reply ]] && return 1
        if IsIpv4 "$Reply"; then
            SetConfig "$2" "$Reply"
            AskedAddr=$Reply
            return 0
        fi
        Warn "Not a valid IPv4 address."
    done
}

# ------------------------------------------------------------
# TUI widgets
# ------------------------------------------------------------

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

# Menu <title> <items...>  -> sets MenuChoice, returns 1 on back/quit
# Optional, set for a single call: MenuTitleFn (prints the title, re-checked on
# every tick), MenuTickFn (runs on every tick), KeyTimeout (tick interval, s).
Menu() {
    local Title=$1; shift
    local Items=("$@") Count=$# Selected=0 I Redraw=1 NewTitle
    printf '\e[?25l'
    while true; do
        if (( Redraw )); then
            [[ -n ${MenuTitleFn:-} ]] && Title=$("$MenuTitleFn")
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
            Redraw=0
        fi
        ReadKey
        case $KeyName in
            Up)    Selected=$(( (Selected + Count - 1) % Count )); Redraw=1 ;;
            Down)  Selected=$(( (Selected + 1) % Count )); Redraw=1 ;;
            Enter) MenuChoice=$Selected; printf '\e[?25h'; return 0 ;;
            Quit)  printf '\e[?25h'; return 1 ;;
            Tick)
                [[ -n ${MenuTickFn:-} ]] && "$MenuTickFn"
                if [[ -n ${MenuTitleFn:-} ]]; then
                    NewTitle=$("$MenuTitleFn")
                    [[ $NewTitle != "$Title" ]] && Redraw=1
                fi ;;
        esac
    done
}

# Checklist <title> <items...>  -> fills CheckedFlags, returns 1 on back
Checklist() {
    local Title=$1; shift
    local Items=("$@") Count=$# Cursor=0 I Mark
    CheckedFlags=()
    for (( I = 0; I < Count; I++ )); do CheckedFlags[I]=1; done
    printf '\e[?25l'
    while true; do
        Header
        printf '%b\n\n' "$Title"
        for I in "${!Items[@]}"; do
            Mark=" "; (( CheckedFlags[I] )) && Mark="x"
            if (( I == Cursor )); then
                printf '  %s> [%s] %s %s\n' "$Reverse" "$Mark" "${Items[$I]}" "$Reset"
            else
                printf '    [%s] %s\n' "$Mark" "${Items[$I]}"
            fi
        done
        printf '\n%s  Up/Down: move   Space: toggle   Enter: confirm   q: back%s\n' "$Dim" "$Reset"
        ReadKey
        case $KeyName in
            Up)    Cursor=$(( (Cursor + Count - 1) % Count )) ;;
            Down)  Cursor=$(( (Cursor + 1) % Count )) ;;
            Space) CheckedFlags[Cursor]=$(( 1 - CheckedFlags[Cursor] )) ;;
            Enter) printf '\e[?25h'; return 0 ;;
            Quit)  printf '\e[?25h'; return 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# Drive helpers
# ------------------------------------------------------------

DriveLabel() {
    local Dev=$1 Name=${1##*/} Model Mp Disc Label
    Model=$(cat "/sys/class/block/$Name/device/vendor" "/sys/class/block/$Name/device/model" 2>/dev/null | xargs)
    Mp=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
    if (( $(cat "/sys/class/block/$Name/size" 2>/dev/null || echo 0) == 0 )); then
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

DetectIscsiDrives() {
    local Link
    ClientDevs=()
    for Link in /dev/disk/by-path/*"$TargetIqn"-lun-*; do
        [[ -e $Link && $Link != *-part* ]] || continue
        ClientDevs+=("$(readlink -f "$Link")")
    done
}

# ------------------------------------------------------------
# Network link selection and setup
# ------------------------------------------------------------

GetIfaceType() {
    local Iface=$1 Driver="" DevPath
    [[ -e /sys/class/net/$Iface/device/driver ]] &&
        Driver=$(basename "$(readlink -f "/sys/class/net/$Iface/device/driver")")
    DevPath=$(readlink -f "/sys/class/net/$Iface/device" 2>/dev/null)
    if [[ $Driver == thunderbolt* || $Iface == thunderbolt* ]]; then
        echo "USB4/Thunderbolt"
    elif [[ -d /sys/class/net/$Iface/wireless || -d /sys/class/net/$Iface/phy80211 ]]; then
        echo "WiFi"
    elif [[ $Iface == tailscale* || $Iface == tun* || $Iface == wg* ]]; then
        echo "VPN"
    elif [[ $DevPath == */usb* ]]; then
        echo "USB"
    else
        echo "Ethernet"
    fi
}

# ListInterfaces <direct|existing>  -> fills IfaceNames and IfaceLabels
ListInterfaces() {
    local Mode=$1 Path Iface Type State Addr Tag DefaultIface
    IfaceNames=(); IfaceLabels=()
    DefaultIface=$(ip -4 route show default 2>/dev/null |
        awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
    for Path in /sys/class/net/*; do
        Iface=${Path##*/}
        case $Iface in lo|docker*|veth*|br-*|virbr*|vmnet*|vboxnet*) continue ;; esac
        Type=$(GetIfaceType "$Iface")
        Addr=$(ip -4 -o addr show dev "$Iface" scope global 2>/dev/null | awk '{print $4; exit}')
        if [[ $Mode == direct ]]; then
            [[ $Type == WiFi || $Type == VPN ]] && continue
        else
            [[ -z $Addr ]] && continue
        fi
        State=$(cat "$Path/operstate" 2>/dev/null)
        Tag=""; [[ $Iface == "$DefaultIface" ]] && Tag="(default route)"
        IfaceNames+=("$Iface")
        IfaceLabels+=("$(printf '%-14s %-17s %-8s %-18s %s' "$Iface" "$Type" "$State" "${Addr:--}" "$Tag")")
    done
}

# SelectInterface <direct|existing>  -> sets LinkIface
SelectInterface() {
    local Mode=$1 Items=()
    while true; do
        [[ $Mode == direct ]] && modprobe -a thunderbolt_net plusb 2>/dev/null
        ListInterfaces "$Mode"
        Items=("${IfaceLabels[@]}" "Rescan interfaces")
        Menu "Select the network interface of the link.\n${Dim}  name           type              state    IPv4${Reset}\n\n${Dim}  Plug the cable into both PCs first, then rescan if nothing shows up.${Reset}" \
            "${Items[@]}" || return 1
        (( MenuChoice == ${#IfaceNames[@]} )) && continue
        LinkIface=${IfaceNames[$MenuChoice]}
        return 0
    done
}

# Give the cable interface a private address and keep NetworkManager away
ConfigureDirectLink() {
    local Flags Waited=0
    if command -v nmcli >/dev/null 2>&1 &&
       nmcli -t -f DEVICE device 2>/dev/null | grep -qx "$LinkIface"; then
        nmcli device set "$LinkIface" managed no >/dev/null 2>&1
        Defer "nmcli device set '$LinkIface' managed yes"
    fi
    Flags=$(cat "/sys/class/net/$LinkIface/flags")
    (( (Flags & 1) == 0 )) && Defer "ip link set dev '$LinkIface' down"
    ip link set dev "$LinkIface" up || return 1
    ip addr replace "$LocalAddr/$PrefixLen" dev "$LinkIface" || return 1
    Defer "ip addr del '$LocalAddr/$PrefixLen' dev '$LinkIface'"

    Info "Waiting for link on $LinkIface ..."
    while (( Waited < 30 )); do
        [[ $(cat "/sys/class/net/$LinkIface/carrier" 2>/dev/null) == 1 ]] && return 0
        sleep 1; Waited=$(( Waited + 1 ))
    done
    Warn "No carrier detected on $LinkIface. Continuing anyway."
}

# SetupLink <Server|Client>  -> sets LinkIface, LocalAddr, PeerAddr
SetupLink() {
    local Role=$1 Cidr Base
    Menu "How are the two PCs connected?" \
        "Direct cable link (USB4/Thunderbolt, USB network cable, LAN cable) - fast" \
        "Existing network (WiFi, LAN, Tailscale) - slow" || return 1
    if (( MenuChoice == 0 )); then
        LinkMode=direct
        SelectInterface direct || return 1
        Header
        Base=$(SuggestFreeSubnet)
        printf 'The cable needs two private addresses (one per PC, same pair on both PCs).\n'
        printf 'Just press Enter to accept the suggestion. On the second PC use the same pair.\n\n'
        AskAddress "Server address on the cable:" DirectServerAddr "$Base.1" || return 1
        ServerAddr=$AskedAddr
        AskAddress "Client address on the cable:" DirectClientAddr "$Base.2" || return 1
        ClientAddr=$AskedAddr
        if [[ $ServerAddr == "$ClientAddr" ]]; then
            Fail "Both addresses must differ."; Pause; return 1
        fi
        if [[ $Role == Server ]]; then
            LocalAddr=$ServerAddr; PeerAddr=$ClientAddr
        else
            LocalAddr=$ClientAddr; PeerAddr=$ServerAddr
        fi
        ConfigureDirectLink || { Fail "Could not configure $LinkIface."; Pause; return 1; }
    else
        LinkMode=existing
        SelectInterface existing || return 1
        Cidr=$(ip -4 -o addr show dev "$LinkIface" scope global | awk '{print $4; exit}')
        LocalAddr=${Cidr%/*}
        if [[ $Role == Client ]]; then
            Header
            AskAddress "IP address of the server PC:" LastServerAddr || return 1
            PeerAddr=$AskedAddr
        fi
    fi
}

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

EnsureTargetcli() {
    local BuildUser=${SUDO_USER:-$(logname 2>/dev/null)} BuildDir Pkg
    command -v targetcli >/dev/null 2>&1 && return 0
    Info "targetcli not found, trying the official repos..."
    pacman -S --needed --noconfirm targetcli-fb && return 0
    Info "Not available there, building from the AUR..."
    if command -v yay >/dev/null 2>&1; then
        sudo -u "$BuildUser" yay -S --noconfirm targetcli-fb
    elif command -v paru >/dev/null 2>&1; then
        sudo -u "$BuildUser" paru -S --noconfirm targetcli-fb
    else
        pacman -S --needed --noconfirm git base-devel || return 1
        BuildDir=$(sudo -u "$BuildUser" mktemp -d)
        Defer "rm -rf '$BuildDir'"
        for Pkg in python-rtslib-fb python-configshell-fb targetcli-fb; do
            sudo -u "$BuildUser" git clone "https://aur.archlinux.org/$Pkg.git" "$BuildDir/$Pkg" || return 1
            (cd "$BuildDir/$Pkg" && sudo -u "$BuildUser" makepkg -si --noconfirm) || return 1
        done
    fi
    command -v targetcli >/dev/null 2>&1
}

EnsureClientTools() {
    # udisks2 gives file managers (Thunar etc.) access to the mounted drives
    command -v udisksctl >/dev/null 2>&1 || pacman -S --needed --noconfirm udisks2
    command -v iscsiadm >/dev/null 2>&1 && return 0
    Info "Installing open-iscsi..."
    pacman -S --needed --noconfirm open-iscsi
}

# ------------------------------------------------------------
# DVD fix (client side)
# ------------------------------------------------------------
# Over iSCSI the client kernel cannot read the drive's capability page (it
# sends a 6-byte MODE SENSE that the drive rejects) and classifies the drive as
# "scsi-1 drive". It then disables the DVD ioctls that libdvdcss needs to
# authenticate, so protected discs fail with "Read of scrambled sector without
# authentication". Raw SCSI commands still work, so a small preload library
# sends the authentication commands itself. It is built at start and removed
# on exit; programs only use it when started through it.

BuildDvdFix() {
    local Log
    FixReady=0
    if ! command -v gcc >/dev/null 2>&1; then
        Info "Installing gcc (used to build the DVD fix)..."
        pacman -S --needed --noconfirm gcc || return 1
    fi
    mkdir -p "$FixDir" && chmod 755 "$FixDir" || return 1
    Defer "rm -rf '$FixDir'"

    cat > "$FixDir/dvdfix.c" <<'FixSourceEnd'
// RiftLink DVD fix
// Re-implements the kernel's DVD_READ_STRUCT and DVD_AUTH ioctls on top of
// SG_IO. The client kernel disables these ioctls for drives it classifies as
// "scsi-1 drive" (which happens over iSCSI/PSCSI), so libdvdcss cannot
// authenticate. Raw SCSI commands still work, so we send them ourselves.
// Preload it: LD_PRELOAD=/run/RiftLink/dvdfix.so dvdbackup ...
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
    if (Debug < 0) Debug = getenv("RIFTLINK_DVDFIX_DEBUG") != NULL;
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
// RiftLink DVD fix check
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
        { Fail "Building the DVD fix failed:"; echo "$Log"; return 1; }
    Log=$(gcc -O2 -o "$FixCheck" "$FixDir/dvdfix-check.c" 2>&1) ||
        { Fail "Building the DVD check failed:"; echo "$Log"; return 1; }
    rm -f "$FixDir"/*.c

    printf '#!/usr/bin/env bash\nexec env LD_PRELOAD="%s${LD_PRELOAD:+:$LD_PRELOAD}" "$@"\n' \
        "$FixLib" > "$FixRunner"
    chmod 755 "$FixLib" "$FixCheck" "$FixRunner"
    FixReady=1
}

# Run the handshake test as the normal user, once without and once with the fix
CheckDvdFix() {
    local Dev=$1 Plain Fixed Rc1 Rc2
    Header
    if (( ! FixReady )); then
        Fail "The DVD fix is not available (build failed at start)."
        Pause; return
    fi
    case $(DiscKind "$Dev") in
        none)   Warn "There is no disc in $Dev."; Pause; return ;;
        bluray) Info "This is a Blu-ray. The DVD fix does not apply: libbluray and libaacs talk to the drive directly."
                Info "Play or read it with mpv or VLC, see NOTES-Ripping-Protected-Discs.md."
                Pause; return ;;
        cd)     Info "This is a CD. The DVD fix only matters for copy-protected DVDs."; Pause; return ;;
    esac
    Info "Testing $Dev as your normal user, like dvdbackup would run."
    Plain=$(RunAsUser "$FixCheck" "$Dev" 2>&1); Rc1=$?
    Fixed=$(RunAsUser env LD_PRELOAD="$FixLib" "$FixCheck" "$Dev" 2>&1); Rc2=$?
    printf '\n%sKernel only:%s\n%s\n' "$Bold" "$Reset" "$Plain"
    printf '\n%sWith the DVD fix:%s\n%s\n\n' "$Bold" "$Reset" "$Fixed"
    if (( Rc1 == 0 )); then
        Info "The kernel already handles this drive. The fix is not needed."
    elif (( Rc2 == 0 )); then
        Info "The fix works. Start your ripping tool from 'Open a shell with the DVD fix'."
    else
        Fail "The fix did not work either. Details of the failing commands:"
        RunAsUser env LD_PRELOAD="$FixLib" RIFTLINK_DVDFIX_DEBUG=1 "$FixCheck" "$Dev" 2>&1 |
            grep -F '[dvdfix]'
        Warn "No disc in the drive? Is it readable for your user (group 'optical')?"
    fi
    Pause
}

# Blu-ray: does the user's KEYDB.cfg have an entry for the disc in the drive?
# Only looks the disc ID up in a file the user already has. Nothing is downloaded.
CheckBluray() {
    local Dev=$1 User=${SUDO_USER:-root} Home Db Mp Tmp="" Id Entry Missing=""
    Header
    case $(DiscKind "$Dev") in
        none)   Warn "There is no disc in $Dev."; Pause; return ;;
        bluray) ;;
        *)      Info "This is not a Blu-ray. The key check only applies to Blu-rays."; Pause; return ;;
    esac
    Home=$(getent passwd "$User" | cut -d: -f6)
    Db="$Home/.config/aacs/KEYDB.cfg"

    Mp=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
    if [[ -z $Mp ]]; then
        Tmp=$(mktemp -d /run/RiftLink-bd.XXXXXX) || { Fail "Cannot create a temporary folder."; Pause; return; }
        if ! mount -o ro,nosuid,nodev "$Dev" "$Tmp" 2>/dev/null; then
            rmdir "$Tmp"; Fail "Could not read the disc (mount failed)."; Pause; return
        fi
        Mp=$Tmp
    fi
    if [[ -r $Mp/AACS/Unit_Key_RO.inf ]]; then
        Id=$(sha1sum "$Mp/AACS/Unit_Key_RO.inf" | cut -d' ' -f1)
    fi
    [[ -n $Tmp ]] && { umount "$Tmp" 2>/dev/null; rmdir "$Tmp" 2>/dev/null; }

    if [[ -z ${Id:-} ]]; then
        Warn "No AACS/Unit_Key_RO.inf on this disc. It is not AACS-protected or has an unusual layout."
        Pause; return
    fi
    Info "Disc ID: $Id"

    for Pkg in libbluray libaacs; do
        pacman -Qq "$Pkg" >/dev/null 2>&1 || Missing+=" $Pkg"
    done
    [[ -n $Missing ]] && Warn "Not installed:$Missing   (sudo pacman -S$Missing)"

    if [[ ! -f $Db ]]; then
        if [[ -f $Home/.config/aacs/keydb.cfg ]]; then
            Warn "Found keydb.cfg in lowercase. libaacs ignores it, the name must be KEYDB.cfg."
        else
            Warn "No $Db. Without it libaacs cannot decrypt the disc."
        fi
        Pause; return
    fi
    Entry=$(grep -i -m1 "^0x$Id" "$Db")
    if [[ -z $Entry ]]; then
        Warn "$Db has no entry for this disc, so libaacs cannot decrypt it."
    elif grep -q -E '\| (V|U|K) \|' <<< "$Entry"; then
        Info "Entry found: $(sed -E 's/^0x[0-9a-fA-F]+ *= *//; s/ *\|.*//' <<< "$Entry")"
        Info "It contains keys, libaacs can use it."
    else
        Warn "An entry exists but contains no keys, libaacs cannot decrypt the disc with it."
    fi
    Pause
}

OpenFixShell() {
    local User=${SUDO_USER:-root} Shell Home
    if (( ! FixReady )); then
        Header; Fail "The DVD fix is not available (build failed at start)."; Pause; return
    fi
    Shell=$(getent passwd "$User" | cut -d: -f7)
    Home=$(getent passwd "$User" | cut -d: -f6)
    [[ -x $Shell ]] || Shell=/bin/bash
    Header
    Info "Starting $Shell with the DVD fix. Everything started from it can read protected discs."
    printf '\n  Example:  dvdbackup -i /dev/srN -M -p -o ~/rip\n'
    printf '  (Blu-rays do not need the fix: mpv --bluray-device=/dev/srN bluray://longest)\n'
    printf '  Without a shell:  %s <program> <arguments>\n' "$FixRunner"
    printf '  Type exit to come back to RiftLink.\n'
    Pause
    printf '\e[?25h'
    (cd "$Home" && RunAsUser env LD_PRELOAD="$FixLib" RIFTLINK_DVDFIX=1 "$Shell" -i)
}

# ------------------------------------------------------------
# Server
# ------------------------------------------------------------

TeardownTarget() {
    local Name
    targetcli /iscsi delete "$TargetIqn"
    for Name in "${BackstoreNames[@]}"; do
        targetcli /backstores/pscsi delete "$Name"
    done
}

PrepareTarget() {
    local I=0 Dev Name PrevAutoSave Tpg="/iscsi/$TargetIqn/tpg1"
    modprobe -a target_core_mod target_core_pscsi iscsi_target_mod || return 1

    # Stop targetcli from writing its config to disk (keeps everything temporary)
    PrevAutoSave=$(targetcli get global auto_save_on_exit 2>/dev/null | sed -n 's/.*=//p' | head -1)
    targetcli set global auto_save_on_exit=false >/dev/null 2>&1
    Defer "targetcli set global auto_save_on_exit='${PrevAutoSave:-true}'"
    Defer "TeardownTarget"

    targetcli /iscsi delete "$TargetIqn" >/dev/null 2>&1
    for Dev in "${SharedDevs[@]}"; do
        Name="$BackstorePrefix$I"; I=$(( I + 1 ))
        umount "$Dev" 2>/dev/null
        targetcli /backstores/pscsi delete "$Name" >/dev/null 2>&1
        BackstoreNames+=("$Name")
        targetcli /backstores/pscsi create "name=$Name" "dev=$Dev" || { Fail "Could not share $Dev (busy?)."; return 1; }
    done

    targetcli /iscsi create "$TargetIqn" || return 1
    # Open access is fine: the portal is bound to the private link address only
    targetcli "$Tpg" set attribute generate_node_acls=1 cache_dynamic_acls=1 \
        demo_mode_write_protect=0 authentication=0 || return 1
    targetcli "$Tpg/portals" delete 0.0.0.0 "$Port" >/dev/null 2>&1
    targetcli "$Tpg/portals" delete "::0" "$Port" >/dev/null 2>&1
    targetcli "$Tpg/portals" create "$LocalAddr" "$Port" || return 1
    for Name in "${BackstoreNames[@]}"; do
        targetcli "$Tpg/luns" create "/backstores/pscsi/$Name" || return 1
    done
}

ShowServerStatus() {
    local Prev Now Rate Sessions Dev
    Prev=$(cat "/sys/class/net/$LinkIface/statistics/tx_bytes")
    while true; do
        Now=$(cat "/sys/class/net/$LinkIface/statistics/tx_bytes")
        Rate=$(awk -v D=$(( Now - Prev )) 'BEGIN { printf "%.1f", D / 2 / 1048576 }')
        Prev=$Now
        Sessions=$(ss -Htn state established "( sport = :$Port )" 2>/dev/null | wc -l)
        Header
        printf '%sServer is sharing your drives%s\n\n' "$Green" "$Reset"
        printf '  Interface : %s (%s)\n' "$LinkIface" "$LinkMode"
        printf '  Address   : %s:%s\n' "$LocalAddr" "$Port"
        printf '  Clients   : %s connection(s)\n' "$Sessions"
        printf '  Send rate : %s MB/s\n\n' "$Rate"
        for Dev in "${SharedDevs[@]}"; do printf '  - %s\n' "$(DriveLabel "$Dev")"; done
        printf '\n%sThe drives are locked for local use while shared.%s\n' "$Dim" "$Reset"
        printf '%sPress q to stop sharing and revert everything.%s\n' "$Dim" "$Reset"
        if IFS= read -rsn1 -t 2 Now && [[ $Now == [qQ] ]]; then break; fi
    done
}

RunServer() {
    local I Labels=()
    EnsureTargetcli || { Fail "Could not install targetcli."; Pause; return 1; }
    DetectDrives
    if (( ${#DriveDevs[@]} == 0 )); then
        Fail "No optical drives found under /dev/sr*."; Pause; return 1
    fi
    for I in "${!DriveDevs[@]}"; do Labels+=("$(DriveLabel "${DriveDevs[$I]}")"); done
    Checklist "Select the drives to share" "${Labels[@]}" || return 1
    for I in "${!DriveDevs[@]}"; do
        (( CheckedFlags[I] )) && SharedDevs+=("${DriveDevs[$I]}")
    done
    (( ${#SharedDevs[@]} )) || { Warn "Nothing selected."; Pause; return 1; }

    SetupLink Server || return 1
    Info "Creating iSCSI target..."
    PrepareTarget || { Fail "Target setup failed."; Pause; return 1; }
    ShowServerStatus
}

# ------------------------------------------------------------
# Client
# ------------------------------------------------------------

WaitForServer() {
    local Tries=0
    Info "Waiting for the server at $PeerAddr:$Port ..."
    until timeout 1 bash -c "exec 3<>/dev/tcp/$PeerAddr/$Port" 2>/dev/null; do
        Tries=$(( Tries + 1 ))
        (( Tries >= 60 )) && return 1
        sleep 1
    done
}

# Run a command as the invoking desktop user (udisks/polkit expect a user session)
RunAsUser() {
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

UnmountDev() {
    local Dev=$1 Mp
    Mp=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
    [[ -n $Mp ]] || return 0
    command -v udisksctl >/dev/null 2>&1 && RunAsUser udisksctl unmount -b "$Dev" >/dev/null 2>&1
    if findmnt -rno TARGET "$Dev" >/dev/null 2>&1; then
        umount "$Mp" || umount -l "$Mp"
    fi
    [[ $Mp == "$MountRoot"/* ]] && rmdir "$Mp" 2>/dev/null
    return 0
}

UnmountAll() {
    local Dev
    DetectIscsiDrives
    for Dev in "${ClientDevs[@]}"; do UnmountDev "$Dev"; done
    rmdir "$MountRoot"/* "$MountRoot" 2>/dev/null
}

# Keep requests small (see ConnectIscsi). Quiet, returns 1 if not applied.
LimitRequestSize() {
    local Q="$SysBlock/${1##*/}/queue"
    [[ $(cat "$Q/max_sectors_kb" 2>/dev/null) == 64 ]] && return 0
    { echo 64 > "$Q/max_sectors_kb"; echo 64 > "$Q/read_ahead_kb"; } 2>/dev/null
    [[ $(cat "$Q/max_sectors_kb" 2>/dev/null) == 64 ]]
}

# Make the kernel ask the drive about disc changes and eject button presses
EnableMediaPolling() {
    local F="$SysBlock/${1##*/}/events_poll_msecs"
    [[ -w $F && $(cat "$F" 2>/dev/null) != 2000 ]] && { echo 2000 > "$F"; } 2>/dev/null
    return 0
}

# State of the iSCSI session (LOGGED_IN when the server is reachable)
SessionState() {
    local F
    for F in /sys/class/iscsi_session/session*/state; do
        [[ -r $F ]] && { cat "$F"; return; }
    done
    echo unknown
}

# none | bluray | dvd | cd | unknown
DiscKind() {
    local Name=${1##*/} P
    if (( $(cat "$SysBlock/$Name/size" 2>/dev/null || echo 0) == 0 )); then echo none; return; fi
    P=$(udevadm info -q property -n "$1" 2>/dev/null)
    if grep -q '^ID_CDROM_MEDIA_BD=1' <<< "$P"; then echo bluray
    elif grep -q '^ID_CDROM_MEDIA_DVD=1' <<< "$P"; then echo dvd
    elif grep -q '^ID_CDROM_MEDIA_CD=1' <<< "$P"; then echo cd
    else echo unknown; fi
}

# Changes whenever the kernel reports a new disc (no access to the drive)
DiscSignature() {
    {
        cat "$SysBlock/${1##*/}/size" 2>/dev/null
        udevadm info -q property -n "$1" 2>/dev/null | grep -E '^(SEQNUM|ID_FS_LABEL|ID_FS_UUID)='
    } | md5sum | cut -d' ' -f1
}

WatchNote() { printf '%s  %s\n' "$(date +%T)" "$*" >> "$WatchLog"; }

# Menu title for the client: live drive list
ClientTitle() {
    local Dev Line State
    DetectIscsiDrives
    printf 'Connected to %s via %s\n\n' "$PeerAddr" "$LinkIface"
    for Dev in "${ClientDevs[@]}"; do
        Line=$(DriveLabel "$Dev")
        printf '  %s\n' "${Line//\\/\\\\}"
    done
    State=$(SessionState)
    [[ $State == LOGGED_IN || $State == unknown ]] || printf '\n  [!] Connection to the server: %s\n' "$State"
}

# Background loop while the client runs (also while a shell is open): unmounts
# mounts whose disc was removed or changed, puts the request size back to 64 KB
# if the kernel reset it, and keeps disc-change polling on. Everything it does
# is written to $WatchLog.
ClientWatcher() {
    local Dev Name Sig Mp Cur State LastState=""
    declare -A Last Base
    while sleep 2; do
        State=$(SessionState)
        [[ $State != "$LastState" ]] && { WatchNote "iSCSI session state: $State"; LastState=$State; }
        DetectIscsiDrives
        for Dev in "${ClientDevs[@]}"; do
            Name=${Dev##*/}
            Cur=$(cat "$SysBlock/$Name/queue/max_sectors_kb" 2>/dev/null)
            if [[ -n $Cur && $Cur != 64 ]] && LimitRequestSize "$Dev"; then
                WatchNote "$Name: request size had been reset to $Cur KB, set back to 64 KB"
            fi
            EnableMediaPolling "$Dev"
            Sig=$(DiscSignature "$Dev")
            [[ -n ${Last[$Dev]:-} && $Sig != "${Last[$Dev]}" ]] && WatchNote "$Name: disc change reported"
            Mp=$(findmnt -rno TARGET "$Dev" 2>/dev/null | head -1)
            if [[ -z $Mp ]]; then
                Base[$Dev]=""
            elif (( $(cat "$SysBlock/$Name/size" 2>/dev/null || echo 0) == 0 )); then
                UnmountDev "$Dev" >/dev/null 2>&1
                WatchNote "$Name: no disc but still mounted at $Mp, unmounted"
                Base[$Dev]=""
            elif [[ -z ${Base[$Dev]:-} ]]; then
                [[ $Sig == "${Last[$Dev]:-}" ]] && Base[$Dev]=$Sig
            elif [[ $Sig != "${Base[$Dev]}" ]]; then
                UnmountDev "$Dev" >/dev/null 2>&1
                WatchNote "$Name: disc changed while mounted at $Mp, old mount removed"
                Base[$Dev]=""
            fi
            Last[$Dev]=$Sig
        done
    done
}

ShowWatchLog() {
    Header
    Info "What RiftLink noticed or corrected in the background since connecting:"
    printf '\n'
    if [[ -s $WatchLog ]]; then tail -n 30 "$WatchLog" | sed 's/^/  /'; else printf '  Nothing so far.\n'; fi
    Pause
}

ConnectIscsi() {
    local Node=(-m node -T "$TargetIqn" -p "$PeerAddr:$Port") Tries Dev

    if iscsiadm -m session 2>/dev/null | grep -q "$TargetIqn"; then
        Fail "An old iSCSI session to this target already exists."
        Warn "Use 'Remove leftovers of old setups' in the main menu first."
        Pause; return 1
    fi

    modprobe iscsi_tcp
    if [[ ! -s /etc/iscsi/initiatorname.iscsi ]]; then
        mkdir -p /etc/iscsi
        echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
        Defer "rm -f /etc/iscsi/initiatorname.iscsi"
    fi
    if ! systemctl is-active --quiet iscsid.service; then
        systemctl start iscsid.service || return 1
        Defer "systemctl stop iscsid.service iscsid.socket"
        sleep 1
    fi

    Defer "iscsiadm -m node -T '$TargetIqn' -p '$PeerAddr:$Port' -o delete"
    Defer "iscsiadm -m node -T '$TargetIqn' -p '$PeerAddr:$Port' -u"
    Defer "UnmountAll"

    iscsiadm "${Node[@]}" -o new >/dev/null
    iscsiadm "${Node[@]}" -o update -n node.startup -v manual >/dev/null
    Info "Logging in..."
    iscsiadm "${Node[@]}" -l >/dev/null || { Fail "Login failed."; Pause; return 1; }

    udevadm settle
    for (( Tries = 0; Tries < 20; Tries++ )); do
        DetectIscsiDrives
        (( ${#ClientDevs[@]} )) && break
        sleep 1
    done
    (( ${#ClientDevs[@]} )) || { Fail "Logged in, but no drives appeared."; Pause; return 1; }

    # The server-side pSCSI backend cannot handle big requests ("failed to
    # append bio"), so keep every request small. Applied on every login.
    for Dev in "${ClientDevs[@]}"; do
        LimitRequestSize "$Dev" || Warn "Could not limit the request size of $Dev."
        EnableMediaPolling "$Dev"
    done
}

PickDrive() {
    local Labels=() Dev
    DetectIscsiDrives
    (( ${#ClientDevs[@]} )) || { Warn "No drives visible."; Pause; return 1; }
    for Dev in "${ClientDevs[@]}"; do Labels+=("$(DriveLabel "$Dev")"); done
    Menu "Select a drive" "${Labels[@]}" || return 1
    PickedDev=${ClientDevs[$MenuChoice]}
}

MountDrive() {
    local Dev=$1 Mp="$MountRoot/${1##*/}" Out
    if findmnt -rno TARGET "$Dev" >/dev/null 2>&1; then
        Warn "Already mounted."; Pause; return
    fi
    # Prefer udisks so the drive also shows up in file managers like Thunar
    if command -v udisksctl >/dev/null 2>&1 && Out=$(RunAsUser udisksctl mount -b "$Dev" 2>&1); then
        Info "$Out"
    else
        Warn "udisks mount failed, using a plain mount instead."
        mkdir -p "$Mp"
        if mount -o ro "$Dev" "$Mp"; then
            Info "Mounted at $Mp (not visible in file managers)"
        else
            Fail "Mount failed (no disc?)."; rmdir "$Mp"
        fi
    fi
    Pause
}

UnmountDrive() {
    if findmnt -rno TARGET "$1" >/dev/null 2>&1; then
        UnmountDev "$1"
        Info "Unmounted."
    else
        Warn "Not mounted."
    fi
}

SpeedTest() {
    Header
    Info "Reading 256 MB from $1 ..."
    # Direct I/O is rejected by optical drives over iSCSI, so flush the cache instead
    blockdev --flushbufs "$1" 2>/dev/null
    if ! dd if="$1" of=/dev/null bs=1M count=256 status=progress; then
        Fail "Read stopped early."
        Warn "Copy-protected (CSS/AACS) discs cannot be read raw past the first few MB."
        Warn "Use a non-protected disc for this test, or dvdbackup from the DVD fix shell for real copies."
        printf '\n%sKernel says:%s\n' "$Dim" "$Reset"
        dmesg | tail -n 12
    fi
    Pause
}

ClientMenu() {
    while true; do
        MenuTitleFn=ClientTitle KeyTimeout=2 Menu "" \
            "Mount a drive (read-only)" \
            "Unmount a drive" \
            "Eject a drive" \
            "Speed test (read 256 MB)" \
            "Check the DVD fix (protected DVDs)" \
            "Check a Blu-ray (key entry in KEYDB.cfg)" \
            "Open a shell with the DVD fix (dvdbackup, vobcopy, ...)" \
            "Show what RiftLink corrected in the background" \
            "Disconnect and revert everything" || break
        case $MenuChoice in
            0) PickDrive && MountDrive "$PickedDev" ;;
            1) PickDrive && { UnmountDrive "$PickedDev"; Pause; } ;;
            2) PickDrive && { UnmountDrive "$PickedDev"; eject "$PickedDev"; Pause; } ;;
            3) PickDrive && SpeedTest "$PickedDev" ;;
            4) PickDrive && CheckDvdFix "$PickedDev" ;;
            5) PickDrive && CheckBluray "$PickedDev" ;;
            6) OpenFixShell ;;
            7) ShowWatchLog ;;
            8) break ;;
        esac
    done
}

RunClient() {
    EnsureClientTools || { Fail "Could not install the client tools (open-iscsi, udisks2)."; Pause; return 1; }
    SetupLink Client || return 1
    WaitForServer || { Fail "Server not reachable. Is the server side running?"; Pause; return 1; }
    ConnectIscsi || return 1
    BuildDvdFix || Warn "The DVD fix could not be built. Protected DVDs may fail to rip."
    : > "$WatchLog"; Defer "rm -f '$WatchLog'"
    ClientWatcher >/dev/null 2>&1 &
    WatcherPid=$!
    disown "$WatcherPid" 2>/dev/null
    Defer "kill $WatcherPid 2>/dev/null"
    ClientMenu
}

# ------------------------------------------------------------
# Remove leftovers of older setups
# ------------------------------------------------------------

CleanLeftovers() {
    local Answer Item
    Header
    printf 'This removes leftovers of older setups (NBD and the old DiskLink iSCSI script) on THIS PC:\n\n'
    printf '  - NBD server/client processes and units\n'
    printf '  - ALL iSCSI sessions and node records, plus the iSCSI boot units\n'
    printf '  - the old LIO targets of this tool and the target boot unit\n'
    printf '  - empty /mnt/dvd and /mnt/bluray folders\n\n'
    Answer=$(Ask "Continue? [y/N]")
    [[ $Answer =~ ^[Yy]$ ]] || return 0
    echo

    pkill -f nbdkit 2>/dev/null
    if command -v nbd-client >/dev/null 2>&1; then
        for Item in /dev/nbd*; do [[ -b $Item ]] && nbd-client -d "$Item" >/dev/null 2>&1; done
    fi
    systemctl disable --now nbd.service >/dev/null 2>&1

    if command -v iscsiadm >/dev/null 2>&1; then
        iscsiadm -m node -u >/dev/null 2>&1
        iscsiadm -m node -o delete >/dev/null 2>&1
        rm -rf /var/lib/iscsi/nodes/* /var/lib/iscsi/send_targets/* 2>/dev/null
        systemctl disable --now iscsid.service iscsid.socket iscsi.service >/dev/null 2>&1
        grep -qs "$LegacyInitiatorIqn" /etc/iscsi/initiatorname.iscsi &&
            rm -f /etc/iscsi/initiatorname.iscsi
    fi

    if command -v targetcli >/dev/null 2>&1; then
        modprobe -a target_core_mod target_core_pscsi iscsi_target_mod 2>/dev/null
        targetcli /iscsi delete "$TargetIqn" >/dev/null 2>&1
        targetcli /iscsi delete "$LegacyTargetIqn" >/dev/null 2>&1
        for Item in drive0 drive1 "${BackstorePrefix}0" "${BackstorePrefix}1" "${BackstorePrefix}2"; do
            targetcli /backstores/pscsi delete "$Item" >/dev/null 2>&1
        done
        systemctl disable --now target.service >/dev/null 2>&1
    fi

    rmdir /mnt/dvd /mnt/bluray 2>/dev/null
    Info "Leftovers removed."
    Pause
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

Main() {
    EnsureRoot
    ResolveDataDir
    trap Cleanup EXIT
    trap 'exit 130' INT TERM
    while true; do
        Menu "What do you want to do on this PC?" \
            "Server  - this PC has the drives" \
            "Client  - this PC wants to use the drives" \
            "Remove leftovers of old setups" \
            "Quit" || exit 0
        case $MenuChoice in
            0) RunServer; exit 0 ;;
            1) RunClient; exit 0 ;;
            2) CleanLeftovers ;;
            3) exit 0 ;;
        esac
    done
}

Main
