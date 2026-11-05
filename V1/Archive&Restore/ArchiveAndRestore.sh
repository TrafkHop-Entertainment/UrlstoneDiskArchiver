#!/usr/bin/env bash
# Archive&Restore (part of UrlstoneDiskArchiver)
#
# 1. Archive: copy a DVD to disk (dvdbackup), optionally rescue damaged discs first (ddrescue).
# 2. Restore: field matching / deinterlacing, rainbow and dot crawl removal, grain and noise
#    removal, dropout removal and classic upscaling. Audio is analysed per track.
#    Both parts can show preview frames before the real work starts.
#
# Fully interactive. Temporary files are removed on exit.
# Only user settings are kept in the data folder. The private Python environment
# with VapourSynth and its plugins also lives there and stays installed.
#
# Optional AI tools (off by default, switch them on under Settings; the AI options only appear
# after that):
#   - Video: any ONNX model (upscaler, denoiser, deblocker) runs through onnxruntime.
#     The AnimeJaNai models can be downloaded from the menu. Tested with one of them.
#   - Video: RIFE frame interpolation through the vsrife package (needs PyTorch). Not tested.
#   - Audio: DeepFilterNet noise cleanup and AudioSR bandwidth extension in a separate
#     private environment. Not tested. AudioSR needs an older Python (3.11 or older).
# Only features that work for PAL and NTSC are included (no NTSC-only filters).

DataDir=""
ConfigFile=""
VenvDir=""
PyBin="python3"
VspipeBin="vspipe"
HelperFile=""
TempRoot=""
WorkDir=""
OutputDir=""
ArchiveDir=""
InputPath=""
Answer=""
EnvScope="all"

CleanupStack=()
MenuChoice=0
MenuStart=0
KeyName=""
InitialFlags=()
CheckedFlags=()
DiscPaths=()
DriveDevs=()
TitleIxList=()
TitleSelList=()
TitleLabelList=()
SelectedTitles=()
NeedSys=()
NeedPy=0
NeedCss=0
NeedAi=0
AiAudioFiles=()
ModelFiles=()
AudioAiEnv=""
SudoCmd=()
HaveDvdvideo=false
TestClip=false
DiscDevice=""
DiscName=""
ProbeKey=""

# Settings (remembered in the config file)
Upscale=true
Height=1080
Resizer="spline36"
Sharpen="off"
Denoise="normal"
Spots="on"
Rainbow="off"
AudioEnhance="off"
KeepBorders=false
Deint="auto"
DoubleRate=false
AudioMode="copy"
Codec="x265"
Crf=18
Preset="slow"
KeepTemp=false
Overwrite=false
# Advanced settings
DenoiseValue=0
ChromaPercent=70
SpotsValue=400
RumbleHz=25
NoiseMedium=8
NoiseStrong=14
TestSeconds=25
TestStartPercent=30
PreviewInterval=60
PreviewMax=12
ColorTags="auto"
Container="mkv"
RescueRetries=3
# AI tools (only visible when AiTools is on)
AiTools=false
AiModel=""
AiProvider="auto"
AiTile=256
AiInterpolate=0
AiAudio="off"
SettingNames=(AudioEnhance AiTools AiModel AiProvider AiTile AiInterpolate AiAudio Upscale Height Resizer Sharpen Denoise Spots Rainbow KeepBorders Deint DoubleRate
              AudioMode Codec Crf Preset KeepTemp Overwrite DenoiseValue ChromaPercent SpotsValue
              RumbleHz NoiseMedium NoiseStrong TestSeconds
              TestStartPercent PreviewInterval PreviewMax ColorTags Container RescueRetries)

# Values reported by the probe step for the current title
SrcWidth=0; SrcHeight=0; Duration=0; Fps=25; SarSrc=1; DarSrc=1
FieldMode="progressive"; Tff=true
CropLeft=0; CropRight=0; CropTop=0; CropBottom=0
Dar=1; OutWidth=0; OutHeight=0; VideoOffset=0; AudioCount=0; SubCount=0

PyPackages=(vapoursynth vapoursynth-bestsource vapoursynth-lsmas vapoursynth-tivtc vapoursynth-mvtools
            "vapoursynth-mvutensils==9" vapoursynth-znedi3 vapoursynth-eedi3 vapoursynth-zsmooth
            vapoursynth-sangnom vapoursynth-resize2 vapoursynth-decross
            havsfunc vsjetpack numpy)

Bold=$'\e[1m'; Dim=$'\e[2m'; Reverse=$'\e[7m'; Reset=$'\e[0m'
Red=$'\e[31m'; Green=$'\e[32m'; Yellow=$'\e[33m'

set -o pipefail

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

# AskText <prompt> [default]  -> sets Answer (the default can be edited)
AskText() {
    Answer=""
    read -e -r -p "$1 " -i "${2:-}" Answer
    [[ -n $Answer ]] || Answer=${2:-}
}

HasCmd() { command -v "$1" >/dev/null 2>&1; }

# Register a command that runs (in reverse order) when the script ends
Defer() { CleanupStack+=("$*"); }

Cleanup() {
    local I
    trap - EXIT INT TERM
    printf '\e[?25h\n'
    Info "Cleaning up..."
    for (( I = ${#CleanupStack[@]} - 1; I >= 0; I-- )); do
        eval "${CleanupStack[$I]}" >/dev/null 2>&1
    done
    Info "Done."
}

Header() {
    printf '\e[H\e[2J'
    printf '%s Archive&Restore %s| archive and restore DVDs%s\n' "$Bold" "$Dim" "$Reset"
    printf '%s----------------------------------------------%s\n\n' "$Dim" "$Reset"
}

# Open a folder in the file manager (as the normal user), or just print the path
OpenFolder() {
    local User=${SUDO_USER:-}
    if ! HasCmd xdg-open; then Info "Folder: $1"; return; fi
    if [[ $EUID -eq 0 && -n $User ]]; then
        sudo -u "$User" nohup xdg-open "$1" >/dev/null 2>&1 &
    else
        nohup xdg-open "$1" >/dev/null 2>&1 &
    fi
    Info "Opened: $1"
}

# ------------------------------------------------------------
# Persistent user settings
# ------------------------------------------------------------

ResolveDataDir() {
    local User=${SUDO_USER:-${USER:-root}} Home
    Home=$(getent passwd "$User" | cut -d: -f6)
    Home=${Home:-$HOME}
    DataDir="$Home/.local/share/TrafkHopEntertainment/UrlstoneDiskArchiver"
    ConfigFile="$DataDir/ArchiveAndRestore.conf"
    VenvDir="$DataDir/ArchiveAndRestore-env"
    AudioAiEnv="$DataDir/ArchiveAndRestore-audio-ai-env"
    mkdir -p "$DataDir/models"
    [[ $EUID -eq 0 && $User != root ]] && chown -R "$User:" "$Home/.local/share/TrafkHopEntertainment"
    [[ $EUID -ne 0 ]] && SudoCmd=(sudo)
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

SetDefaultSettings() {
    Upscale=true; Height=1080; Resizer="spline36"; Sharpen="off"; Denoise="normal"; Spots="on"
    Rainbow="off"; AudioEnhance="off"; KeepBorders=false; Deint="auto"; DoubleRate=false; AudioMode="copy"; Codec="x265"
    Crf=18; Preset="slow"; KeepTemp=false; Overwrite=false
    AiTools=false; AiModel=""; AiProvider="auto"; AiTile=256; AiInterpolate=0; AiAudio="off"
    SetDefaultAdvanced
}

SetDefaultAdvanced() {
    DenoiseValue=0; ChromaPercent=70; SpotsValue=400; RumbleHz=0; NoiseMedium=8; NoiseStrong=14
    TestSeconds=25; TestStartPercent=30
    PreviewInterval=60; PreviewMax=12; ColorTags="auto"; Container="mkv"; RescueRetries=3
}

# Read every remembered setting, keep the built-in default where nothing is saved
LoadSettings() {
    local Name Value
    for Name in "${SettingNames[@]}"; do
        Value=$(GetConfig "$Name")
        [[ -n $Value ]] && printf -v "$Name" '%s' "$Value"
    done
    [[ $AudioMode == upsample || $AudioMode == fixed ]] && AudioMode="copy"     # removed modes
}

SaveSettings() {
    local Name
    for Name in "${SettingNames[@]}"; do SetConfig "$Name" "${!Name}"; done
}

SettingsSummary() {
    local UpText="no" Border="remove automatically" Level=$Denoise
    [[ $Upscale == true ]] && UpText="yes, ${Height}p with $Resizer, sharpening: $Sharpen"
    [[ $KeepBorders == true ]] && Border="keep"
    (( DenoiseValue > 0 )) && [[ $Denoise != off ]] && Level="$Denoise (custom value $DenoiseValue)"
    printf '  Upscale      : %s\n' "$UpText"
    printf '  Noise        : %s    Dropouts/streaks: %s    Rainbows: %s\n' "$Level" "$Spots" "$Rainbow"
    printf '  Fields       : %s%s\n' "$Deint" "$([[ $DoubleRate == true ]] && echo ' (true interlace to 50 fps)')"
    printf '  Black borders: %s\n' "$Border"
    case $AudioMode in
        copy) printf '  Audio        : original, unchanged\n' ;;
        *)    printf '  Audio        : processing on (%s), enhancement: %s\n' "$AudioMode" "$AudioEnhance" ;;
    esac
    printf '  Video        : %s, CRF %s, preset %s, container %s\n' "$Codec" "$Crf" "$Preset" "$Container"
    if [[ $AiTools == true ]]; then
        printf '  AI (on)      : video model %s, interpolation %s, audio %s\n' \
            "${AiModel:+${AiModel##*/}}" "$([[ $AiInterpolate == 0 ]] && echo off || echo "${AiInterpolate}x")" "$AiAudio"
    fi
}

# ------------------------------------------------------------
# TUI widgets
# ------------------------------------------------------------

ReadKey() {
    local Key Rest
    IFS= read -rsn1 Key || { KeyName=Quit; return; }
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
# MenuStart (set by the caller) preselects an item.
Menu() {
    local Title=$1; shift
    local Items=("$@") Count=$# Selected=$MenuStart I
    MenuStart=0
    (( Selected >= Count )) && Selected=0
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

# Checklist <title> <items...>  -> fills CheckedFlags, returns 1 on back
# InitialFlags (set by the caller) holds the preselection, default is "all checked".
Checklist() {
    local Title=$1; shift
    local Items=("$@") Count=$# Cursor=0 I Mark
    CheckedFlags=()
    for (( I = 0; I < Count; I++ )); do
        if (( ${#InitialFlags[@]} == Count )); then CheckedFlags[I]=${InitialFlags[$I]}; else CheckedFlags[I]=1; fi
    done
    InitialFlags=()
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

# PickOption <VarName> <title> <"value|label"...>  -> sets the variable, preselects its current value
PickOption() {
    local Var=$1 Title=$2; shift 2
    local Options=("$@") Labels=() I
    MenuStart=0
    for I in "${!Options[@]}"; do
        Labels+=("${Options[$I]#*|}")
        [[ ${Options[$I]%%|*} == "${!Var}" ]] && MenuStart=$I
    done
    Menu "$Title" "${Labels[@]}" || return 1
    printf -v "$Var" '%s' "${Options[$MenuChoice]%%|*}"
}

# AskNumber <VarName> <prompt> [min] [max]  -> keeps the old value on invalid input
AskNumber() {
    local Var=$1 Min=${3:-0} Max=${4:-999999}
    Header
    printf '%b\n\n' "$2"
    AskText "Value:" "${!Var}"
    if [[ $Answer =~ ^[0-9]+$ ]] && (( Answer >= Min && Answer <= Max )); then
        printf -v "$Var" '%s' "$Answer"
    else
        Warn "Invalid value (allowed: $Min to $Max). Kept ${!Var}."
        Pause
    fi
}

# AskYesNo <question> [default: yes|no]  -> returns 0 for yes, 1 for no or back
AskYesNo() {
    MenuStart=0
    [[ ${2:-yes} == no ]] && MenuStart=1
    Menu "$1" "Yes" "No" || return 1
    (( MenuChoice == 0 ))
}

# ------------------------------------------------------------
# Settings dialogs
# ------------------------------------------------------------

CustomizeSettings() {
    local Default=16
    PickOption Upscale "Upscale the video?" "true|Yes" "false|No (restore only, keep the original size)" || return 1
    if [[ $Upscale == true ]]; then
        PickOption Height "Target height. The width follows the detected aspect ratio." \
            "720|720p" "1080|1080p (recommended)" "1440|1440p" "2160|2160p (4K)" || return 1
        PickOption Resizer "Scaling method (classic kernels, no AI)" \
            "spline36|Spline36 - clean, little ringing (recommended)" \
            "lanczos|Lanczos3 - a bit sharper, slight ringing possible" \
            "spline64|Spline64 - sharper than Spline36" \
            "bicubic|Bicubic - soft" \
            "nearest|Nearest neighbor - hard square pixels (usually looks bad on video)" || return 1
        PickOption Sharpen "Sharpen after scaling" "off|Off" "0.3|Light" "0.6|Medium" || return 1
    else
        Sharpen="off"
    fi
    PickOption Denoise "Remove grain and MPEG-2 noise (grey luma noise and colored chroma noise)" \
        "off|Off" "light|Light" "normal|Normal (recommended)" "strong|Strong (can soften detail)" || return 1
    PickOption Spots "Remove dropouts and short streaks (temporal median)" \
        "on|On (recommended)" "off|Off" || return 1
    PickOption Rainbow "Rainbowing (cross color, analog color artifacts)" \
        "off|Off (recommended unless you see them)" \
        "decross|Remove rainbows (DeCross, works for PAL and NTSC)" || return 1
    PickOption Deint "Fields and interlacing" \
        "auto|Detect automatically (recommended)" \
        "off|Do nothing (material is progressive)" \
        "match|Re-match fields (shifted or mixed material)" \
        "bob|Deinterlace true interlacing with QTGMC" || return 1
    DoubleRate=false
    if [[ $Deint == auto || $Deint == bob ]]; then
        PickOption DoubleRate "If true interlacing is found: keep all 50 motion phases per second (50 fps) instead of 25 fps?\nOnly useful for video-shot material (TV, concerts, sports). Animation and film gain nothing." \
            "false|No (recommended)" "true|Yes" || return 1
    fi
    PickOption KeepBorders "Black borders" "false|Remove automatically (recommended)" "true|Keep" || return 1
    PickOption AudioMode "Audio. The original is kept unchanged unless you switch processing on here." \
        "copy|Original audio, unchanged (default)" \
        "auto|Processing on: measure each track, repair only what is wrong (noise, hum, clipping, fake stereo), lossless FLAC" \
        "clean|Processing on: same fixed noise filter on all tracks, lossless FLAC" || return 1
    if [[ $AudioMode != copy ]]; then
        PickOption AudioEnhance "Audio enhancement: harmonic exciter (classic, no AI).\nIt invents extra overtones, so dull old tracks sound brighter. It does not restore real detail and can sound harsh on speech. Compare before you keep it." \
            "off|Off (recommended)" "light|Light (exciter)" "medium|Medium (exciter + dynamics crystalizer)" || return 1
    fi
    PickOption Codec "Video codec" \
        "x265|x265 / HEVC 10 bit (small, recommended)" "x264|x264 / H.264 10 bit (more compatible)" || return 1
    [[ $Codec == x265 ]] && Default=18
    AskNumber Crf "Quality (CRF): lower means better quality and larger files. 16-20 is usual. Suggested: $Default" 0 51
    PickOption Preset "Encoder speed" "medium|Medium (faster)" "slow|Slow (recommended)" "slower|Slower (a bit smaller)" || return 1
    PickOption KeepTemp "Keep temporary files after each disc? (needs a lot of space, saves the extraction on a rerun)" \
        "false|No" "true|Yes" || return 1
    PickOption Overwrite "Results that already exist" "false|Skip them (recommended)" "true|Overwrite" || return 1
    if [[ $AiTools == true ]]; then CustomizeAi || return 1; fi
}

# The .onnx models in the models folder
ScanModels() {
    ModelFiles=()
    while IFS= read -r Item; do ModelFiles+=("$Item"); done < <(find "$DataDir/models" -maxdepth 2 -name '*.onnx' 2>/dev/null | sort)
}

# Download the AnimeJaNai models (ONNX, about 6 MB) from the vs-mlrt release page
DownloadModels() {
    local Url="https://github.com/AmusementClub/vs-mlrt/releases/download/v14/contrib-models.v14.7z" Tmp
    HasCmd curl || { Fail "curl is needed for the download."; Pause; return 1; }
    "$PyBin" -c "import py7zr" 2>/dev/null || { Fail "py7zr is missing. Use 'Check environment / install missing parts' with AI tools on."; Pause; return 1; }
    mkdir -p "$DataDir/models"
    Tmp=$(mktemp --suffix=.7z)
    Header
    Info "Downloading the AnimeJaNai models (about 6 MB)..."
    if ! curl -fL --progress-bar -o "$Tmp" "$Url"; then
        Fail "Download failed."; rm -f "$Tmp"; Pause; return 1
    fi
    "$PyBin" - "$Tmp" "$DataDir/models" <<'ARMODELEOF'
import sys, os, shutil, tempfile, py7zr
Archive, Dest = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as Tmp:
    with py7zr.SevenZipFile(Archive) as Z:
        Z.extractall(Tmp)
    for Root, _, Files in os.walk(Tmp):
        for Name in Files:
            if Name.endswith(".onnx"):
                shutil.move(os.path.join(Root, Name), os.path.join(Dest, Name))
ARMODELEOF
    rm -f "$Tmp"
    Info "Models saved in $DataDir/models"
    Pause
}

# AI options (video model, runtime, interpolation, audio)
CustomizeAi() {
    local Labels=() I Choice
    while true; do
        ScanModels
        Labels=("Off (no AI model)")
        for I in "${!ModelFiles[@]}"; do Labels+=("${ModelFiles[$I]##*/}   ($(du -h "${ModelFiles[$I]}" | cut -f1))"); done
        Labels+=("Download the AnimeJaNai models (about 6 MB)" "Enter the path of an .onnx model...")
        MenuStart=0
        for I in "${!ModelFiles[@]}"; do [[ ${ModelFiles[$I]} == "$AiModel" ]] && MenuStart=$(( I + 1 )); done
        Menu "AI video model (upscaler, denoiser or deblocker, any ONNX model)\n${Dim}  Anime upscalers like AnimeJaNai work best; the model's scale (1x, 2x, 4x) is detected automatically.${Reset}" "${Labels[@]}" || return 1
        Choice=$MenuChoice
        if (( Choice == 0 )); then AiModel=""; break
        elif (( Choice <= ${#ModelFiles[@]} )); then AiModel=${ModelFiles[$(( Choice - 1 ))]}; break
        elif (( Choice == ${#ModelFiles[@]} + 1 )); then DownloadModels
        else
            Header
            AskText "Path of the .onnx file:" ""
            Answer=${Answer//\'/}; Answer=${Answer/#\~/$HOME}
            if [[ -f $Answer && $Answer == *.onnx ]]; then AiModel=$Answer; break; fi
            Fail "Not an .onnx file: $Answer"; Pause
        fi
    done
    PickOption AiProvider "AI runtime device" \
        "auto|Automatic (NVIDIA CUDA if available, otherwise CPU)" "cuda|NVIDIA CUDA" "rocm|AMD ROCm" "cpu|CPU only" || return 1
    PickOption AiTile "Tile size for the AI model (smaller uses less memory)" \
        "0|Whole frame (needs a lot of memory)" "128|128" "256|256 (recommended)" "512|512" || return 1
    PickOption AiInterpolate "AI frame interpolation (RIFE). Experimental, untested, downloads PyTorch (about 2 GB).\nUsually unwanted for anime (soap opera effect)." \
        "0|Off (recommended)" "2|2x frame rate" || return 1
    PickOption AiAudio "AI audio processing (experimental, untested, mono and stereo tracks only)" \
        "off|Off (recommended)" \
        "denoise|Noise cleanup (DeepFilterNet)" \
        "superres|Bandwidth extension (AudioSR, needs Python 3.11 or older, large download)" || return 1
}

# Every advanced value as "label|variable|kind"; kind is "num:min:max" or "pick:a,b,c"
AdvancedItems=(
    "Denoise strength, luma threshold (0 = use the preset)|DenoiseValue|num:0:2000"
    "Chroma denoise strength in % of luma (raise for colored noise)|ChromaPercent|num:0:300"
    "Dropout and streak threshold|SpotsValue|num:1:5000"
    "Audio rumble filter in Hz (0 = off; turning it on re-encodes every track)|RumbleHz|num:0:200"
    "Audio noise filter, medium noise (dB)|NoiseMedium|num:1:40"
    "Audio noise filter, strong noise (dB)|NoiseStrong|num:1:40"
    "Test clip length (seconds)|TestSeconds|num:3:600"
    "Test clip start (% of the title)|TestStartPercent|num:0:90"
    "Preview: one frame every N seconds|PreviewInterval|num:5:3600"
    "Preview: maximum frames per title|PreviewMax|num:1:200"
    "Color tags in the video file|ColorTags|pick:auto,off"
    "Container|Container|pick:mkv,mp4"
    "ddrescue: retries for bad sectors|RescueRetries|num:0:20"
)

AdvancedSettings() {
    local Labels=() Item Label Var Kind Choices Options=() Values=() Min Max I Pos=0
    while true; do
        Labels=()
        for Item in "${AdvancedItems[@]}"; do
            Label=${Item%%|*}; Var=${Item#*|}; Var=${Var%%|*}
            Labels+=("$(printf '%-62s %s' "$Label" "[${!Var}]")")
        done
        Labels+=("Reset all advanced values to the defaults")
        MenuStart=$Pos
        Menu "Advanced settings. Enter changes a value.\n${Dim}  Container mp4 drops the DVD's bitmap subtitles. The audio values only matter when audio processing is switched on.${Reset}" "${Labels[@]}" || return 0
        Pos=$MenuChoice
        if (( MenuChoice == ${#AdvancedItems[@]} )); then
            SetDefaultAdvanced; continue
        fi
        Item=${AdvancedItems[$MenuChoice]}
        Label=${Item%%|*}; Var=${Item#*|}; Var=${Var%%|*}; Kind=${Item##*|}
        case $Kind in
            num:*)
                IFS=: read -r _ Min Max <<< "$Kind"
                AskNumber "$Var" "$Label" "$Min" "$Max" ;;
            pick:*)
                Choices=${Kind#pick:}
                Options=()
                IFS=, read -ra Values <<< "$Choices"
                for I in "${!Values[@]}"; do Options+=("${Values[$I]}|${Values[$I]}"); done
                PickOption "$Var" "$Label" "${Options[@]}" ;;
        esac
        SaveSettings
    done
}

# ------------------------------------------------------------
# Environment: check and install
# ------------------------------------------------------------

HasDvdvideoDemuxer() { ffmpeg -hide_banner -demuxers 2>/dev/null | grep -qw dvdvideo; }

HasLibdvdcss() { ldconfig -p 2>/dev/null | grep -q libdvdcss; }

# Prefer the private environment, otherwise use the system Python
UseVenv() {
    if [[ -x "$VenvDir/bin/vspipe" && -x "$VenvDir/bin/python3" ]]; then
        PyBin="$VenvDir/bin/python3"
        VspipeBin="$VenvDir/bin/vspipe"
        "$VenvDir/bin/vapoursynth" config >/dev/null 2>&1     # lets vspipe find its Python
    else
        PyBin="python3"
        VspipeBin="vspipe"
    fi
}

# CheckEnv [show]  uses EnvScope (archive, repair, restore or all).
# Fills NeedSys (missing system tools) and NeedPy (1 if the Python side is incomplete).
CheckEnv() {
    local Show=${1:-} Tool Report Tools=() PyNeeded=0
    NeedSys=(); NeedPy=0; NeedCss=0; NeedAi=0
    Say() { [[ $Show == show ]] && printf '%s\n' "$*"; }
    case $EnvScope in
        archive) Tools=(dvdbackup lsdvd) ;;
        repair)  Tools=(dvdbackup ddrescue lsdvd) ;;
        restore) Tools=(ffmpeg ffprobe lsdvd); PyNeeded=1 ;;
        *)       Tools=(dvdbackup ddrescue ffmpeg ffprobe lsdvd); PyNeeded=1 ;;
    esac
    for Tool in "${Tools[@]}"; do
        if HasCmd "$Tool"; then Say "  ok       $Tool"; else Say "  missing  $Tool"; NeedSys+=("$Tool"); fi
    done
    if [[ $EnvScope == restore || $EnvScope == all ]]; then
        if HasCmd ffmpeg && HasDvdvideoDemuxer; then
            Say "  ok       ffmpeg can read DVD titles directly (dvdvideo)"
        elif HasCmd mpv; then
            Say "  ok       mpv (reads DVD titles and makes disc previews)"
        else
            Say "  missing  mpv (or ffmpeg 7.1+ with libdvdnav) to read DVD titles"; NeedSys+=("mpv")
        fi
    fi
    if HasLibdvdcss; then
        Say "  ok       libdvdcss (encrypted discs)"
    else
        Say "  note     libdvdcss not found: encrypted discs cannot be read (Arch: libdvdcss, Debian: libdvd-pkg, Fedora: RPM Fusion)"
        HasCmd pacman && NeedCss=1
    fi
    (( PyNeeded )) || return 0
    if [[ -x "$VenvDir/bin/vspipe" ]]; then
        Say "  ok       private Python environment: $VenvDir"
    else
        Say "  missing  private Python environment with VapourSynth and plugins (installed with pip)"
    fi
    Report=$("$PyBin" - <<'ARCHECKEOF' 2>&1
import importlib
Bad = 0
try:
    import vapoursynth as Vs
    Core = Vs.core
except Exception:
    print("  missing  python-vapoursynth"); print("RESULT=1"); raise SystemExit
print("  ok       VapourSynth")
Sources = [N for N in ("bs", "lsmas", "ffms2") if hasattr(Core, N)]
print(f"  {'ok      ' if Sources else 'missing '} source filter ({', '.join(Sources) or 'bs/lsmas/ffms2'})")
Bad += not Sources
for Name, Why in [("tivtc", "TIVTC (field matching / IVTC)"), ("mv", "MVTools (dropouts + denoising)"),
                  ("mvu", "MVTools-Utensils (QTGMC)"), ("znedi3", "znedi3 (QTGMC)"), ("eedi3m", "eedi3 (QTGMC)"),
                  ("resize2", "resize2 (QTGMC)"), ("zsmooth", "zsmooth (QTGMC)"),
                  ("decross", "DeCross (rainbows)")]:
    Ok = hasattr(Core, Name)
    Bad += not Ok
    print(f"  {'ok      ' if Ok else 'missing '} plugin {Name:8} {Why}")
for Name, Why in (("vsdeinterlace", "QTGMC (true interlacing)"), ("numpy", "field and audio analysis")):
    try:
        importlib.import_module(Name)
        print(f"  ok       Python module {Name}")
    except Exception:
        print(f"  missing  Python module {Name} ({Why})")
        Bad += 1
print(f"RESULT={1 if Bad else 0}")
ARCHECKEOF
)
    [[ $Show == show ]] && printf '%s\n' "$Report" | grep -v '^RESULT='
    printf '%s\n' "$Report" | grep -q '^RESULT=0' || NeedPy=1
    [[ $AiTools == true ]] || return 0
    if "$PyBin" -c "import onnxruntime, py7zr" 2>/dev/null; then
        Say "  ok       AI video runtime (onnxruntime, py7zr)"
    else
        Say "  missing  AI video runtime (onnxruntime, py7zr)"; NeedAi=1
    fi
    if [[ $AiInterpolate != 0 ]]; then
        if "$PyBin" -c "import vsrife" 2>/dev/null; then Say "  ok       vsrife (RIFE)"; else Say "  missing  vsrife (RIFE, downloads PyTorch)"; NeedAi=1; fi
    fi
    if [[ $AiAudio == denoise ]]; then
        if [[ -x $AudioAiEnv/bin/deepFilter ]]; then Say "  ok       DeepFilterNet"; else Say "  missing  DeepFilterNet (own environment)"; NeedAi=1; fi
    elif [[ $AiAudio == superres ]]; then
        if [[ -x $AudioAiEnv/bin/python3 ]] && "$AudioAiEnv/bin/python3" -c "import audiosr" 2>/dev/null; then
            Say "  ok       AudioSR"
        else
            Say "  missing  AudioSR (own environment, needs Python 3.11 or older)"; NeedAi=1
        fi
    fi
}

# The vapoursynth wheels need Python 3.12 or newer
PickPython() {
    local Candidate
    for Candidate in python3.13 python3.12 python3.14 python3; do
        if HasCmd "$Candidate" &&
           "$Candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
            echo "$Candidate"; return 0
        fi
    done
    return 1
}

# PackageFor <manager> <tool>  -> package name for that tool
PackageFor() {
    case $2 in
        ddrescue) if [[ $1 == apt || $1 == zypper ]]; then echo gddrescue; else echo ddrescue; fi ;;
        ffprobe) echo ffmpeg ;;
        *) echo "$2" ;;
    esac
}

InstallEnv() {
    local Manager="" Pkgs=() Cmd=() Tool Pkg Py
    if HasCmd pacman; then Manager=pacman
    elif HasCmd apt-get; then Manager=apt
    elif HasCmd dnf; then Manager=dnf
    elif HasCmd zypper; then Manager=zypper
    fi
    for Tool in "${NeedSys[@]}"; do
        Pkg=$(PackageFor "$Manager" "$Tool")
        [[ -n $Pkg && " ${Pkgs[*]} " != *" $Pkg "* ]] && Pkgs+=("$Pkg")
    done
    if (( NeedCss )) && [[ $Manager == pacman ]]; then Pkgs+=(libdvdcss); fi
    if [[ $Manager == apt ]] && (( NeedPy )) && ! "$(PickPython || echo python3)" -m venv --help >/dev/null 2>&1; then
        Pkgs+=(python3-venv)
    fi
    if (( ${#Pkgs[@]} )); then
        case $Manager in
            pacman) Cmd=("${SudoCmd[@]}" pacman -S --needed "${Pkgs[@]}") ;;
            apt)    Cmd=("${SudoCmd[@]}" apt-get install -y "${Pkgs[@]}") ;;
            dnf)    Cmd=("${SudoCmd[@]}" dnf install -y "${Pkgs[@]}") ;;
            zypper) Cmd=("${SudoCmd[@]}" zypper install -y "${Pkgs[@]}") ;;
            *)      Warn "Package manager not recognised. Please install: ${Pkgs[*]}"; Pause ;;
        esac
        if (( ${#Cmd[@]} )); then
            if AskYesNo "System packages are missing: ${Pkgs[*]}\n\nCommand: ${Cmd[*]}\n\nRun it now? (it may ask for your password)"; then
                Header
                "${Cmd[@]}" || { Warn "The installation failed (on Fedora mpv/ffmpeg often need RPM Fusion). Please install them by hand."; Pause; }
            fi
        fi
    fi
    if (( NeedPy )); then
        Py=$(PickPython) || { Warn "Python 3.12 or newer is needed for the VapourSynth packages."; Pause; return 0; }
        if [[ $(uname -m) != x86_64 ]]; then
            Warn "Ready-made plugin packages exist for x86_64 only. Please install VapourSynth and the plugins with your distribution."
            Pause; return 0
        fi
        if AskYesNo "A private Python environment with VapourSynth and all plugins will be installed (a few hundred MB).\n\n  Location: $VenvDir\n\nYour system is not touched, and you can delete the folder at any time. Install now?"; then
            Header
            mkdir -p "$DataDir"
            if [[ ! -x "$VenvDir/bin/python3" ]]; then
                "$Py" -m venv "$VenvDir" || { Fail "Could not create the environment (Debian/Ubuntu: package python3-venv)."; Pause; return 0; }
            fi
            "$VenvDir/bin/pip" install --upgrade pip >/dev/null 2>&1
            "$VenvDir/bin/pip" install --upgrade "${PyPackages[@]}" || { Fail "pip install failed (internet connection?)."; Pause; return 0; }
            "$VenvDir/bin/vapoursynth" config >/dev/null 2>&1 || Warn "'vapoursynth config' failed, vspipe may not find its Python."
        fi
    fi
    UseVenv
    if (( NeedAi )); then InstallAi; fi
}

HasNvidia() { HasCmd nvidia-smi && nvidia-smi -L >/dev/null 2>&1; }

PickOldPython() {
    local Candidate
    for Candidate in python3.11 python3.10 python3.9; do
        HasCmd "$Candidate" && { echo "$Candidate"; return 0; }
    done
    return 1
}

# Install the optional AI parts that the current settings need
InstallAi() {
    local Py Pkg Old
    Py=$(PickPython) || { Warn "Python 3.12 or newer is needed."; Pause; return 0; }
    if ! "$PyBin" -c "import onnxruntime, py7zr" 2>/dev/null && [[ -x $VenvDir/bin/pip ]]; then
        Pkg=onnxruntime; HasNvidia && Pkg=onnxruntime-gpu
        if AskYesNo "Install the AI video runtime ($Pkg and py7zr) into the private environment?"; then
            Header
            "$VenvDir/bin/pip" install --upgrade "$Pkg" py7zr || { Fail "pip install failed."; Pause; }
        fi
    fi
    if [[ $AiInterpolate != 0 ]] && ! "$PyBin" -c "import vsrife" 2>/dev/null; then
        if AskYesNo "RIFE frame interpolation needs vsrife and PyTorch (about 2 GB). Install it now?" no; then
            Header
            "$VenvDir/bin/pip" install --upgrade vsrife || { Fail "pip install failed."; Pause; }
        fi
    fi
    if [[ $AiAudio == denoise && ! -x $AudioAiEnv/bin/deepFilter ]]; then
        if AskYesNo "DeepFilterNet needs its own environment with PyTorch (about 2 GB). Install it now?" no; then
            Header
            "$Py" -m venv "$AudioAiEnv" && "$AudioAiEnv/bin/pip" install --upgrade pip >/dev/null 2>&1
            "$AudioAiEnv/bin/pip" install --upgrade deepfilternet || { Fail "pip install failed."; Pause; }
        fi
    elif [[ $AiAudio == superres ]] && ! { [[ -x $AudioAiEnv/bin/python3 ]] && "$AudioAiEnv/bin/python3" -c "import audiosr" 2>/dev/null; }; then
        Old=$(PickOldPython) || { Warn "AudioSR needs Python 3.11 or older (it pins numpy 1.23). None is installed."; Pause; return 0; }
        if AskYesNo "AudioSR needs its own environment with $Old and PyTorch (several GB). Install it now?" no; then
            Header
            "$Old" -m venv "$AudioAiEnv" && "$AudioAiEnv/bin/pip" install --upgrade pip >/dev/null 2>&1
            "$AudioAiEnv/bin/pip" install --upgrade audiosr || { Fail "pip install failed."; Pause; }
        fi
    fi
}

# EnsureEnv <scope>: check, offer the installation if something is missing.
# Returns 0 when everything is there. Missing libdvdcss alone is only a note.
EnsureEnv() {
    EnvScope=$1
    CheckEnv
    (( ${#NeedSys[@]} == 0 && NeedPy == 0 && NeedAi == 0 )) && return 0
    if AskYesNo "Some required parts are missing.\n\nInstall them automatically now?"; then
        InstallEnv
        CheckEnv
    fi
    (( ${#NeedSys[@]} == 0 && NeedPy == 0 && NeedAi == 0 ))
}

ShowEnvironment() {
    EnvScope=all
    Header
    Info "Checking the environment..."
    echo
    CheckEnv show
    if (( ${#NeedSys[@]} || NeedPy || NeedCss || NeedAi )); then
        if AskYesNo "Something is missing.\n\nInstall the missing parts automatically now?"; then
            InstallEnv
            Header
            CheckEnv show
        fi
    else
        printf '\n'; Info "Everything is installed."
    fi
    Pause
}

# ------------------------------------------------------------
# Drives and discs
# ------------------------------------------------------------

NormalizeRoot() {
    local Path=${1%/}
    if [[ ${Path##*/} =~ ^[Vv][Ii][Dd][Ee][Oo]_[Tt][Ss]$ ]]; then dirname "$Path"; else echo "$Path"; fi
}

# DiscoverDiscs <path>  -> prints disc roots or ISO files
DiscoverDiscs() {
    local Path=$1 Root
    if [[ -f $Path && ${Path,,} == *.iso ]]; then
        echo "$Path"
    elif [[ -d $Path ]]; then
        Root=$(NormalizeRoot "$Path")
        if [[ -d $Root/VIDEO_TS || -d $Root/video_ts ]]; then
            echo "$Root"
        else
            find "$Path" -maxdepth 3 \( -type d -iname VIDEO_TS -printf '%h\n' \) -o \( -type f -iname '*.iso' -print \) | sort
        fi
    fi
}

SafeName() {
    local Name=${1##*/}
    Name=${Name%.[iI][sS][oO]}
    echo "${Name//[\/:*?\"<>|&]/_}"
}

DriveLabel() {
    local Dev=$1 Name=${1##*/} Model Disc
    Model=$(cat "/sys/class/block/$Name/device/vendor" "/sys/class/block/$Name/device/model" 2>/dev/null | xargs)
    Disc=$(blkid -o value -s LABEL "$Dev" 2>/dev/null)
    printf '%s  %s%s' "$Dev" "${Model:-unknown drive}" "${Disc:+  [disc: $Disc]}"
}

DetectDrives() {
    local Dev
    DriveDevs=()
    for Dev in /dev/sr*; do
        [[ -b $Dev ]] && DriveDevs+=("$Dev")
    done
}

# SelectDrive  -> sets DiscDevice (a drive, an ISO file or a disc folder)
SelectDrive() {
    local Labels=() I
    DetectDrives
    for I in "${!DriveDevs[@]}"; do Labels+=("$(DriveLabel "${DriveDevs[$I]}")"); done
    Labels+=("Other path (ISO file or disc folder)...")
    Menu "Select the DVD drive" "${Labels[@]}" || return 1
    if (( MenuChoice == ${#DriveDevs[@]} )); then
        Header
        AskText "Path to an ISO file or a disc folder:" ""
        DiscDevice=${Answer//\'/}
        DiscDevice=${DiscDevice/#\~/$HOME}
        [[ -e $DiscDevice ]] || { Fail "Not found: $DiscDevice"; Pause; return 1; }
    else
        DiscDevice=${DriveDevs[$MenuChoice]}
    fi
}

# Read the titles of a disc into TitleIxList / TitleSelList / TitleLabelList
ScanDisc() {
    local Src=$1 Ix Sel Label
    TitleIxList=(); TitleSelList=(); TitleLabelList=()
    lsdvd -x -Ox "$Src" 2>/dev/null > "$WorkDir/lsdvd.xml"
    while IFS=$'\t' read -r Ix Sel Label; do
        [[ -n $Ix ]] || continue
        TitleIxList+=("$Ix"); TitleSelList+=("$Sel"); TitleLabelList+=("$Label")
    done < <("$PyBin" "$HelperFile" titles "$WorkDir/lsdvd.xml" --out "$WorkDir/titles.json")
    (( ${#TitleIxList[@]} ))
}

# ------------------------------------------------------------
# Archive
# ------------------------------------------------------------

# Pull still frames from the titles of a disc (three per title) to see what is on it
PreviewDisc() {
    local Dev=$1 Dir Tmp Ix Pct Files=() Name
    HasCmd mpv || { Fail "mpv is needed for the disc preview."; Pause; return 1; }
    Name=$(SafeName "${DiscName:-disc}")
    Dir="${ArchiveDir:-$HOME/Videos/Archive}/Preview-$Name"
    WorkDir=$(mktemp -d); Defer "rm -rf '$WorkDir'"
    mkdir -p "$Dir"
    Header
    Info "Reading the title list..."
    ScanDisc "$Dev" || { Fail "Could not read the title list (disc not readable?)."; Pause; return 1; }
    for Ix in "${TitleIxList[@]}"; do
        Files=()
        for Pct in 20 50 80; do
            Tmp="$WorkDir/frame"; rm -rf "$Tmp"; mkdir -p "$Tmp"
            mpv --no-config --really-quiet --no-input-terminal --dvd-device="$Dev" "dvd://$Ix" --start="${Pct}%" --frames=1 \
                --no-audio --sid=no --vo=image --vo-image-format=png --vo-image-outdir="$Tmp" </dev/null >/dev/null 2>&1
            if [[ -f $Tmp/00000001.png ]]; then
                mv "$Tmp/00000001.png" "$Dir/Title$(printf '%02d' "$Ix")_${Pct}pct.png"
                Files+=("$Dir/Title$(printf '%02d' "$Ix")_${Pct}pct.png")
            fi
        done
        if (( ${#Files[@]} == 3 )); then
            ffmpeg -nostdin -v error -y -i "${Files[0]}" -i "${Files[1]}" -i "${Files[2]}" \
                -filter_complex "[0]scale=480:-2[a];[1]scale=480:-2[b];[2]scale=480:-2[c];[a][b][c]hstack=inputs=3" \
                "$Dir/Title$(printf '%02d' "$Ix")_sheet.png" 2>/dev/null
        fi
        Info "Title $Ix: ${#Files[@]} frame(s)"
    done
    OpenFolder "$Dir"
    Pause
}

# RunArchive <plain|repair>
RunArchive() {
    local Mode=$1 Label Default Out Iso Map Free Status=0 Rescue
    EnvScope=archive; [[ $Mode == repair ]] && EnvScope=repair
    EnsureEnv "$EnvScope" || { Fail "Required parts are still missing. Use 'Check environment' for details."; Pause; return 1; }
    SelectDrive || return 1

    Label=$(blkid -o value -s LABEL "$DiscDevice" 2>/dev/null)
    Default=${Label:-$(SafeName "$DiscDevice")}
    Header
    printf 'Name for this disc (it becomes the folder name).\n\n'
    AskText "Name:" "$Default"
    DiscName=$(SafeName "$Answer")
    [[ -n $DiscName ]] || return 1

    Default=$(GetConfig ArchiveDir)
    printf '\nWhere should the archive go?\n\n'
    AskText "Archive folder:" "${Default:-$HOME/Videos/Archive}"
    ArchiveDir=${Answer/#\~/$HOME}
    [[ -n $ArchiveDir ]] || return 1
    SetConfig ArchiveDir "$ArchiveDir"
    mkdir -p "$ArchiveDir"
    Out="$ArchiveDir"

    Header
    if [[ $Mode == plain ]]; then
        Info "Archiving $DiscDevice -> $Out/$DiscName"
        dvdbackup -i "$DiscDevice" -M -v -o "$Out" -n "$DiscName" || Status=$?
    else
        Free=$(df --output=avail -BG "$ArchiveDir" 2>/dev/null | tail -1 | tr -dc '0-9')
        if [[ -n $Free ]] && (( Free < 10 )); then
            Warn "Only ${Free} GB free in $ArchiveDir. The temporary ISO needs up to 9 GB."
            AskYesNo "Continue anyway?" no || return 1
        fi
        Rescue="$ArchiveDir/.rescue"
        mkdir -p "$Rescue"
        Iso="$Rescue/$DiscName.iso"
        Map="$Rescue/$DiscName.map"
        Info "Step 1/3: authenticating the drive (needed for encrypted discs)..."
        dvdbackup -i "$DiscDevice" -I >/dev/null 2>&1
        Info "Step 2/3: rescuing the disc to a temporary image (pass 1: quick, pass 2: retries)..."
        ddrescue -b 2048 -n "$DiscDevice" "$Iso" "$Map"
        ddrescue -b 2048 -d -r"$RescueRetries" "$DiscDevice" "$Iso" "$Map"
        if HasCmd ddrescuelog; then
            printf '\n%sRescue result:%s\n' "$Dim" "$Reset"
            ddrescuelog -t "$Map"
        fi
        Info "Step 3/3: extracting the disc structure from the image..."
        dvdbackup -i "$Iso" -M -v -o "$Out" -n "$DiscName" || Status=$?
        if (( Status == 0 )); then
            rm -f "$Iso" "$Map"
            rmdir "$Rescue" 2>/dev/null
            Info "Temporary image removed."
        else
            Warn "Extraction from the image failed. The image was kept for another try: $Iso"
        fi
    fi
    if (( Status != 0 )); then
        Fail "dvdbackup reported an error (exit code $Status)."
        Pause; return 1
    fi
    Info "Archive finished: $Out/$DiscName"
    SetConfig LastInput "$Out/$DiscName"
    [[ $DiscDevice == /dev/sr* ]] && AskYesNo "Eject the disc?" && eject "$DiscDevice" 2>/dev/null
    if AskYesNo "Restore this archive now? (the path is prefilled)" no; then
        RunRestore
    fi
}

ArchiveMenu() {
    while true; do
        MenuStart=0
        Menu "Archive - copy a DVD to your disk" \
            "Archive              (dvdbackup -M, copies the whole disc with menus)" \
            "Repair & Archive     (ddrescue first, then dvdbackup; for scratched or hanging discs)" \
            "Preview disc         (still frames from every title)" || return 0
        case $MenuChoice in
            0) RunArchive plain ;;
            1) RunArchive repair ;;
            2) EnvScope=archive
               EnsureEnv archive || { Fail "Required parts are still missing."; Pause; continue; }
               SelectDrive && PreviewDisc "$DiscDevice" ;;
        esac
    done
}

# ------------------------------------------------------------
# Restore
# ------------------------------------------------------------

# Read one title losslessly (chapters, audio tracks and subtitles are kept)
ExtractTitle() {
    local Src=$1 Ix=$2 Dst=$3 Meta="$WorkDir/chapters_$2.txt"
    "$PyBin" "$HelperFile" chapters "$WorkDir/titles.json" "$Ix" "$Meta"
    if [[ $HaveDvdvideo == true ]]; then
        ffmpeg -nostdin -hide_banner -v error -stats -y -f dvdvideo -title "$Ix" -i "$Src" \
            -f ffmetadata -i "$Meta" -map 0:v:0 -map '0:a?' -map '0:s?' -map_chapters 1 -c copy "$Dst"
    elif HasCmd mpv; then
        mpv --no-config --really-quiet --no-input-terminal --dvd-device="$Src" "dvd://$Ix" --stream-dump="$WorkDir/raw_$Ix.vob" </dev/null
        ffmpeg -nostdin -hide_banner -v error -stats -y -fflags +genpts -probesize 200M -analyzeduration 200M \
            -i "$WorkDir/raw_$Ix.vob" -f ffmetadata -i "$Meta" -map 0:v:0 -map '0:a?' -map '0:s?' \
            -map_chapters 1 -c copy "$Dst"
        rm -f "$WorkDir/raw_$Ix.vob"
    else
        Fail "Cannot read the titles: ffmpeg 7.1+ with libdvdnav or mpv is needed."
        return 1
    fi
}

# WriteJob <source> <job file> [plain]  -> settings of the current title as JSON for VapourSynth.
# "plain" switches every cleaning filter off (used for the "before" preview).
WriteJob() {
    local Src=$1 Dst=$2 Plain=${3:-} Strength=0 Chroma=0 Spot=0 Matrix="470bg" Amount=0 Rain=$Rainbow
    local Model="" Interp=0
    case $Denoise in light) Strength=70 ;; normal) Strength=130 ;; strong) Strength=220 ;; esac
    [[ $Denoise != off ]] && (( DenoiseValue > 0 )) && Strength=$DenoiseValue
    Chroma=$(( Strength * ChromaPercent / 100 ))
    [[ $Spots == on ]] && Spot=$SpotsValue
    [[ $Sharpen != off ]] && Amount=$Sharpen
    (( SrcHeight != 576 )) && Matrix="170m"
    if [[ $Plain == plain ]]; then Strength=0; Chroma=0; Spot=0; Amount=0; Rain="off"; fi
    if [[ $AiTools == true && $Plain != plain ]]; then
        [[ -f $AiModel ]] && Model=$AiModel
        Interp=$AiInterpolate
    fi
    cat > "$Dst" <<JOBEOF
{"src": "$Src", "tff": $Tff, "field_mode": "$FieldMode", "double_rate": $DoubleRate,
 "crop": [$CropLeft, $CropRight, $CropTop, $CropBottom], "spots": $Spot, "denoise": $Strength,
 "denoise_chroma": $Chroma, "rainbow": "$Rain", "dar": $Dar,
 "ai_model": "$Model", "ai_provider": "$AiProvider", "ai_tile": $AiTile, "ai_interpolate": $Interp,
 "upscale": $Upscale, "resizer": "$Resizer", "sharpen": $Amount, "matrix": "$Matrix",
 "out": [$OutWidth, $OutHeight]}
JOBEOF
}

# OutputFps  -> frame rate of the restored video (for frame number calculations)
OutputFps() {
    local Rate=$Fps
    [[ $FieldMode == bob && $DoubleRate == true ]] && Rate=$(awk -v F="$Fps" 'BEGIN { print F * 2 }')
    [[ $AiTools == true && $AiInterpolate != 0 ]] && Rate=$(awk -v F="$Rate" -v I="$AiInterpolate" 'BEGIN { print F * I }')
    echo "$Rate"
}

# Run the AI audio tool on every mono or stereo track. Fills AiAudioFiles (track number -> file).
AiAudioProcess() {
    local Src=$1 K Channels In OutDir Result
    AiAudioFiles=()
    for (( K = 0; K < AudioCount; K++ )); do
        Channels=$(ffprobe -v error -select_streams "a:$K" -show_entries stream=channels -of csv=p=0 "$Src")
        if (( ${Channels:-2} > 2 )); then
            Warn "Audio track $(( K + 1 )): surround is left untouched (the AI tools handle mono and stereo)."
            continue
        fi
        In="$WorkDir/ai_in_$K.wav"; OutDir="$WorkDir/ai_out_$K"
        mkdir -p "$OutDir"
        Info "Audio track $(( K + 1 )): AI processing ($AiAudio), this can take long..."
        ffmpeg -nostdin -v error -y -i "$Src" -map "0:a:$K" -ar 48000 -c:a pcm_s16le "$In" || continue
        case $AiAudio in
            denoise)  "$AudioAiEnv/bin/deepFilter" "$In" -o "$OutDir" >/dev/null 2>&1 ;;
            superres) "$AudioAiEnv/bin/python3" -m audiosr -i "$In" -s "$OutDir" --device auto >/dev/null 2>&1 ;;
        esac
        Result=$(find "$OutDir" -name '*.wav' -type f | head -1)
        if [[ -n $Result ]]; then AiAudioFiles[K]=$Result; else Warn "Audio track $(( K + 1 )): AI processing failed, the original is kept."; fi
    done
}

EncodeEpisode() {
    local Ix=$1 Src=$2 Final=$3 Vpy="$WorkDir/T$1.vpy" Job="$WorkDir/T$1.json"
    local VideoArgs=() FilterArgs=() OffsetArgs=() RangeArgs=() ColorArgs=() MapArgs=() ExtraArgs=()
    local AudioMaps=() AudioCodecs=() AiInputs=() J=0 InIdx=2 Chains=()
    local K Start End Rate Order Tz
    local RumbleFilter="" Enhance=""
    WriteJob "$Src" "$Job"
    "$PyBin" "$HelperFile" vpy "$Job" "$Vpy"

    case $Codec in
        x265) VideoArgs=(-c:v libx265 -preset "$Preset" -crf "$Crf" -pix_fmt yuv420p10le
                         -x265-params "aq-mode=3:deblock=-1,-1" -tag:v hvc1) ;;
        x264) VideoArgs=(-c:v libx264 -preset "$Preset" -crf "$Crf" -tune animation -pix_fmt yuv420p10le) ;;
    esac
    if [[ $Upscale == true ]]; then
        ColorArgs=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
        FilterArgs=(-vf "setsar=1")
    else
        if (( SrcHeight == 576 )); then
            ColorArgs=(-colorspace bt470bg -color_primaries bt470bg -color_trc gamma28)
        else
            ColorArgs=(-colorspace smpte170m -color_primaries smpte170m -color_trc smpte170m)
        fi
        FilterArgs=(-vf "setsar=$SarSrc")
    fi
    [[ $ColorTags == off ]] && ColorArgs=()
    (( RumbleHz > 0 )) && RumbleFilter="highpass=f=$RumbleHz,"
    [[ $AudioMode == copy ]] && ActiveEnhance="off" || ActiveEnhance=$AudioEnhance
    case $ActiveEnhance in
        light)  Enhance="aexciter=amount=1:drive=4:freq=6000:ceil=12000," ;;
        medium) Enhance="aexciter=amount=2:drive=6:freq=5000:ceil=14000,crystalizer=i=1.5," ;;
    esac
    AiAudioFiles=(); AiInputs=()
    if [[ $TestClip != true ]] && (( AudioCount > 0 )); then
        if [[ $AiTools == true && $AiAudio != off ]]; then AiAudioProcess "$Src"; fi
        if [[ $AudioMode == auto ]]; then
            Info "Title $Ix: analysing the audio tracks..."
            mapfile -t Chains < <("$PyBin" "$HelperFile" audio "$Src" --rumble "$RumbleHz" \
                --nr-medium "$NoiseMedium" --nr-strong "$NoiseStrong")
        fi
        for (( K = 0; K < AudioCount; K++ )); do
            if [[ -n ${AiAudioFiles[$K]:-} ]]; then
                AiInputs+=(-i "${AiAudioFiles[$K]}")
                AudioMaps+=(-map "$InIdx:a:0")
                InIdx=$(( InIdx + 1 ))
                AudioCodecs+=("-c:a:$J" flac "-compression_level:a:$J" 8 "-sample_fmt:a:$J" s32)
                [[ -n $Enhance ]] && AudioCodecs+=("-filter:a:$J" "${Enhance%,}")
            else
                AudioMaps+=(-map "1:a:$K")
                case $AudioMode in
                    copy)     AudioCodecs+=("-c:a:$J" copy) ;;
                    clean)    AudioCodecs+=("-c:a:$J" flac "-compression_level:a:$J" 8 "-sample_fmt:a:$J" s32
                                            "-filter:a:$J" "$Enhance${RumbleFilter}afftdn=nr=6:nf=-45") ;;
                    auto)
                        if [[ ${Chains[$K]:-COPY} == COPY && -z $Enhance ]]; then
                            AudioCodecs+=("-c:a:$J" copy)
                        elif [[ ${Chains[$K]:-COPY} == COPY ]]; then
                            AudioCodecs+=("-c:a:$J" flac "-compression_level:a:$J" 8 "-sample_fmt:a:$J" s32 "-filter:a:$J" "${Enhance%,}")
                        else
                            AudioCodecs+=("-c:a:$J" flac "-compression_level:a:$J" 8 "-sample_fmt:a:$J" s32 "-filter:a:$J" "$Enhance${Chains[$K]}")
                        fi ;;
                esac
            fi
            J=$(( J + 1 ))
        done
    fi
    [[ $VideoOffset != "0.0000" ]] && OffsetArgs=(-itsoffset "$VideoOffset")
    if [[ $Container == mp4 ]]; then
        MapArgs=("${AudioMaps[@]}" -sn -map_chapters 1 "${AudioCodecs[@]}")
        ExtraArgs=(-movflags +faststart -strict -2)
    else
        MapArgs=("${AudioMaps[@]}" -map '1:s?' -map_chapters 1 "${AudioCodecs[@]}" -c:s copy)
    fi
    if [[ $TestClip == true ]]; then
        Rate=$(OutputFps)
        Start=$(awk -v D="$Duration" -v P="$TestStartPercent" -v R="$Rate" 'BEGIN { printf "%d", D * P / 100 * R }')
        End=$(awk -v D="$Duration" -v S="$Start" -v R="$Rate" -v L="$TestSeconds" 'BEGIN { if (L > D * 0.4) L = D * 0.4; printf "%d", S + L * R - 1 }')
        RangeArgs=(-s "$Start" -e "$End")
        MapArgs=(-an -sn -map_chapters -1)
    fi
    Order="BFF"; [[ $Tff == true ]] && Order="TFF"
    Tz="original size"; [[ $Upscale == true ]] && Tz="${OutWidth}x${OutHeight}"
    Info "Title $Ix: fields=$FieldMode ($Order), aspect=$Dar, crop L$CropLeft R$CropRight T$CropTop B$CropBottom, target $Tz"
    if ! "$VspipeBin" -c y4m "${RangeArgs[@]}" "$Vpy" - |
         ffmpeg -nostdin -hide_banner -v error -stats -y "${OffsetArgs[@]}" -f yuv4mpegpipe -i - -i "$Src" "${AiInputs[@]}" \
             -map 0:v:0 "${MapArgs[@]}" "${VideoArgs[@]}" "${FilterArgs[@]}" "${ColorArgs[@]}" "${ExtraArgs[@]}" "$Final"; then
        Fail "Encoding of title $Ix failed (see the VapourSynth message above, or use 'Check environment')."
        return 1
    fi
    if [[ $TestClip != true ]]; then
        local OutDur
        OutDur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$Final" 2>/dev/null)
        if awk -v A="$Duration" -v B="${OutDur:-0}" 'BEGIN { D = A - B; if (D < 0) D = -D; exit !(D > 1.5) }'; then
            Warn "Duration differs (source ${Duration}s, result ${OutDur}s). Please check a few spots."
        fi
    fi
    Info "Finished: $Final"
}

# Probe (and extract) every selected title. Probing is repeated when a setting that
# influences it has changed.
PrepareTitles() {
    local Src=$1 Ix Mkv Key CropFlag=()
    Key="$Deint|$KeepBorders|$Height"
    [[ $KeepBorders == true ]] && CropFlag=(--no-crop)
    for Ix in "${SelectedTitles[@]}"; do
        Mkv="$WorkDir/T$Ix.src.mkv"
        if [[ ! -s $Mkv ]]; then
            Info "Title $Ix: reading from the disc (lossless)..."
            ExtractTitle "$Src" "$Ix" "$Mkv" || return 1
        fi
        if [[ $Key != "$ProbeKey" || ! -s $WorkDir/T$Ix.meta ]]; then
            Info "Title $Ix: analysing fields, borders and aspect ratio (about a minute)..."
            "$PyBin" "$HelperFile" probe "$Mkv" --json "$WorkDir/titles.json" --ix "$Ix" --deint "$Deint" \
                --height "$Height" "${CropFlag[@]}" > "$WorkDir/T$Ix.meta" || { Fail "Analysis failed."; return 1; }
        fi
    done
    ProbeKey=$Key
}

# Render one frame of a job with vspipe + ffmpeg: RenderFrame <job> <frame> <png>
RenderFrame() {
    local Vpy="${1%.json}.vpy"
    "$PyBin" "$HelperFile" vpy "$1" "$Vpy"
    "$VspipeBin" -s "$2" -e "$2" -c y4m "$Vpy" - 2>/dev/null |
        ffmpeg -nostdin -v error -y -f yuv4mpegpipe -i - -frames:v 1 "$3"
}

# Preview frames of every selected title: one frame every PreviewInterval seconds,
# before (fields and scaling only) next to after (all filters)
MakePreview() {
    local Dest=$1 Dir="$1/Preview" Ix Rate Times T K N Base Count
    mkdir -p "$Dir"
    for Ix in "${SelectedTitles[@]}"; do
        # shellcheck disable=SC1090
        source "$WorkDir/T$Ix.meta"
        Rate=$(OutputFps)
        Times=()
        if awk -v D="$Duration" -v I="$PreviewInterval" 'BEGIN { exit !(D > I * 3) }'; then
            for (( K = 0; K < PreviewMax; K++ )); do
                T=$(( K * PreviewInterval + 10 ))
                awk -v D="$Duration" -v T="$T" 'BEGIN { exit !(T < D - 2) }' || break
                Times+=("$T")
            done
        else
            for K in 25 50 75; do Times+=("$(awk -v D="$Duration" -v P="$K" 'BEGIN { printf "%d", D * P / 100 }')"); done
        fi
        WriteJob "$WorkDir/T$Ix.src.mkv" "$WorkDir/P${Ix}_before.json" plain
        WriteJob "$WorkDir/T$Ix.src.mkv" "$WorkDir/P${Ix}_after.json"
        Count=0
        for T in "${Times[@]}"; do
            N=$(awk -v T="$T" -v R="$Rate" 'BEGIN { printf "%d", T * R }')
            Base="$Dir/Title$(printf '%02d' "$Ix")_$(printf '%05d' "$T")s"
            RenderFrame "$WorkDir/P${Ix}_before.json" "$N" "$Base.before.png"
            RenderFrame "$WorkDir/P${Ix}_after.json" "$N" "$Base.after.png"
            if [[ -s $Base.before.png && -s $Base.after.png ]]; then
                ffmpeg -nostdin -v error -y -i "$Base.before.png" -i "$Base.after.png" \
                    -filter_complex "[0]scale=960:-2[a];[1]scale=960:-2[b];[a][b]hstack" "${Base}_compare.png"
                rm -f "$Base.before.png" "$Base.after.png"
                Count=$(( Count + 1 ))
            fi
        done
        Info "Title $Ix: $Count preview frame(s) (left: before, right: after)"
    done
    OpenFolder "$Dir"
    Pause
}

ProcessDisc() {
    local Src=$1 Name Dest Ix Final I Suffix Choice
    Name=$(SafeName "$Src")
    Dest="$OutputDir/$Name"
    WorkDir="$Dest/.work"
    mkdir -p "$WorkDir"
    [[ $KeepTemp == true ]] || Defer "rm -rf '$WorkDir'"

    Info "Disc: $Name"
    if ! ScanDisc "$Src"; then
        Fail "No titles found on this disc."; Pause; return 1
    fi
    InitialFlags=("${TitleSelList[@]}")
    Checklist "Select the titles to process: $Name\n${Dim}  Preselected: everything except play-all titles${Reset}" \
        "${TitleLabelList[@]}" || return 1
    SelectedTitles=()
    for I in "${!TitleIxList[@]}"; do
        (( CheckedFlags[I] )) && SelectedTitles+=("${TitleIxList[$I]}")
    done
    (( ${#SelectedTitles[@]} )) || { Warn "Nothing selected."; Pause; return 1; }

    ProbeKey=""
    mkdir -p "$Dest"
    Suffix=""; [[ $TestClip == true ]] && Suffix="_TEST"
    while true; do
        PrepareTitles "$Src" || { Pause; return 1; }
        MenuStart=0
        Menu "Disc: $Name  (${#SelectedTitles[@]} title(s) ready)\n\n$(SettingsSummary)" \
            "Encode now" \
            "Preview frames (one frame every ${PreviewInterval}s, before and after)" \
            "Change settings" \
            "Skip this disc" || return 0
        case $MenuChoice in
            0) break ;;
            1) MakePreview "$Dest" ;;
            2) CustomizeSettings && SaveSettings ;;
            3) return 0 ;;
        esac
    done
    Header
    for Ix in "${SelectedTitles[@]}"; do
        # shellcheck disable=SC1090
        source "$WorkDir/T$Ix.meta"
        Final="$Dest/${Name}_Title$(printf '%02d' "$Ix")$Suffix.$Container"
        if [[ -s $Final && $Overwrite != true ]]; then
            Info "Title $Ix: result already exists, skipped."; continue
        fi
        EncodeEpisode "$Ix" "$WorkDir/T$Ix.src.mkv" "$Final" || { Pause; return 1; }
    done
    [[ $KeepTemp == true ]] || rm -rf "$WorkDir"
}

RunRestore() {
    local Found Last I Names=() Chosen=() Source

    EnvScope=restore
    EnsureEnv restore || { Fail "Required parts are still missing. Use 'Check environment' for details."; Pause; return 1; }
    HaveDvdvideo=false
    HasDvdvideoDemuxer && HaveDvdvideo=true

    Header
    printf 'Path to the DVD: a folder containing VIDEO_TS, an ISO file, or a folder with several discs.\n'
    printf '%sTab completes paths.%s\n\n' "$Dim" "$Reset"
    Last=$(GetConfig LastInput)
    AskText "Path:" "$Last"
    InputPath=${Answer//\'/}
    InputPath=${InputPath%\"}; InputPath=${InputPath#\"}; InputPath=${InputPath/#\~/$HOME}
    [[ -n $InputPath ]] || return 1
    mapfile -t Found < <(DiscoverDiscs "$InputPath")
    if (( ${#Found[@]} == 0 )); then
        Fail "No DVD (VIDEO_TS folder or ISO) found in: $InputPath"; Pause; return 1
    fi
    SetConfig LastInput "$InputPath"

    DiscPaths=("${Found[@]}")
    if (( ${#Found[@]} > 1 )); then
        for I in "${!Found[@]}"; do Names+=("$(SafeName "${Found[$I]}")"); done
        Checklist "Several discs found. Select the ones to process" "${Names[@]}" || return 1
        for I in "${!Found[@]}"; do (( CheckedFlags[I] )) && Chosen+=("${Found[$I]}"); done
        (( ${#Chosen[@]} )) || { Warn "Nothing selected."; Pause; return 1; }
        DiscPaths=("${Chosen[@]}")
    fi

    Header
    printf 'Where should the restored episodes go?\n\n'
    Last=$(GetConfig OutputDir)
    AskText "Output folder:" "${Last:-$HOME/Videos/Restored}"
    OutputDir=${Answer/#\~/$HOME}
    [[ -n $OutputDir ]] || return 1
    SetConfig OutputDir "$OutputDir"

    MenuStart=0
    local Items=("Use these settings" "Recommended defaults" "Customize" "Advanced settings"
                 "AI tools: $([[ $AiTools == true ]] && echo on || echo off)  (switch)")
    [[ $AiTools == true ]] && Items+=("AI options")
    Menu "Settings\n\n$(SettingsSummary)" "${Items[@]}" || return 1
    case $MenuChoice in
        1) SetDefaultSettings ;;
        2) CustomizeSettings || return 1 ;;
        3) AdvancedSettings ;;
        4) ToggleAi ;;
        5) CustomizeAi ;;
    esac
    SaveSettings

    Menu "Ready to restore ${#DiscPaths[@]} disc(s)\n\n$(SettingsSummary)\n\n  Output: $OutputDir" \
        "Continue (you can preview before encoding)" \
        "Continue with short test clips only (${TestSeconds}s per episode, no audio)" || return 1
    TestClip=false
    (( MenuChoice == 1 )) && TestClip=true

    mkdir -p "$OutputDir"
    Header
    for Source in "${DiscPaths[@]}"; do ProcessDisc "$Source"; done
    Info "All done. Results are in: $OutputDir"
    Pause
}

ToggleAi() {
    if [[ $AiTools == true ]]; then AiTools=false; else AiTools=true; fi
    SaveSettings
}

EditSettings() {
    local Items Pos=0
    while true; do
        Items=("Customize" "Advanced settings" "AI tools: $([[ $AiTools == true ]] && echo on || echo off)  (switch)")
        [[ $AiTools == true ]] && Items+=("AI options")
        Items+=("Reset everything to the recommended defaults")
        MenuStart=$Pos
        Menu "Saved settings\n\n$(SettingsSummary)" "${Items[@]}" || return 0
        Pos=$MenuChoice
        case ${Items[$MenuChoice]} in
            Customize) CustomizeSettings && SaveSettings ;;
            Advanced*) AdvancedSettings ;;
            "AI tools"*) ToggleAi ;;
            "AI options") CustomizeAi && SaveSettings ;;
            Reset*) SetDefaultSettings; SaveSettings; Info "Defaults restored."; Pause ;;
        esac
    done
}

# ------------------------------------------------------------
# Embedded helper (analysis, planning, VapourSynth script generator)
# ------------------------------------------------------------

WriteHelper() {
    cat > "$HelperFile" <<'ARHELPEREOF'
#!/usr/bin/env python3
# Helper for Archive&Restore: analysis, planning and the VapourSynth script generator
import sys, re, json, shlex, subprocess, argparse
import xml.etree.ElementTree as ET


def Run(Cmd):
    # stdin is closed so ffmpeg never swallows keystrokes that belong to the menus
    return subprocess.run(Cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def Out(Key, Value):
    print(f"{Key}={shlex.quote(str(Value))}")


def Frac(Text, Default=None):
    try:
        if Text in (None, "", "N/A", "0:1", "0/0"):
            return Default
        A, B = re.split(r"[:/]", Text)
        A, B = float(A), float(B)
        return A / B if B else Default
    except Exception:
        return Default


# ------------------------------------------------------------ Titles
def ChannelName(Count):
    return {"1": "mono", "2": "stereo", "6": "5.1"}.get(str(Count), f"{Count}ch")


def CmdTitles(Args):
    Raw = open(Args.xml, encoding="utf-8", errors="replace").read()
    Start = Raw.find("<?xml")
    End = Raw.rfind("</lsdvd>")
    if Start < 0 or End < 0:
        sys.exit("lsdvd returned no XML (disc not readable?)")
    # lsdvd writes raw ampersands (for example "P&S")
    Xml = re.sub(r"&(?!amp;|lt;|gt;|quot;|apos;|#)", "&amp;", Raw[Start:End + 8])
    Root = ET.fromstring(Xml)
    Titles = []
    for T in Root.findall("track"):
        G = lambda Name, Default="": (T.findtext(Name) or Default).strip()
        Titles.append(dict(
            ix=int(G("ix", "0")), length=float(G("length", "0") or 0),
            vts=int(G("vts", "0") or 0), fps=float(G("fps", "25") or 25),
            format=G("format"), aspect=G("aspect"),
            width=int(G("width", "0") or 0), height=int(G("height", "0") or 0),
            chapters=[float(C.findtext("length") or 0) for C in T.findall("chapter")],
            audio=[dict(lang=X.findtext("langcode") or "", fmt=X.findtext("format") or "",
                        ch=X.findtext("channels") or "") for X in T.findall("audio")],
            subp=[dict(lang=X.findtext("langcode") or "") for X in T.findall("subp")]))
    Cand = [T for T in Titles if T["length"] >= 1]
    Seen, Uniq = set(), []
    for T in Cand:                      # drop exact duplicates (same VTS, length and chapter count)
        Key = (T["vts"], round(T["length"], 1), len(T["chapters"]))
        if Key in Seen:
            continue
        Seen.add(Key)
        Uniq.append(T)
    Cand = Uniq
    PlayAll = set()
    for T in Cand:                      # a play-all title equals the sum of consecutive other titles
        Others = [O for O in Cand if O is not T]
        for S in range(len(Others)):
            Total = 0
            for E in range(S, len(Others)):
                Total += Others[E]["length"]
                if E > S and abs(Total - T["length"]) <= 0.03 * T["length"]:
                    PlayAll.add(T["ix"])
    Selected = [T["ix"] for T in Cand if T["ix"] not in PlayAll]
    json.dump(dict(titles=Titles, selected=Selected, playall=sorted(PlayAll)), open(Args.out, "w"))
    for T in Titles:
        Mark = " (play-all)" if T["ix"] in PlayAll else ""
        Minutes, Seconds = divmod(int(T["length"]), 60)
        Audio = ",".join(f"{X['lang'] or '??'}/{X['fmt']}/{ChannelName(X['ch'])}" for X in T["audio"]) or "-"
        Subs = ",".join(X["lang"] or "??" for X in T["subp"]) or "-"
        Label = (f"Title {T['ix']:>2}  {Minutes:>3}:{Seconds:02d}  {T['format']:>4} {T['aspect']:>4} "
                 f"{T['width']}x{T['height']}  {len(T['chapters']):>2} ch  audio {Audio}  subs {Subs}{Mark}")
        print(f"{T['ix']}\t{1 if T['ix'] in Selected else 0}\t{Label}")


def CmdChapters(Args):
    Data = json.load(open(Args.json))
    T = next(X for X in Data["titles"] if X["ix"] == Args.ix)
    Lines, Pos = [";FFMETADATA1"], 0.0
    for N, Length in enumerate(T["chapters"], 1):
        Lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(Pos * 1000)}",
                  f"END={int((Pos + Length) * 1000)}", f"title=Chapter {N}"]
        Pos += Length
    open(Args.out, "w").write("\n".join(Lines) + "\n")


# ------------------------------------------------------------ Video analysis
FieldLabels = ["A", "B", "C", "D", "E"]


def Comb(Plane, Threshold=10):
    import numpy as np
    Y = Plane.astype(np.int16)
    D1 = Y[1:-1] - Y[:-2]
    D2 = Y[1:-1] - Y[2:]
    return float(((D1 * D2 > 0) & (np.minimum(abs(D1), abs(D2)) > Threshold)).mean())


def FieldStats(Video, Width, Height, Duration, Fps, Samples=6, NumFrames=150):
    import numpy as np
    Counts = {K: 0 for K in FieldLabels}
    Informative = Matchable = Total = 0
    Span = max(Duration - NumFrames / Fps - 5, 1)
    for S in range(Samples):
        Seek = min(3 + Span * (S + .5) / Samples, max(Duration - 2, 0))
        Raw = Run(["ffmpeg", "-v", "error", "-ss", f"{Seek:.2f}", "-i", Video, "-an", "-sn",
                   "-frames:v", str(NumFrames), "-vf", "format=gray", "-f", "rawvideo", "-"]).stdout
        N = len(Raw) // (Width * Height)
        if N < 3:
            continue
        F = np.frombuffer(Raw[:N * Width * Height], np.uint8).reshape(N, Height, Width)
        for I in range(1, N - 1):
            Total += 1
            Cur = F[I]
            B = Cur.copy(); B[1::2] = F[I - 1][1::2]    # top(i) + bottom(i-1)
            C = Cur.copy(); C[0::2] = F[I + 1][0::2]    # top(i+1) + bottom(i)
            D = Cur.copy(); D[0::2] = F[I - 1][0::2]    # top(i-1) + bottom(i)
            E = Cur.copy(); E[1::2] = F[I + 1][1::2]    # top(i) + bottom(i+1)
            Scores = [Comb(X) for X in (Cur, B, C, D, E)]
            High = max(Scores)
            if High < 0.004:
                continue
            Informative += 1
            Low = min(Scores)
            if Low < 0.3 * High:
                Matchable += 1
                Counts[FieldLabels[Scores.index(Low)]] += 1
    Result = dict(total=Total, informative=Informative, matchable=Matchable, counts=Counts)
    if Informative:
        Result["frac_match"] = Matchable / Informative
    if Matchable:
        Result["frac_A"] = Counts["A"] / Matchable
        Result["shift_tff"] = (Counts["B"] + Counts["C"]) / Matchable
        Result["shift_bff"] = (Counts["D"] + Counts["E"]) / Matchable
    return Result


def Idet(Video, Duration):
    Tff = Bff = Prog = 0
    for K in (0.2, 0.5, 0.8):
        Err = Run(["ffmpeg", "-hide_banner", "-ss", f"{Duration * K:.1f}", "-i", Video, "-an", "-sn",
                   "-frames:v", "300", "-vf", "idet", "-f", "null", "-"]).stderr.decode(errors="replace")
        M = re.findall(r"Multi frame detection: TFF:\s*(\d+) BFF:\s*(\d+) Progressive:\s*(\d+)", Err)
        if M:
            T, B, P = map(int, M[-1])
            Tff += T; Bff += B; Prog += P
    return Tff, Bff, Prog


def AutoCrop(Video, Width, Height, Duration):
    L = T = R = B = None
    Ok = 0
    for K in range(8):
        Seek = Duration * (K + 1) / 9
        Err = Run(["ffmpeg", "-hide_banner", "-ss", f"{Seek:.1f}", "-i", Video, "-an", "-sn", "-frames:v", "40",
                   "-vf", "cropdetect=limit=24:round=2:reset=0", "-f", "null", "-"]).stderr.decode(errors="replace")
        M = re.findall(r"crop=(\d+):(\d+):(\d+):(\d+)", Err)
        if not M:
            continue
        Cw, Ch, X, Y = map(int, M[-1])
        Ok += 1
        Vals = (X, Y, Width - Cw - X, Height - Ch - Y)
        Cur = (L, T, R, B)
        L, T, R, B = [V if C is None else min(C, V) for C, V in zip(Cur, Vals)]   # keep the smallest crop
    if Ok < 4:
        return (0, 0, 0, 0)
    L, T, R, B = [(max(V, 0) // 2) * 2 for V in (L, T, R, B)]
    if (L + R) > 0.2 * Width or (T + B) > 0.3 * Height:
        return (0, 0, 0, 0)             # implausible, ignore
    return (L, R, T, B)


StdRatios = [4 / 3, 16 / 9, 1.85, 2.0, 2.2, 2.35, 2.39, 2.40, 1.0]


def Snap(Ratio):
    for S in StdRatios:
        if abs(Ratio - S) / S < 0.015:
            return S
    return Ratio


def CmdProbe(Args):
    Info = json.loads(Run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", Args.video]).stdout)
    V = next(S for S in Info["streams"] if S["codec_type"] == "video")
    W, H = int(V["width"]), int(V["height"])
    Duration = float(Info["format"].get("duration") or 0)
    Fps = Frac(V.get("avg_frame_rate"), None) or Frac(V.get("r_frame_rate"), 25.0)
    DarSrc = Frac(V.get("display_aspect_ratio"), None)
    Sar = Frac(V.get("sample_aspect_ratio"), None)
    Aspect = ""
    if Args.json and Args.ix:
        try:
            T = next(X for X in json.load(open(Args.json))["titles"] if X["ix"] == Args.ix)
            Aspect = T["aspect"]
        except Exception:
            pass
    IfoDar = Frac(Aspect, None) if Aspect else None      # the aspect ratio from the disc has priority
    if IfoDar and 1.2 < IfoDar < 2.0:
        DarSrc = IfoDar
        Sar = DarSrc * H / W
    if Sar is None:
        Sar = (DarSrc * H / W) if DarSrc else 1.0
    if DarSrc is None:
        DarSrc = W * Sar / H
    FieldOrder = V.get("field_order", "unknown")
    VStart = float(V.get("start_time") or 0)
    FStart = float(Info["format"].get("start_time") or 0)
    NumAudio = sum(1 for S in Info["streams"] if S["codec_type"] == "audio")
    NumSub = sum(1 for S in Info["streams"] if S["codec_type"] == "subtitle")

    # Field structure
    Mode = Args.deint
    Tff = None
    Stats = {}
    if Mode == "auto":
        Stats = FieldStats(Args.video, W, H, Duration, Fps)
        Fm = Stats.get("frac_match", 0.0)
        Fa = Stats.get("frac_A", 0.0)
        if Stats["informative"] < 40:
            T_, B_, P_ = Idet(Args.video, Duration)
            Mode = "progressive" if P_ > 0.8 * max(T_ + B_ + P_, 1) else "match"
        elif Fm >= 0.9:
            if Fa >= 0.95:
                Mode = "progressive"
            else:
                Mode = "match"
        elif Fm >= 0.5:
            Mode = "match"
        else:
            Mode = "bob"
    # Field order
    if "shift_tff" in Stats and Stats.get("matchable", 0) and (Stats["shift_tff"] + Stats["shift_bff"]) > 0.3:
        Tff = Stats["shift_tff"] >= Stats["shift_bff"]
    if Tff is None and Mode != "progressive":
        T_, B_, P_ = Idet(Args.video, Duration)
        if T_ + B_ > 20:
            Tff = T_ >= B_
    if Tff is None:
        Tff = {"tt": True, "tb": True, "bb": False, "bt": False}.get(FieldOrder, True)

    # Crop, display aspect ratio and target size
    Crop = (0, 0, 0, 0) if Args.no_crop else AutoCrop(Args.video, W, H, Duration)
    L, R, T, B = Crop
    Cw, Ch = W - L - R, H - T - B
    Dar = Snap(Cw * Sar / Ch)
    OutHeight = Args.height
    OutWidth = round(OutHeight * Dar / 2) * 2
    Out("SrcWidth", W); Out("SrcHeight", H); Out("Duration", f"{Duration:.3f}"); Out("Fps", f"{Fps:.5f}")
    Out("SarSrc", f"{Sar:.6f}"); Out("DarSrc", f"{DarSrc:.5f}")
    Out("FieldMode", Mode); Out("Tff", "true" if Tff else "false")
    Out("CropLeft", L); Out("CropRight", R); Out("CropTop", T); Out("CropBottom", B)
    Out("Dar", f"{Dar:.5f}"); Out("OutWidth", OutWidth); Out("OutHeight", OutHeight)
    Out("VideoOffset", f"{VStart - FStart:.4f}"); Out("AudioCount", NumAudio); Out("SubCount", NumSub)


# ------------------------------------------------------------ Audio analysis
def DecodeAudio(Video, Index, Seek, Duration, Channels):
    import numpy as np
    Raw = Run(["ffmpeg", "-v", "error", "-ss", f"{Seek:.1f}", "-t", f"{Duration:.1f}", "-i", Video,
               "-map", f"0:a:{Index}", "-vn", "-sn", "-ac", str(Channels), "-ar", "48000", "-f", "f32le", "-"]).stdout
    N = len(Raw) // (4 * Channels)
    return np.frombuffer(Raw[:N * 4 * Channels], np.float32).reshape(N, Channels)


def EstimateKbps(Video, Index, Duration):
    Lines = Run(["ffprobe", "-v", "error", "-select_streams", f"a:{Index}", "-read_intervals", "%+60",
                 "-show_entries", "packet=size,pts_time", "-of", "csv=p=0", Video]).stdout.decode().split()
    Size = 0
    First = Last = None
    for Line in Lines:
        try:
            Pts, Bytes = Line.split(",")[:2]
            Pts = float(Pts)
            Bytes = int(Bytes)
        except Exception:
            continue
        Size += Bytes
        First = Pts if First is None else First
        Last = Pts
    if First is None or Last is None or Last - First < 5:
        return 0
    return int(Size * 8 / (Last - First) / 1000)


def Spectrum(Signal, Size):
    import numpy as np
    Count = len(Signal) // Size
    Frames = Signal[:Count * Size].reshape(Count, Size) * np.hanning(Size)
    Keep = np.sqrt((Frames ** 2).mean(axis=1)) > 1e-3
    if Keep.sum() < 3:
        Keep[:] = True
    Power = (np.abs(np.fft.rfft(Frames[Keep], axis=1)) ** 2).mean(axis=0)
    return 10 * np.log10(Power + 1e-20), np.fft.rfftfreq(Size, 1 / 48000)


def AnalyzeTrack(Video, Index, Channels, Total):
    import numpy as np
    Chn = 2 if Channels == 2 else 1
    Segments, SegLen = 6, 15.0
    Parts = []
    for S in range(Segments):
        Seek = max(0.0, (Total - SegLen) * (S + .5) / Segments) if Total > 2 * SegLen else 0.0
        Part = DecodeAudio(Video, Index, Seek, min(SegLen, Total), Chn)
        if len(Part):
            Parts.append(Part)
        if Total <= 2 * SegLen:
            break
    if not Parts:
        return None
    X = np.concatenate(Parts)
    Mono = X.mean(axis=1)
    Res = dict(active=False)
    if np.sqrt(np.mean(Mono ** 2)) < 3e-4:
        return Res
    Res["active"] = True
    Ls, F = Spectrum(Mono, 4096)
    Ls = np.convolve(Ls, np.ones(9) / 9, mode="same")
    Ref = float(np.median(Ls[(F >= 500) & (F <= 4000)]))
    Top = float(np.median(Ls[(F >= 21000) & (F <= 23500)]))
    Res["hf_snr"] = Ref - Top
    # Useful bandwidth: loud blocks against quiet blocks (hiss does not count as signal)
    N4 = 4096
    M4 = len(Mono) // N4
    Fr = Mono[:M4 * N4].reshape(M4, N4) * np.hanning(N4)
    R4 = np.sqrt((Fr ** 2).mean(axis=1))
    Ok = R4 > 1e-4
    if Ok.sum() >= 10:
        Lo, Hi = np.percentile(R4[Ok], 20), np.percentile(R4[Ok], 70)
        P = np.abs(np.fft.rfft(Fr, axis=1)) ** 2
        Pl = P[R4 >= Hi].mean(axis=0) + 1e-20
        Pq = P[Ok & (R4 <= Lo)].mean(axis=0) + 1e-20
        PlDb = np.convolve(10 * np.log10(Pl), np.ones(9) / 9, mode="same")
        RefLoud = np.median(PlDb[(F >= 500) & (F <= 4000)])
        Sig = (Pl > 4 * Pq) & (PlDb > RefLoud - 65)
        PqDb = 10 * np.log10(Pq)
        Res["hf_snr"] = float(RefLoud - np.median(PqDb[(F >= 500) & (F <= 4000)]))   # pause level against loud level
    else:
        Sig = Ls > max(Top + 8, Ref - 65)
    Run5 = np.convolve(Sig.astype(int), np.ones(5, int), mode="same") == 5
    Idx = np.where(Run5)[0]
    Res["bw"] = float(F[Idx[-1]]) if len(Idx) else 0.0
    # Noise floor from quiet 50 ms blocks
    N = 2400
    M = len(Mono) // N
    Rms = np.sqrt((Mono[:M * N].reshape(M, N) ** 2).mean(axis=1))
    Db = 20 * np.log10(Rms + 1e-9)
    Db = Db[Db > -90]
    Res["noise_db"] = float(np.percentile(Db, 10)) if len(Db) else -90.0
    # Mains hum
    Lh, Fh = Spectrum(Mono, 16384)
    Hum = []
    for F0 in (50.0, 60.0):
        Center = F0
        Peak = Lh[(Fh >= Center - 1.5) & (Fh <= Center + 1.5)].max()
        Base = np.median(np.concatenate([Lh[(Fh >= Center - 40) & (Fh <= Center - 10)],
                                         Lh[(Fh >= Center + 10) & (Fh <= Center + 40)]]))
        if Peak - Base >= 12:
            Hum.append((F0, Peak - Base))
    Res["hum"] = max(Hum, key=lambda T: T[1])[0] if Hum else 0.0
    # Clipping
    Hit = np.abs(Mono) >= 0.985
    Res["clip_pct"] = float((Hit[1:] & Hit[:-1]).mean() * 100)
    # Dual mono stored as stereo
    Res["dual_mono"] = False
    if Chn == 2:
        Diff = X[:, 0] - X[:, 1]
        Sum = X[:, 0] + X[:, 1]
        Ratio = np.sqrt((Diff ** 2).mean()) / (np.sqrt((Sum ** 2).mean()) + 1e-9)
        Res["dual_mono"] = bool(20 * np.log10(Ratio + 1e-9) < -40)
    return Res


def NoiseClass(NoiseDb, HfSnr):
    SevN = 3 if NoiseDb > -42 else 2 if NoiseDb > -50 else 1 if NoiseDb > -58 else 0
    SevH = 3 if HfSnr < 30 else 2 if HfSnr < 40 else 1 if HfSnr < 50 else 0
    return ["none", "light", "medium", "strong"][min(SevN, SevH)]      # both indicators must agree


def CmdAudio(Args):
    Info = json.loads(Run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", Args.video]).stdout)
    Total = float(Info["format"].get("duration") or 0)
    Tracks = [S for S in Info["streams"] if S["codec_type"] == "audio"]
    for K, S in enumerate(Tracks):
        Channels = int(S.get("channels", 2))
        Lang = (S.get("tags") or {}).get("language", "??")
        Kbps = EstimateKbps(Args.video, K, Total) or (int(S.get("bit_rate") or 0) // 1000)
        Head = (f"  Track {K + 1}: {Lang}, {S.get('codec_name')}, {ChannelName(Channels)}, "
                f"{Kbps or '?'} kbit/s, {int(S.get('sample_rate', 48000)) // 1000} kHz")
        R = AnalyzeTrack(Args.video, K, Channels, Total)
        if R is None or not R["active"]:
            print(Head + "\n    -> silent or not measurable: original is copied", file=sys.stderr)
            print("COPY")
            continue
        Bw = R["bw"]
        if Bw < 2000:                   # measurement unusable (test tone, almost only silence): do not risk anything
            print(Head + "\n    -> measurement not meaningful (hardly any signal): original is copied", file=sys.stderr)
            print("COPY")
            continue
        Noise = NoiseClass(R["noise_db"], R["hf_snr"])
        Quality = "good" if (Bw >= 17000 and Noise == "none") else \
                  ("medium" if (Bw >= 12000 and Noise in ("none", "light")) else "poor")
        Chain, Plan = [], []
        if R["dual_mono"]:
            Chain.append("pan=mono|c0=0.5*c0+0.5*c1")
            Plan.append("dual mono -> mono (same sound, half the size)")
        if R["clip_pct"] > 0.05:
            Chain.append("adeclip")
            Plan.append("repair clipping")
        if R["hum"]:
            for H in (1, 2, 3):
                Chain.append(f"bandreject=f={int(R['hum'] * H)}:width_type=q:w=25")
            Plan.append(f"remove {int(R['hum'])} Hz hum")
        if Args.rumble > 0:
            Chain.append(f"highpass=f={Args.rumble}")
            Plan.append(f"rumble filter {Args.rumble} Hz")
        Nr = {"none": 0, "light": 0, "medium": Args.nr_medium, "strong": Args.nr_strong}[Noise]   # "light" is left alone
        if Nr:
            Nf = int(max(-80, min(-25, R["noise_db"])))
            Chain.append(f"afftdn=nr={Nr}:nf={Nf}:tn=1")
            Plan.append(f"noise filter {Nr} dB")
        print(Head, file=sys.stderr)
        Hum = f"yes, {int(R['hum'])} Hz" if R["hum"] else "no"
        Note = " (left untouched)" if Noise == "light" else ""
        print(f"    measured: bandwidth {Bw / 1000:.1f} kHz | noise {Noise}{Note} ({R['noise_db']:.0f} dBFS) | "
              f"hum {Hum} | clipping {R['clip_pct']:.2f}% | quality: {Quality}", file=sys.stderr)
        if not Chain:
            print("    -> no problems found: the original is copied unchanged", file=sys.stderr)
            print("COPY")
            continue
        Plan.append("lossless FLAC 24 bit (sample rate kept)")
        print("    -> " + ", ".join(Plan), file=sys.stderr)
        print(",".join(Chain))


# ------------------------------------------------------------ VapourSynth script
VpyTemplate = r'''# generated by Archive&Restore
import vapoursynth as vs, json
core = vs.core
Cfg = json.loads(r"""__CFG__""")


def Load(Path):
    Errors = []
    for Source in (lambda: core.bs.VideoSource(Path), lambda: core.lsmas.LWLibavSource(Path),
                   lambda: core.ffms2.Source(Path)):
        try:
            return Source()
        except Exception as E:
            Errors.append(str(E))
    raise RuntimeError("No source filter (bs/lsmas/ffms2) worked: " + " | ".join(Errors))


def Need(Namespace, Hint):
    if not hasattr(core, Namespace):
        raise RuntimeError(f"VapourSynth plugin '{Namespace}' is missing: {Hint}")


def SetFieldBased(Clip, Value):
    return core.std.SetFrameProp(Clip, prop="_FieldBased", intval=Value)


def Qtgmc(Clip, Tff, Double=False):
    # New interface (vsjetpack/vsdeinterlace) with the old havsfunc.QTGMC as fallback
    try:
        from vsdeinterlace import QTempGaussMC
    except ImportError:
        QTempGaussMC = None
    if QTempGaussMC is not None:
        Q = QTempGaussMC()
        if not Double:
            Q = Q.motion_blur(fps_divisor=2)        # 25 instead of 50 frames per second
        return Q.deinterlace(Clip, tff=Tff)
    try:
        import havsfunc as Haf
        return Haf.QTGMC(Clip, Preset="Slower", TFF=Tff, FPSDivisor=1 if Double else 2)
    except Exception as E:
        raise RuntimeError("QTGMC is missing (pip: vsjetpack, vapoursynth-znedi3, vapoursynth-eedi3, "
                           "vapoursynth-zsmooth, vapoursynth-sangnom): " + str(E))


def OnnxLoad(Path, Provider):
    try:
        import onnxruntime as Ort
    except ImportError:
        raise RuntimeError("onnxruntime is missing (pip install onnxruntime, or onnxruntime-gpu for NVIDIA)")
    Available = Ort.get_available_providers()
    if Provider == "cuda":
        Order = ["CUDAExecutionProvider"]
    elif Provider == "rocm":
        Order = ["ROCMExecutionProvider"]
    elif Provider == "cpu":
        Order = []
    else:
        Order = [P for P in ("CUDAExecutionProvider", "ROCMExecutionProvider") if P in Available]
    Order = [P for P in Order if P in Available] + ["CPUExecutionProvider"]
    return Ort.InferenceSession(Path, providers=Order)


def OnnxRun(Session, Array, Tile):
    # Array has the shape 1 x 3 x H x W (float32, 0..1). Large frames are processed in padded tiles.
    import numpy as np
    Name = Session.get_inputs()[0].name
    H, W = Array.shape[2], Array.shape[3]
    if Tile <= 0 or (H <= Tile and W <= Tile):
        return np.clip(Session.run(None, {Name: Array})[0], 0, 1)
    Pad = 16
    Padded = np.pad(Array, ((0, 0), (0, 0), (Pad, Pad), (Pad, Pad)), mode="reflect")
    Out = None
    for Y in range(0, H, Tile):
        for X in range(0, W, Tile):
            Y1, X1 = min(Y + Tile, H), min(X + Tile, W)
            Piece = np.ascontiguousarray(Padded[:, :, Y:Y1 + 2 * Pad, X:X1 + 2 * Pad])
            Res = Session.run(None, {Name: Piece})[0]
            S = Res.shape[2] // Piece.shape[2]
            if Out is None:
                Out = np.zeros((1, 3, H * S, W * S), np.float32)
            Out[:, :, Y * S:Y1 * S, X * S:X1 * S] = Res[:, :, Pad * S:Res.shape[2] - Pad * S, Pad * S:Res.shape[3] - Pad * S]
    return np.clip(Out, 0, 1)


def OnnxScale(Session):
    import numpy as np
    Name = Session.get_inputs()[0].name
    Probe = Session.run(None, {Name: np.zeros((1, 3, 64, 64), np.float32)})[0]
    return Probe.shape[2] // 64


def OnnxApply(Rgb, Session, Scale, Tile):
    import numpy as np, threading
    Lock = threading.Lock()
    Dst = core.std.BlankClip(Rgb, width=Rgb.width * Scale, height=Rgb.height * Scale)

    def Process(n, f):      # VapourSynth passes these two arguments by keyword (n, f)
        Out = f[1].copy()
        Src = np.stack([np.asarray(f[0][P]) for P in range(3)])[None].astype(np.float32)
        with Lock:
            Res = OnnxRun(Session, Src, Tile)
        for P in range(3):
            np.copyto(np.asarray(Out[P]), Res[0, P])
        return Out
    return core.std.ModifyFrame(Dst, [Rgb, Dst], Process)


Clip = Load(Cfg["src"])
Tff, Mode = Cfg["tff"], Cfg["field_mode"]

# 0. Rainbows (cross color): must run right after the source, before any field handling
if Cfg.get("rainbow") == "decross":
    Need("decross", "pip install vapoursynth-decross")
    Clip = core.decross.DeCross(Clip)

# 1. Fields: only touch what is really interlaced or shifted
if Mode == "progressive":
    Clip = SetFieldBased(Clip, 0)
elif Mode == "match":
    Need("tivtc", "pip install vapoursynth-tivtc")
    Clip = SetFieldBased(Clip, 2 if Tff else 1)
    Fallback = None
    if Mode == "match":
        Fallback = Qtgmc(Clip, Tff)
    Kw = dict(order=1 if Tff else 0, mode=1, PP=6)
    if Fallback is not None:
        Kw["clip2"] = Fallback
    Clip = core.tivtc.TFM(Clip, **Kw)
    Clip = SetFieldBased(Clip, 0)
elif Mode == "bob":
    Clip = SetFieldBased(Clip, 2 if Tff else 1)
    Clip = Qtgmc(Clip, Tff, bool(Cfg.get("double_rate")))
    Clip = SetFieldBased(Clip, 0)

# 2. Crop (after deinterlacing, so no field problems)
Left, Right, Top, Bottom = Cfg["crop"]
if Left or Right or Top or Bottom:
    Clip = core.std.Crop(Clip, left=Left, right=Right, top=Top, bottom=Bottom)
Clip = core.resize.Point(Clip, format=vs.YUV420P16)


def MvSuper(Source, Pel=2):
    return core.mv.Super(Source, pel=Pel, sharp=2)


def Vectors(Super, Delta, BlockSize):
    Kw = dict(delta=Delta, blksize=BlockSize, overlap=BlockSize // 2, search=4, truemotion=True)
    return core.mv.Analyse(Super, isb=True, **Kw), core.mv.Analyse(Super, isb=False, **Kw)


# 3. Dropouts and short streaks: motion compensated temporal median
if Cfg["spots"] > 0:
    Need("mv", "pip install vapoursynth-mvtools")
    Super = MvSuper(Clip)
    Back, Forward = Vectors(Super, 1, 8)
    CompBack = core.mv.Compensate(Clip, Super, Back, thsad=Cfg["spots"])
    CompForward = core.mv.Compensate(Clip, Super, Forward, thsad=Cfg["spots"])
    Clip = core.std.Expr([CompBack, Clip, CompForward], "x y min x y max z min max")   # median of three

# 4. Grain and MPEG-2 noise: MDegrain2 with the analysis done on a slightly blurred copy
if Cfg["denoise"] > 0:
    Need("mv", "pip install vapoursynth-mvtools")
    Block = 8 if Clip.width <= 1000 else 16
    Pre = core.std.Convolution(Clip, [1, 2, 1, 2, 4, 2, 1, 2, 1])
    SuperAnalyse = MvSuper(Pre)
    SuperRender = core.mv.Super(Clip, pel=2, sharp=2, levels=1)
    Back1, Forward1 = Vectors(SuperAnalyse, 1, Block)
    Back2, Forward2 = Vectors(SuperAnalyse, 2, Block)
    Strength = Cfg["denoise"]
    Clip = core.mv.Degrain2(Clip, SuperRender, Back1, Forward1, Back2, Forward2,
                            thsad=Strength, thsadc=Cfg["denoise_chroma"], plane=4)

# 5. Upscale: classic kernel (one resize step, color matrix 601 -> 709) or an AI model (ONNX)
AiModel = Cfg.get("ai_model") or ""
if AiModel:
    Session = OnnxLoad(AiModel, Cfg.get("ai_provider", "auto"))
    Scale = OnnxScale(Session)
    Target = (Cfg["out"][0], Cfg["out"][1]) if Cfg["upscale"] else (Clip.width, Clip.height)
    Matrix = "709" if Cfg["upscale"] else Cfg["matrix"]
    if Scale > 1:
        # square pixels first (true aspect ratio), then the model, then down to the target size
        SqHeight = Clip.height
        SqWidth = int(round(SqHeight * Cfg.get("dar", Clip.width / Clip.height) / 2) * 2)
        Rgb = core.resize.Spline36(Clip, width=SqWidth, height=SqHeight, format=vs.RGBS,
                                   matrix_in_s=Cfg["matrix"], range_in_s="limited")
    else:
        Rgb = core.resize.Bicubic(Clip, format=vs.RGBS, matrix_in_s=Cfg["matrix"], range_in_s="limited")
    Rgb = OnnxApply(Rgb, Session, Scale, Cfg.get("ai_tile", 256))
    Clip = core.resize.Spline36(Rgb, width=Target[0], height=Target[1], format=vs.YUV420P16,
                                matrix_s=Matrix, range_s="limited", dither_type="error_diffusion")
    if Cfg["upscale"]:
        Clip = core.std.SetFrameProps(Clip, _Matrix=1, _Transfer=1, _Primaries=1)
elif Cfg["upscale"]:
    Kernels = {"spline36": core.resize.Spline36, "spline64": core.resize.Spline64,
               "lanczos": core.resize.Lanczos, "bicubic": core.resize.Bicubic,
               "nearest": core.resize.Point}
    Clip = Kernels[Cfg["resizer"]](Clip, width=Cfg["out"][0], height=Cfg["out"][1],
                                   matrix_in_s=Cfg["matrix"], matrix_s="709",
                                   range_in_s="limited", range_s="limited", dither_type="error_diffusion")
    Clip = core.std.SetFrameProps(Clip, _Matrix=1, _Transfer=1, _Primaries=1)

# 6. Optional light sharpening (unsharp mask, luma only)
if Cfg["sharpen"] > 0:
    Blur = core.std.Convolution(Clip, [1, 2, 1, 2, 4, 2, 1, 2, 1])
    Clip = core.std.Expr([Clip, Blur], ["x x y - %s * +" % Cfg["sharpen"], ""])

# 7. Optional AI frame interpolation (RIFE through the vsrife package, needs PyTorch)
if Cfg.get("ai_interpolate"):
    try:
        from vsrife import rife
    except ImportError:
        raise RuntimeError("vsrife is missing (pip install vsrife; it downloads PyTorch)")
    Matrix = "709" if Cfg["upscale"] else Cfg["matrix"]
    Rgb = core.resize.Bicubic(Clip, format=vs.RGBS, matrix_in_s=Matrix, range_in_s="limited")
    Rgb = rife(Rgb, model="4.25", factor_num=int(Cfg["ai_interpolate"]))
    Clip = core.resize.Bicubic(Rgb, format=vs.YUV420P16, matrix_s=Matrix, range_s="limited",
                               dither_type="error_diffusion")

Clip = core.resize.Point(Clip, format=vs.YUV420P10, dither_type="error_diffusion")
Clip.set_output()
'''


def CmdVpy(Args):
    Cfg = json.load(open(Args.cfg))
    open(Args.out, "w").write(VpyTemplate.replace("__CFG__", json.dumps(Cfg)))


if __name__ == "__main__":
    Parser = argparse.ArgumentParser()
    Sub = Parser.add_subparsers(dest="command", required=True)
    P = Sub.add_parser("titles"); P.add_argument("xml")
    P.add_argument("--out", required=True); P.set_defaults(func=CmdTitles)
    P = Sub.add_parser("chapters"); P.add_argument("json"); P.add_argument("ix", type=int); P.add_argument("out")
    P.set_defaults(func=CmdChapters)
    P = Sub.add_parser("probe"); P.add_argument("video"); P.add_argument("--json", default="")
    P.add_argument("--ix", type=int, default=0); P.add_argument("--deint", default="auto")
    P.add_argument("--no-crop", action="store_true"); P.add_argument("--height", type=int, default=1080)
    P.set_defaults(func=CmdProbe)
    P = Sub.add_parser("audio"); P.add_argument("video"); P.add_argument("--rumble", type=int, default=0)
    P.add_argument("--nr-medium", type=int, default=8); P.add_argument("--nr-strong", type=int, default=14)
    P.set_defaults(func=CmdAudio)
    P = Sub.add_parser("vpy"); P.add_argument("cfg"); P.add_argument("out"); P.set_defaults(func=CmdVpy)
    Parsed = Parser.parse_args()
    Parsed.func(Parsed)
ARHELPEREOF
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

Main() {
    ResolveDataDir
    TempRoot=$(mktemp -d /tmp/ArchiveAndRestore.XXXXXX)
    HelperFile="$TempRoot/helper.py"
    Defer "rm -rf '$TempRoot'"
    trap Cleanup EXIT
    trap 'exit 130' INT TERM
    WriteHelper
    SetDefaultSettings
    LoadSettings
    UseVenv
    while true; do
        MenuStart=0
        Menu "What do you want to do?" \
            "1. Archive   - copy a DVD to your disk (dvdbackup, optional ddrescue repair)" \
            "2. Restore   - restore archived DVDs (fields, noise, rainbow, upscale, audio)" \
            "Settings" \
            "Check environment / install missing parts" \
            "Quit" || exit 0
        case $MenuChoice in
            0) ArchiveMenu ;;
            1) RunRestore ;;
            2) EditSettings ;;
            3) ShowEnvironment ;;
            4) exit 0 ;;
        esac
    done
}

Main
