#!/usr/bin/env bash
# =============================================================================
#  sysdash — a server-statistics dashboard for your terminal
# =============================================================================
#  Modules
#    · system / user header           · hardware and resource panels
#    · CPU, RAM, storage, network     · top processes by *live* CPU, with type icons
#    · open ports                     · system uptime via tuptime
#    · internet uptime (collector)    · uninterrupted-power time (collector)
#    · inbound connections by service (website, SSH, game server, database …)
#    · installable service plugins (OS logo, Tailscale, aria2, Jellyfin, animated panels, and custom panels)
#
#  Usage
#    ./sysdash.sh                         one-shot dashboard
#    ./sysdash.sh watch [N]               live view, refresh every N seconds (default 5)
#    ./sysdash.sh live                    live view, data refresh every 0.5 s; animated plugins run up to 30 fps
#    ./sysdash.sh showcase [FLAGS]        privacy-safe dashboard for screenshots
#    ./sysdash.sh showcase FLAGS live     privacy-safe live dashboard
#    ./sysdash.sh showcase default        shorthand for: showcase sn osn g og pn opn oeip iip
#      FLAGS: un oun sn osn g og s os em oem pn opn eip oeip iip   (or: default)
#    ./sysdash.sh keys                    list the names of the keys you have stored (alias: kyes)
#    ./sysdash.sh keys list               same as above
#    ./sysdash.sh keys set KEY VALUE      store an API key for plugins
#    ./sysdash.sh keys get KEY            print a stored key's value
#    ./sysdash.sh keys unset KEY          remove a stored key
#    ./sysdash.sh no-install              never try to install missing packages
#    ./sysdash.sh no-daemon               don't start the background collector / cron job
#    ./sysdash.sh uninstall               stop collector, remove cron entries + history
#    ./sysdash.sh i URL                   install a trusted plugin from a raw URL
#    ./sysdash.sh list                    list installed plugins and toggle state
#    ./sysdash.sh rm NAME                 remove a plugin
#    ./sysdash.sh toggle NAME [on|off]    enable or disable a plugin
#    ./sysdash.sh reorder NAME up|down    change plugin order
#    ./sysdash.sh swap NAME NAME          swap plugin positions
#    ./sysdash.sh update NAME URL         update an installed plugin (shorthand: upd)
#    ./sysdash.sh help [COMMAND]          show general or command-specific help (try: help api)
#    Legacy --options remain supported.
#
#  Showcase allow-list: un=self username, oun=other usernames, sn=self system name,
#    osn=other system names, g=self groups, og=other groups, s=self session, os=other sessions; em/oem=email, pn/opn=phone, eip/oeip=external IP, iip=internal IPs.
#    All categories are hidden by default in showcase mode. "default" enables: sn osn g og pn opn oeip iip.
#
#  Plugin API
#    Metadata   SYSDASH_PLUGIN_ID="id"  SYSDASH_PLUGIN_NAME="Name"  SYSDASH_PLUGIN_SPAN="auto|half|full"
#    Renderer   sysdash_plugin_<id> WIDTH   prints the panel's content rows with box_line
#    Animation  (live mode only, up to 30 fps)
#      SYSDASH_PLUGIN_FPS="30"              requested frame rate, 1-30 (anything higher is capped at 30)
#      sysdash_plugin_<id>_frame W N MS     draws ONE frame: print content rows with box_line (no
#                                           box_top/box_bot). W = panel width, N = frame counter
#                                           (0 = static snapshot), MS = milliseconds since live start.
#                                           Keep the row count constant: the rows are redrawn in place.
#      If sysdash_plugin_<id> is not defined, the _frame function is called with N=0 for static views.
#      Frames run in a subshell once per frame, so keep them cheap (no network, few forks).
#      Outside live mode a plugin just shows its static snapshot. SYSDASH_LIVE=1 is set in live mode.
#
#  Env:  SYSDASH_ASCII=1 (ASCII only)   SYSDASH_EMOJI=1 (emoji icons)   NO_COLOR=1
#        SYSDASH_SHOWCASE and SYSDASH_SHOWCASE_{UN,OUN,SN,OSN,G,OG,S,OS,EM,OEM,PN,OPN,EIP,OEIP,IIP} are exported to plugins
#        SYSDASH_LIVE=1 is exported to plugins when running in live mode
#        SYSDASH_COLS / SYSDASH_ROWS override the detected window size
#        SYSDASH_ARIA2_RPC_URL / SYSDASH_ARIA2_SECRET / SYSDASH_ARIA2_CONFIG configure aria2
#        SYSDASH_JELLYFIN_URL / SYSDASH_JELLYFIN_API_KEY configure Jellyfin
#        Plugin span: auto (default), full, or half; adjacent auto/half panels pair.
#
#  Works on: Linux (apt/dnf/yum/pacman/zypper/apk), macOS (brew), BSD (best effort).
#  Needs bash 3.2+. Anything that can't be installed degrades gracefully.
# =============================================================================
shopt -s extglob 2>/dev/null
export LC_NUMERIC=C
SD_VERSION="1.4.0"
OS_KIND=$(uname -s 2>/dev/null || echo Linux)
ESC=$'\033'
SELF="${BASH_SOURCE[0]:-$0}"
case $SELF in /*) ;; *) SELF="$PWD/$SELF" ;; esac
SD_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/sysdash"
SD_COPY="$SD_DIR/sysdash.sh"
NET_LOG="$SD_DIR/net.log"
PWR_LOG="$SD_DIR/power.log"
PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/sysdash/plugins"
PLUGIN_ORDER="$SD_DIR/plugins.order"
HB_FILE="$SD_DIR/heartbeat"
PID_FILE="$SD_DIR/collector.pid"
TRIED_FILE="$SD_DIR/install.tried"
INSTALL_LOG="$SD_DIR/install.log"
KEYS_FILE="$SD_DIR/keys.env"
INTERVAL=20
GRACE=$((INTERVAL * 4))
OPT_INSTALL=1; OPT_DAEMON=1; OPT_WATCH=0; OPT_LIVE=0; OPT_SHOWCASE=0; WATCH_SECS=5
# Showcase allow-list: all identity fields remain hidden unless explicitly enabled.
OPT_SHOWCASE_UN=0; OPT_SHOWCASE_OUN=0; OPT_SHOWCASE_SN=0; OPT_SHOWCASE_OSN=0
OPT_SHOWCASE_G=0; OPT_SHOWCASE_OG=0; OPT_SHOWCASE_S=0; OPT_SHOWCASE_OS=0
OPT_SHOWCASE_EM=0; OPT_SHOWCASE_OEM=0; OPT_SHOWCASE_PN=0; OPT_SHOWCASE_OPN=0
OPT_SHOWCASE_EIP=0; OPT_SHOWCASE_OEIP=0; OPT_SHOWCASE_IIP=0
export SYSDASH_SHOWCASE=0
# ----------------------------------------------------------------------------
#  generic helpers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
now()  { date +%s; }
tmo() { # tmo SECONDS cmd...   (timeout if we have one)
local t=$1; shift
if have timeout; then timeout "$t" "$@"
elif have gtimeout; then gtimeout "$t" "$@"
else "$@"; fi
}
fmt_dur() {
local s=${1:-0} d h m
[ "$s" -lt 0 ] 2>/dev/null && s=0
d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
if   [ "$d" -gt 0 ]; then printf '%dd %dh %dm' "$d" "$h" "$m"
elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
elif [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" $((s % 60))
else printf '%ds' "$s"; fi
}
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null; }
hkb() { awk -v k="${1:-0}" 'BEGIN{ if(k>=1073741824) printf "%.1fT",k/1073741824; else if(k>=1048576) printf "%.1fG",k/1048576; else if(k>=1024) printf "%.0fM",k/1024; else printf "%dK",k }'; }
hbytes() { awk -v b="${1:-0}" 'BEGIN{ if(b>=1099511627776) printf "%.1fT",b/1099511627776; else if(b>=1073741824) printf "%.1fG",b/1073741824; else if(b>=1048576) printf "%.0fM",b/1048576; else printf "%.0fK",b/1024 }'; }
usage() { awk 'NR<2{next} { l=$0; sub(/^# ?/,"",l); print l; if ($0 ~ /^# ====/ && ++n==3) exit }' "$SELF"; }
showcase_text() { # Replace potentially identifying text in showcase mode.
if [ "${OPT_SHOWCASE:-0}" = 1 ]; then printf '%s' "${2:-[hidden]}"; else printf '%s' "$1"; fi
}
showcase_ip() { # IP address -> stable non-identifying placeholder in showcase mode.
if [ "${OPT_SHOWCASE:-0}" = 1 ]; then printf '[address hidden]'; else printf '%s' "$1"; fi
}
showcase_port() { # port -> non-identifying placeholder in showcase mode.
if [ "${OPT_SHOWCASE:-0}" = 1 ]; then printf '[hidden]'; else printf '%s' "$1"; fi
}
export_showcase_flags() {
export SYSDASH_SHOWCASE="$OPT_SHOWCASE"
export SYSDASH_SHOWCASE_UN="$OPT_SHOWCASE_UN" SYSDASH_SHOWCASE_OUN="$OPT_SHOWCASE_OUN"
export SYSDASH_SHOWCASE_SN="$OPT_SHOWCASE_SN" SYSDASH_SHOWCASE_OSN="$OPT_SHOWCASE_OSN"
export SYSDASH_SHOWCASE_G="$OPT_SHOWCASE_G" SYSDASH_SHOWCASE_OG="$OPT_SHOWCASE_OG"
export SYSDASH_SHOWCASE_S="$OPT_SHOWCASE_S" SYSDASH_SHOWCASE_OS="$OPT_SHOWCASE_OS"
export SYSDASH_SHOWCASE_EM="$OPT_SHOWCASE_EM" SYSDASH_SHOWCASE_OEM="$OPT_SHOWCASE_OEM"
export SYSDASH_SHOWCASE_PN="$OPT_SHOWCASE_PN" SYSDASH_SHOWCASE_OPN="$OPT_SHOWCASE_OPN"
export SYSDASH_SHOWCASE_EIP="$OPT_SHOWCASE_EIP" SYSDASH_SHOWCASE_OEIP="$OPT_SHOWCASE_OEIP"
export SYSDASH_SHOWCASE_IIP="$OPT_SHOWCASE_IIP"
}
# ----------------------------------------------------------------------------
#  keys manager (for plugins to use API keys securely)
# ----------------------------------------------------------------------------
keys_set() {
local key=$1 val=$2
if [ -z "$key" ]; then echo "Usage: keys set KEY VALUE" >&2; return 1; fi
mkdir -p "$SD_DIR"
touch "$KEYS_FILE"
chmod 600 "$KEYS_FILE"
if [ -f "$KEYS_FILE" ]; then
grep -v "^${key}=" "$KEYS_FILE" > "$KEYS_FILE.tmp" 2>/dev/null
mv "$KEYS_FILE.tmp" "$KEYS_FILE"
fi
printf '%s=%s\n' "$key" "$val" >> "$KEYS_FILE"
echo "Key '$key' set."
}
keys_get() {
local key=$1
[ -f "$KEYS_FILE" ] || return 1
# value is everything after the first '=' (API keys may contain '=')
awk -v k="$key" '{ i=index($0,"="); if (i>0 && substr($0,1,i-1)==k) { print substr($0,i+1); exit } }' "$KEYS_FILE"
}
keys_unset() {
local key=$1
[ -f "$KEYS_FILE" ] || return 0
grep -v "^${key}=" "$KEYS_FILE" > "$KEYS_FILE.tmp" 2>/dev/null
mv "$KEYS_FILE.tmp" "$KEYS_FILE"
echo "Key '$key' unset."
}
keys_list() { # one key name per line (values are never printed)
local out
[ -f "$KEYS_FILE" ] && out=$(awk -F= '/^[[:space:]]*#/ || NF==0 {next} {print $1}' "$KEYS_FILE")
if [ -z "$out" ]; then echo "No keys set." >&2; return 0; fi
printf '%s\n' "$out"
}
load_keys() {
[ -f "$KEYS_FILE" ] || return 0
while IFS= read -r line; do
[[ "$line" =~ ^[[:space:]]*# ]] && continue
[[ -z "$line" ]] && continue
export "$line"
done < "$KEYS_FILE"
}
# ----------------------------------------------------------------------------
#  style: unicode detection, colours, glyphs
# ----------------------------------------------------------------------------
detect_unicode() {
UNI=1
[ "${SYSDASH_ASCII:-0}" = 1 ] && { UNI=0; return; }
local loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
case $loc in
*UTF-8*|*utf8*|*UTF8*|*utf-8*) ;;
*) if have locale && locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then export LC_ALL=C.UTF-8
else UNI=0; fi ;;
esac
}
setup_style() {
detect_unicode
local nc; nc=$(tput colors 2>/dev/null || echo 0)
if [ -n "${NO_COLOR:-}" ]; then
RST=""; BOLD=""; DIM=""; ACC=""; ACC2=""; OK=""; WARN=""; BAD=""
elif [ "${nc:-0}" -ge 256 ] 2>/dev/null || [ -n "${COLORTERM:-}" ]; then
RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[38;5;245m'
ACC=$'\033[38;5;75m'; ACC2=$'\033[38;5;141m'
OK=$'\033[38;5;78m'; WARN=$'\033[38;5;221m'; BAD=$'\033[38;5;203m'
else
RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
ACC=$'\033[36m'; ACC2=$'\033[35m'; OK=$'\033[32m'; WARN=$'\033[33m'; BAD=$'\033[31m'
fi
if [ "$UNI" = 1 ]; then
H='─'; V='│'; TL='╭'; TR='╮'; BL='╰'; BR='╯'; LT='├'; RT='┤'
FILL='█'; EMPTY='░'; DOT='●'; ELL='…'; SEP='·'; DEG='°'; GE='≥'; AD='↓'; AU='↑'
else
H='-'; V='|'; TL='+'; TR='+'; BL='+'; BR='+'; LT='+'; RT='+'
FILL='#'; EMPTY='.'; DOT='*'; ELL='~'; SEP='-'; DEG=''; GE='>='; AD='v'; AU='^'
fi
}
set_width() { COLS=$1; IW=$((COLS - 4)); }
setup_term() {
local _r="" _c=""
if [ -n "${SD_LIVE_BG:-}" ]; then   # the live renderer has no tty on stdout: ask the terminal directly
read -r _r _c < <(stty size 2>/dev/null </dev/tty)
case $_r in ''|*[!0-9]*) _r="";; esac; case $_c in ''|*[!0-9]*) _c="";; esac
fi
TERM_COLS=${SYSDASH_COLS:-${_c:-$(tput cols 2>/dev/null || echo 100)}}
TERM_ROWS=${SYSDASH_ROWS:-${_r:-$(tput lines 2>/dev/null || echo 50)}}
case $TERM_COLS in ''|*[!0-9]*) TERM_COLS=100 ;; esac
case $TERM_ROWS in ''|*[!0-9]*) TERM_ROWS=50 ;; esac
[ "$TERM_COLS" -lt 73 ] && TERM_COLS=73
set_width $((TERM_COLS - 1))      # never touch the last column (avoids wrap glitches)
}
# ----------------------------------------------------------------------------
#  drawing primitives
# ----------------------------------------------------------------------------
strip_ansi() { STRIPPED=${1//"$ESC"\[*([0-9;])m/}; }
rep() { [ "$2" -gt 0 ] 2>/dev/null || return 0; local s; s=$(printf '%*s' "$2" ''); printf '%s' "${s// /$1}"; }
trunc() { local s=$1 n=$2; [ "$n" -lt 2 ] && n=2
if [ "${#s}" -gt "$n" ]; then printf '%s' "${s:0:$((n - 1))}$ELL"; else printf '%s' "$s"; fi; }
padv() { strip_ansi "$1"; local n=$(($2 - ${#STRIPPED})); printf '%s' "$1"; [ "$n" -gt 0 ] && printf '%*s' "$n" ''; return 0; }
box_top() {
local t=" $1 " n
n=$((COLS - 3 - ${#t}))
printf '%s%s%s%s%s%s%s%s%s
' "$ACC" "$TL" "$H" "$RST" "$BOLD$ACC2" "$t" "$RST$ACC" "$(rep "$H" "$n")" "$TR$RST"
}
box_sep() { printf '%s%s%s%s%s
' "$ACC" "$LT" "$(rep "$H" $((COLS - 2)))" "$RT" "$RST"; }
box_bot() { printf '%s%s%s%s%s
' "$ACC" "$BL" "$(rep "$H" $((COLS - 2)))" "$BR" "$RST"; }
box_line() { # text [extra-display-width]
local s=$1 x=${2:-0} n
strip_ansi "$s"; n=$((IW - ${#STRIPPED} - x)); [ "$n" -lt 0 ] && n=0
printf '%s%s%s %s%s%*s %s%s%s
' "$ACC" "$V" "$RST" "$s" "$RST" "$n" "" "$ACC" "$V" "$RST"
}
box_center() { strip_ansi "$1"; local l=$(((IW - ${#STRIPPED}) / 2)); [ "$l" -lt 0 ] && l=0; box_line "$(rep ' ' "$l")$1"; }
sec() { printf '%s%s%s %s%s%s' "$BOLD$ACC2" "$1" "$RST" "$DIM" "$(rep "$H" $(($2 - ${#1} - 1)))" "$RST"; }   # panel title
kv()  { printf '%s%-9s%s %s' "$DIM" "$1" "$RST" "$2"; }
bar() { # pct width
local p=${1:-0} w=${2:-10} f e col s t
case $p in ''|*[!0-9]*) p=0 ;; esac
[ "$p" -gt 100 ] && p=100
[ "$w" -lt 3 ] && w=3
f=$((p * w / 100)); e=$((w - f))
col=$OK; [ "$p" -ge 70 ] && col=$WARN; [ "$p" -ge 90 ] && col=$BAD
s=$(printf '%*s' "$f" ''); s=${s// /$FILL}
t=$(printf '%*s' "$e" ''); t=${t// /$EMPTY}
printf '%s%s%s%s%s' "$col" "$s" "$DIM" "$t" "$RST"
}
# Positive-quality meters: 100% is green, 0% is red, and the middle is yellow.
bar_good() { # pct width
local p=${1:-0} w=${2:-10} f e col s t
case $p in ''|*[!0-9]*) p=0 ;; esac
[ "$p" -gt 100 ] && p=100; [ "$p" -lt 0 ] && p=0
[ "$w" -lt 3 ] && w=3
f=$((p * w / 100)); e=$((w - f))
col=$WARN; [ "$p" -eq 100 ] && col=$OK; [ "$p" -eq 0 ] && col=$BAD
s=$(printf '%*s' "$f" ''); s=${s// /$FILL}
t=$(printf '%*s' "$e" ''); t=${t// /$EMPTY}
printf '%s%s%s%s%s' "$col" "$s" "$DIM" "$t" "$RST"
}
pctcol() { local p=${1:-0} c=$OK; [ "${p%.*}" -ge 70 ] 2>/dev/null && c=$WARN; [ "${p%.*}" -ge 90 ] 2>/dev/null && c=$BAD; printf '%s' "$c"; }
emit_rows() { # uses LA LB LC WA WB WC ROW_MARGIN
local n=${#LA[@]} i a b c row gap='   '
[ "${#LB[@]}" -gt "$n" ] && n=${#LB[@]}
[ "${#LC[@]}" -gt "$n" ] && n=${#LC[@]}
for ((i = 0; i < n; i++)); do
a=${LA[i]:-}; b=${LB[i]:-}; c=${LC[i]:-}
if [ "$WB" -gt 0 ]; then row="$(padv "$a" "$WA")$gap$(padv "$b" "$WB")$gap$c"
else row="$(padv "$a" "$WA")$gap$c"; fi
box_line "${ROW_MARGIN}${row}"
done
}
# ----------------------------------------------------------------------------
#  icons / process classification
# ----------------------------------------------------------------------------
icon_emoji() { # kind -> ICON (2 columns wide), KLBL
if [ "$UNI" = 1 ]; then
case $1 in
cron) ICON='⏰'; KLBL=cron;;        docker) ICON='🐳'; KLBL=docker;;
k8s) ICON='🚢'; KLBL=kubernetes;;   node) ICON='🟢'; KLBL=node.js;;
python) ICON='🐍'; KLBL=python;;    minecraft) ICON='🧱'; KLBL=minecraft;;
java) ICON='☕'; KLBL=java;;         web) ICON='🌐'; KLBL="web server";;
db) ICON='💾'; KLBL=database;;      ssh) ICON='🔑'; KLBL=ssh;;
shell) ICON='🐚'; KLBL=shell;;      php) ICON='🐘'; KLBL=php;;
ruby) ICON='💎'; KLBL=ruby;;        game) ICON='🎮'; KLBL="game server";;
file) ICON='📁'; KLBL="file share";; rdp) ICON='💻'; KLBL="remote desktop";;
media) ICON='🎬'; KLBL="media server";; mqtt) ICON='📡'; KLBL=mqtt;;
vpn) ICON='🔒'; KLBL=vpn;;          mail) ICON='📧'; KLBL=mail;;
system) ICON='🔧'; KLBL=system;;    *) ICON='🔧'; KLBL=process;;
esac
ICON_X=1
else
case $1 in
cron) ICON=CR; KLBL=cron;; docker) ICON=DK; KLBL=docker;; k8s) ICON=K8; KLBL=kubernetes;;
node) ICON=JS; KLBL=node.js;; python) ICON=PY; KLBL=python;; minecraft) ICON=MC; KLBL=minecraft;;
java) ICON=JV; KLBL=java;; web) ICON=WW; KLBL="web server";; db) ICON=DB; KLBL=database;;
ssh) ICON=SS; KLBL=ssh;; shell) ICON=SH; KLBL=shell;; php) ICON=PH; KLBL=php;; ruby) ICON=RB; KLBL=ruby;;
game) ICON=GM; KLBL="game server";; file) ICON=FS; KLBL="file share";; rdp) ICON=RD; KLBL="remote desktop";;
media) ICON=MD; KLBL="media server";; mqtt) ICON=MQ; KLBL=mqtt;; vpn) ICON=VP; KLBL=vpn;; mail) ICON=ML; KLBL=mail;;
system) ICON=SY; KLBL=system;; *) ICON='--'; KLBL=process;;
esac
ICON_X=0
fi
}
icon_of() { # kind -> ICON (2 columns wide, coloured badge), KLBL, ICON_X
local code=238 letters='--'
case $1 in
cron) letters=CR; code=178; KLBL=cron;;        docker) letters=DK; code=39; KLBL=docker;;
k8s) letters=K8; code=33; KLBL=kubernetes;;    node) letters=JS; code=77; KLBL=node.js;;
python) letters=PY; code=221; KLBL=python;;    minecraft) letters=MC; code=34; KLBL=minecraft;;
java) letters=JV; code=208; KLBL=java;;        web) letters=WW; code=75; KLBL="web server";;
db) letters=DB; code=141; KLBL=database;;      ssh) letters=SS; code=150; KLBL=ssh;;
shell) letters=SH; code=250; KLBL=shell;;      php) letters=PH; code=105; KLBL=php;;
ruby) letters=RB; code=203; KLBL=ruby;;        game) letters=GM; code=171; KLBL="game server";;
file) letters=FS; code=180; KLBL="file share";; rdp) letters=RD; code=38; KLBL="remote desktop";;
media) letters=MD; code=214; KLBL="media server";; mqtt) letters=MQ; code=99; KLBL=mqtt;;
vpn) letters=VP; code=72; KLBL=vpn;;           mail) letters=ML; code=111; KLBL=mail;;
system) letters=SY; code=240; KLBL=system;;    *) letters='--'; code=238; KLBL=process;;
esac
if [ "${SYSDASH_EMOJI:-0}" = 1 ] && [ "$UNI" = 1 ]; then icon_emoji "$1"; return; fi
ICON_X=0
if [ -n "${NO_COLOR:-}" ]; then ICON=$letters
elif [ -n "$RST" ] && [ "${#BAD}" -gt 6 ]; then
local fg=16; [ "$code" -le 240 ] && fg=255
ICON=$'\033[48;5;'"${code}"$'m\033[38;5;'"${fg}"'m'"${letters}${RST}"
else ICON=$'\033[46m\033[30m'"${letters}${RST}"; fi
}
classify() { # cmd args -> KIND
local c=$1 a=$2 la
la=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
KIND=other
case $c in
kubelet|kube-*|k3s*|k0s|etcd|minikube|crio|cri-o) KIND=k8s;;
dockerd|docker|docker-*|containerd|containerd-shim*|podman|conmon|runc|crun) KIND=docker;;
cron|crond|anacron|atd|fcron|systemd-cron*) KIND=cron;;
node|nodejs|npm|npx|pm2|PM2*|bun|deno|yarn|pnpm) KIND=node;;
python|python[0-9]*|gunicorn|uvicorn|celery|uwsgi|ipython|jupyter*|flask|pipx) KIND=python;;
java|javaw|javaw.exe)
case $la in
*minecraft*|*paper*|*spigot*|*bukkit*|*purpur*|*fabric*|*forge*|*quilt*|*velocity*|*bungeecord*|*waterfall*|*folia*|*server.jar*|*nogui*) KIND=minecraft;;
*) KIND=java;;
esac;;
bedrock_server) KIND=minecraft;;
nginx|apache2|httpd|caddy|lighttpd|traefik|haproxy|envoy) KIND=web;;
postgres*|mysqld|mariadbd|mongod|mongos|redis-server|redis|memcached|influxd|clickhouse*|cockroach) KIND=db;;
sshd|sshd:*|sshd-session|ssh) KIND=ssh;;
bash|zsh|fish|sh|dash|ksh|tmux*|screen) KIND=shell;;
php|php-fpm*|php[0-9]*) KIND=php;;
ruby|puma|unicorn|rails) KIND=ruby;;
systemd*|init|dbus-daemon|udevd|rsyslogd|agetty|login) KIND=system;;
esac
if [ "$KIND" = other ]; then case $la in *minecraft*) KIND=minecraft;; esac; fi
}
port_kind() { # port -> KIND, PLBL
case $1 in
80|443|8080|8443|8000|8008|3000|5000|8888|9000) KIND=web; PLBL=Website;;
22|2222) KIND=ssh; PLBL=SSH;;
25565|25566|19132|19133) KIND=minecraft; PLBL=Minecraft;;
27015|27016|7777|7778|2456|2457|28960|34197|30120|64738) KIND=game; PLBL="Game server";;
3306|5432|6379|27017|1433|9042|5984) KIND=db; PLBL=Database;;
21|990) KIND=file; PLBL=FTP;;
445|139|2049) KIND=file; PLBL="File share";;
3389|5900|5901) KIND=rdp; PLBL="Remote desktop";;
32400|8096|8920) KIND=media; PLBL="Media server";;
1883|8883) KIND=mqtt; PLBL=MQTT;;
51820) KIND=vpn; PLBL=VPN;;
25|465|587|993|143) KIND=mail; PLBL=Mail;;
*) KIND=other; PLBL=Service;;
esac
}
svc_name() { # port -> well-known name (empty if unknown)
case $1 in
22) echo ssh;; 25) echo smtp;; 53) echo dns;; 80) echo http;; 110) echo pop3;; 111) echo rpcbind;;
123) echo ntp;; 143) echo imap;; 443) echo https;; 445) echo smb;; 631) echo cups;; 993) echo imaps;;
1883) echo mqtt;; 2375|2376) echo docker;; 3000) echo dev-web;; 3306) echo mysql;; 3389) echo rdp;;
5353) echo mdns;; 5432) echo postgres;; 5900) echo vnc;; 6379) echo redis;; 6443) echo k8s-api;;
8080) echo http-alt;; 8443) echo https-alt;; 9090) echo prometheus;; 10250) echo kubelet;;
19132) echo minecraft-be;; 25565) echo minecraft;; 25575) echo rcon;; 27017) echo mongodb;;
27015) echo source-game;; 32400) echo plex;; 8096) echo jellyfin;; 51820) echo wireguard;;
*) echo "";;
esac
}
# ----------------------------------------------------------------------------
#  data: system
# ----------------------------------------------------------------------------
os_name() {
if [ -r /etc/os-release ]; then ( . /etc/os-release; echo "${PRETTY_NAME:-$NAME}" )
elif have sw_vers; then echo "$(sw_vers -productName) $(sw_vers -productVersion)"
else uname -sr; fi
}
uptime_secs() {
if [ -r /proc/uptime ]; then local u; read -r u _ </proc/uptime; echo "${u%.*}"
elif have sysctl; then
local b; b=$(sysctl -n kern.boottime 2>/dev/null | sed -E 's/.*sec = ([0-9]+).*/\1/')
case $b in ''|*[!0-9]*) echo 0;; *) echo $(($(now) - b));; esac
else echo 0; fi
}
host_model() {
local m=""
[ -r /sys/devices/virtual/dmi/id/product_name ] && m=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)
[ -z "$m" ] && [ -r /proc/device-tree/model ] && m=$(tr -d '\0' </proc/device-tree/model 2>/dev/null)
[ -z "$m" ] && [ "$OS_KIND" = Darwin ] && m=$(sysctl -n hw.model 2>/dev/null)
if have systemd-detect-virt; then
local v; v=$(systemd-detect-virt 2>/dev/null); [ -n "$v" ] && [ "$v" != none ] && m="${m:+$m }(vm: $v)"
fi
echo "$m"
}
cpu_model() {
local m=""
[ -r /proc/cpuinfo ] && m=$(awk -F: '/^model name|^Model name|^Hardware|^cpu model/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
[ -z "$m" ] && have lscpu && m=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
[ -z "$m" ] && [ "$OS_KIND" = Darwin ] && m=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
[ -z "$m" ] && m=$(uname -m)
echo "$m" | sed -E 's/\((R|TM|tm|r)\)//g; s/ CPU//; s/@.*//; s/[[:space:]]+/ /g; s/ $//'
}
cpu_ghz()  { local f; f=$(awk -F: '/cpu MHz/{print $2; exit}' /proc/cpuinfo 2>/dev/null); [ -n "$f" ] && awk -v f="$f" 'BEGIN{printf "%.2f GHz", f/1000}'; }
ncpu()     { getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1; }
load_avg() { uptime 2>/dev/null | sed -E 's/.*load averages?: *//; s/,/ /g; s/  +/ /g'; }
_cpu_snap() { local l; read -r l </proc/stat; set -- $l; echo "$(($2 + $3 + $4 + $5 + $6 + $7 + $8 + ${9:-0})) $(($5 + $6))"; }
cpu_usage() {
if [ -r /proc/stat ]; then
local t1 i1 t2 i2 dt di
read -r t1 i1 <<<"$(_cpu_snap)"; sleep 0.10; read -r t2 i2 <<<"$(_cpu_snap)"
dt=$((t2 - t1)); di=$((i2 - i1))
if [ "$dt" -gt 0 ]; then echo $((100 * (dt - di) / dt)); else echo 0; fi
else
ps -A -o %cpu= 2>/dev/null | awk -v n="$(ncpu)" '{s+=$1} END{v=s/n; if(v>100)v=100; printf "%d", v}'
fi
}
cpu_temp() {
local best=0 z t
for z in /sys/class/thermal/thermal_zone*; do
[ -e "$z/temp" ] || continue
read -r t 2>/dev/null <"$z/temp"
case $t in ''|*[!0-9]*) continue;; esac
[ "$t" -gt "$best" ] && best=$t
done
[ "$best" -gt 0 ] && echo $((best / 1000))
}
mem_info() { # sets MEM_* SWAP_* in kB
MEM_TOTAL=0; MEM_USED=0; MEM_CACHE=0; SWAP_TOTAL=0; SWAP_USED=0
if [ -r /proc/meminfo ]; then
local MemTotal MemAvailable MemFree Buffers Cached SwapTotal SwapFree
eval "$(awk '/^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):/{gsub(":","",$1); print $1"="$2}' /proc/meminfo)"
: "${MemAvailable:=$((MemFree + Buffers + Cached))}"
MEM_TOTAL=$MemTotal; MEM_USED=$((MemTotal - MemAvailable)); MEM_CACHE=$((Buffers + Cached))
SWAP_TOTAL=$SwapTotal; SWAP_USED=$((SwapTotal - SwapFree))
elif [ "$OS_KIND" = Darwin ]; then
local bytes psz freepg
bytes=$(sysctl -n hw.memsize 2>/dev/null); MEM_TOTAL=$((bytes / 1024))
psz=$(vm_stat 2>/dev/null | awk '/page size of/{print $8}'); psz=${psz:-4096}
freepg=$(vm_stat 2>/dev/null | awk '/Pages (free|inactive|speculative)/{gsub("\\.","",$3); s+=$3} END{print s+0}')
MEM_USED=$((MEM_TOTAL - freepg * psz / 1024))
read -r SWAP_TOTAL SWAP_USED <<<"$(sysctl -n vm.swapusage 2>/dev/null | awk '{gsub("M","",$3); gsub("M","",$6); printf "%d %d", $3*1024, $6*1024}')"
fi
}
disk_list() { # mount|pct|size|used|avail
local out
out=$(df -Pk 2>/dev/null | awk 'NR>1 {
dev=$1; mnt=$6; for(i=7;i<=NF;i++) mnt=mnt" "$i
if (dev ~ /^(tmpfs|devtmpfs|overlay|squashfs|none|udev|map|devfs|efivarfs|shm|ramfs|fuse\.|\/dev\/loop)/) next
if (mnt ~ /^\/(proc|sys|dev|run|snap)(\/|$)/ || mnt ~ /^\/boot\/efi/) next
if (mnt ~ /^\/System\/Volumes\// && mnt != "/System/Volumes/Data") next
if (seen[dev]++) next
pct=$5; sub(/%/,"",pct); print mnt "|" pct "|" $2 "|" $3 "|" $4 }' | head -n 4)
[ -z "$out" ] && out=$(df -Pk / 2>/dev/null | awk 'NR>1{pct=$5; sub(/%/,"",pct); print "/|" pct "|" $2 "|" $3 "|" $4}')
printf '%s
' "$out"
}
net_info() {
NET_IF=""; NET_IP=""
if have ip; then
local r; r=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1)
NET_IF=$(echo "$r" | sed -n 's/.* dev \([^ ]*\).*/\1/p'); NET_IP=$(echo "$r" | sed -n 's/.* src \([^ ]*\).*/\1/p')
fi
if [ -z "$NET_IP" ] && [ "$OS_KIND" = Darwin ]; then
NET_IF=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
[ -n "$NET_IF" ] && NET_IP=$(ipconfig getifaddr "$NET_IF" 2>/dev/null)
fi
[ -z "$NET_IP" ] && have hostname && NET_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
NET_RX=""; NET_TX=""
if [ -n "$NET_IF" ] && [ -r "/sys/class/net/$NET_IF/statistics/rx_bytes" ]; then
NET_RX=$(cat "/sys/class/net/$NET_IF/statistics/rx_bytes"); NET_TX=$(cat "/sys/class/net/$NET_IF/statistics/tx_bytes")
fi
}
external_ip() { # Cached public IPv4 lookup; only called when the display is permitted.
local cache="$SD_DIR/external-ip.cache" stamp now_ip
if [ -s "$cache" ]; then
stamp=$(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null)
if [[ "$stamp" =~ ^[0-9]+$ ]] && [ "$(( $(date +%s) - stamp ))" -lt 300 ]; then cat "$cache"; return; fi
fi
now_ip=""
if have curl; then now_ip=$(tmo 3 curl -4fsS https://api.ipify.org 2>/dev/null)
elif have wget; then now_ip=$(tmo 3 wget -qO- https://api.ipify.org 2>/dev/null); fi
if [[ "$now_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
printf '%s
' "$now_ip" > "$cache" 2>/dev/null
printf '%s
' "$now_ip"
else
[ -s "$cache" ] && cat "$cache" || printf 'n/a'
fi
}
# ----------------------------------------------------------------------------
#  data: processes, ports, connections
# ----------------------------------------------------------------------------
proc_sample() { cat /proc/[0-9]*/stat 2>/dev/null | awk '{ i=match($0,/\) [A-Za-z] /); if(!i) next; n=split(substr($0,i+2),f," "); print $1, f[12]+f[13] }'; }
top_procs() { # n -> cpu|mem|pid|user|args  (live CPU%, per-core like top)
local n=${1:-8}
if [ -d /proc/self ] && [ -r /proc/stat ]; then
local hz a b tbl; hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
a=$(proc_sample); sleep 0.10; b=$(proc_sample)
tbl=$({ printf '%s
' "$a" | sed 's/^/A /'; printf '%s
' "$b" | sed 's/^/B /'; } |
awk -v hz="$hz" -v dt=0.1 '$1=="A"{a[$2]=$3} $1=="B"{ if(($2 in a)){ d=$3-a[$2]; if(d<0)d=0; printf "%d %.1f\n",$2,d*100/hz/dt } }')
awk '
NR==FNR { cpu[$1]=$2; next }
($1 in cpu) { args=$4; for(i=5;i<=NF;i++) args=args" "$i
if (args ~ /^\[/ || args ~ /sysdash/ || args ~ /^(ps|cat|awk|gawk|mawk|sed|sort|head|tr|grep|sleep|getconf|date)( |$)/) next
print cpu[$1] "|" $2 "|" $1 "|" $3 "|" args }' \
<(printf '%s
' "$tbl") <(ps -eo pid=,pmem=,user=,args= 2>/dev/null) |
sort -t'|' -k1,1nr | head -n "$n"
else
ps -Ao pcpu=,pmem=,pid=,user=,args= 2>/dev/null | awk '
{ args=$5; for(i=6;i<=NF;i++) args=args" "$i
if (args ~ /sysdash/ || args ~ /^(ps|awk|sed|sort|head)( |$)/) next
print $1 "|" $2 "|" $3 "|" $4 "|" args }' | sort -t'|' -k1,1nr | head -n "$n"
fi
}
get_listeners() { # proto|addr|port|proc
local sudo_ss=""
[ "$(id -u)" != 0 ] && have sudo && sudo -n true 2>/dev/null && sudo_ss="sudo -n"
if have ss; then
$sudo_ss ss -tulnp 2>/dev/null | awk 'NR>1 {
proto=$1; loc=$5
if (match(loc,/[.:][0-9]+$/)) { port=substr(loc,RSTART+1); addr=substr(loc,1,RSTART-1) } else next
gsub(/[\[\]]/,"",addr); proc=""
if (match($0,/\(\("[^"]+"/)) proc=substr($0,RSTART+3,RLENGTH-4)
sub(/6$/,"",proto); print proto "|" addr "|" port "|" proc }'
elif have lsof; then
lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null | awk 'NR>1 {
loc=$9; proto=tolower($8)
if (match(loc,/[.:][0-9]+$/)) { port=substr(loc,RSTART+1); addr=substr(loc,1,RSTART-1) } else next
gsub(/[\[\]]/,"",addr); sub(/^\*$/,"0.0.0.0",addr); print proto "|" addr "|" port "|" $1 }'
elif have netstat; then
netstat -tuln 2>/dev/null | awk '$1 ~ /^(tcp|udp)/ {
proto=$1; loc=$4
if (match(loc,/[.:][0-9]+$/)) { port=substr(loc,RSTART+1); addr=substr(loc,1,RSTART-1) } else next
gsub(/[\[\]]/,"",addr); sub(/6$/,"",proto); print proto "|" addr "|" port "|" }'
fi
}
get_established() { # lport raddr
local prog='
function sp(a) { if (match(a,/[.:][0-9]+$/)) { P=substr(a,RSTART+1); A=substr(a,1,RSTART-1); gsub(/[\[\]]/,"",A); sub(/^::ffff:/,"",A); return 1 } return 0 }'
if have ss; then
ss -tn state established 2>/dev/null | awk "$prog"'NR>1 { if (sp($(NF-1))) { lp=P; if (sp($NF)) print lp, A } }'
elif have netstat; then
netstat -tn 2>/dev/null | awk "$prog"'$6=="ESTABLISHED" { if (sp($4)) { lp=P; if (sp($5)) print lp, A } }'
fi
}
# ----------------------------------------------------------------------------
#  data: power + internet probes (used by the collector)
# ----------------------------------------------------------------------------
get_net_state() {
local t h p
if have timeout || have gtimeout; then
for t in 1.1.1.1:443 8.8.8.8:53 9.9.9.9:443; do
h=${t%:*}; p=${t#*:}
tmo 3 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null && { echo up; return; }
done
elif have ping; then
if [ "$OS_KIND" = Darwin ]; then ping -c1 -t2 1.1.1.1 >/dev/null 2>&1 && { echo up; return; }
else ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && { echo up; return; }; fi
fi
echo down
}
get_power_state() { # ac | bat | none
local d t st="" seen=0 ac=0 bat=0
if [ -d /sys/class/power_supply ]; then
for d in /sys/class/power_supply/*; do
[ -r "$d/type" ] || continue
t=$(cat "$d/type" 2>/dev/null)
case $t in
Mains|USB*) seen=1; [ "$(cat "$d/online" 2>/dev/null)" = 1 ] && ac=1;;
Battery) [ "$(cat "$d/scope" 2>/dev/null)" = Device ] && continue; bat=1; st=$(cat "$d/status" 2>/dev/null);;
esac
done
if [ "$bat" -eq 1 ]; then
if [ "$seen" -eq 1 ]; then [ "$ac" -eq 1 ] && echo ac || echo bat
else case $st in Discharging) echo bat;; *) echo ac;; esac; fi
else echo none; fi
return
fi
if [ "$OS_KIND" = Darwin ] && have pmset; then
local o; o=$(pmset -g batt 2>/dev/null)
case $o in *InternalBattery*) case $o in *"AC Power"*) echo ac;; *) echo bat;; esac;; *) echo none;; esac
return
fi
echo none
}
battery_info() { # BAT_PCT BAT_STATUS BAT_ETA(seconds)
BAT_PCT=""; BAT_STATUS=""; BAT_ETA=""
local d en fu ra
for d in /sys/class/power_supply/*; do
[ -r "$d/type" ] || continue
[ "$(cat "$d/type" 2>/dev/null)" = Battery ] || continue
[ "$(cat "$d/scope" 2>/dev/null)" = Device ] && continue
BAT_PCT=$(cat "$d/capacity" 2>/dev/null); BAT_STATUS=$(cat "$d/status" 2>/dev/null)
en=$(cat "$d/energy_now" 2>/dev/null || cat "$d/charge_now" 2>/dev/null)
fu=$(cat "$d/energy_full" 2>/dev/null || cat "$d/charge_full" 2>/dev/null)
ra=$(cat "$d/power_now" 2>/dev/null || cat "$d/current_now" 2>/dev/null)
if [ "${ra:-0}" -gt 0 ] 2>/dev/null; then
case $BAT_STATUS in
Discharging) BAT_ETA=$(awk -v n="$en" -v r="$ra" 'BEGIN{printf "%d", n*3600/r}');;
Charging)    BAT_ETA=$(awk -v n="$en" -v f="$fu" -v r="$ra" 'BEGIN{printf "%d", (f-n)*3600/r}');;
esac
fi
return
done
if [ "$OS_KIND" = Darwin ] && have pmset; then
local o; o=$(pmset -g batt 2>/dev/null)
BAT_PCT=$(echo "$o" | grep -Eo '[0-9]+%' | head -n1 | tr -d %)
BAT_STATUS=$(echo "$o" | awk -F'; ' '/InternalBattery/{print $2}')
local t; t=$(echo "$o" | grep -Eo '[0-9]+:[0-9]+ remaining' | cut -d' ' -f1)
[ -n "$t" ] && BAT_ETA=$(( ${t%:*} * 3600 + ${t#*:} * 60 ))
fi
}
# ----------------------------------------------------------------------------
#  collector (background): records internet + power state transitions
# ----------------------------------------------------------------------------
last_state() { tail -n1 "$1" 2>/dev/null | awk '{print $2}'; }
mark_unknown() { [ "$(last_state "$1")" = unknown ] || echo "$2 unknown" >>"$1"; }
trim_log() { [ -f "$1" ] && [ "$(wc -l <"$1")" -gt 4000 ] && { tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }; return 0; }
collector_running() {
local p; p=$(cat "$PID_FILE" 2>/dev/null)
[ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -p "$p" -o args= 2>/dev/null | grep -q -- '--collect'
}
collector_loop() {
mkdir -p "$SD_DIR"
local old; old=$(cat "$PID_FILE" 2>/dev/null)
if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null && ps -p "$old" -o args= 2>/dev/null | grep -q -- '--collect'; then exit 0; fi
echo $$ >"$PID_FILE"; trap 'rm -f "$PID_FILE"; exit 0' INT TERM HUP
local prev=0 n s
[ -r "$HB_FILE" ] && read -r prev <"$HB_FILE"
case $prev in ''|*[!0-9]*) prev=0;; esac
trim_log "$NET_LOG"; trim_log "$PWR_LOG"
while :; do
n=$(now)
if [ "$prev" -gt 0 ] && [ $((n - prev)) -gt "$GRACE" ]; then   # slept / was off / killed
mark_unknown "$NET_LOG" "$prev"; mark_unknown "$PWR_LOG" "$prev"
fi
echo "$n" >"$HB_FILE"; prev=$n
s=$(get_net_state);   [ "$s" != "$(last_state "$NET_LOG")" ] && echo "$n $s" >>"$NET_LOG"
s=$(get_power_state); [ "$s" != "$(last_state "$PWR_LOG")" ] && echo "$n $s" >>"$PWR_LOG"
sleep "$INTERVAL"
done
}
start_collector() {
[ -x "$SD_COPY" ] || return 1
if have setsid; then setsid nohup "$SD_COPY" --collect >/dev/null 2>&1 </dev/null &
else nohup "$SD_COPY" --collect >/dev/null 2>&1 </dev/null & fi
disown 2>/dev/null; return 0
}
install_cron() {
have crontab || return 0
local cur; cur=$(crontab -l 2>/dev/null)
case $cur in *"# sysdash"*) return 0;; esac
{ [ -n "$cur" ] && printf '%s
' "$cur"
echo "@reboot \"$SD_COPY\" --ensure >/dev/null 2>&1 # sysdash"
echo "*/5 * * * * \"$SD_COPY\" --ensure >/dev/null 2>&1 # sysdash"; } | crontab - 2>/dev/null
}
ensure_collector() {
mkdir -p "$SD_DIR" 2>/dev/null
if [ "$SELF" != "$SD_COPY" ] && [ -r "$SELF" ]; then
cmp -s "$SELF" "$SD_COPY" 2>/dev/null || { cp "$SELF" "$SD_COPY" 2>/dev/null; chmod +x "$SD_COPY" 2>/dev/null; }
fi
[ -x "$SD_COPY" ] || return 1
[ -s "$NET_LOG" ] || echo "$(now) $(get_net_state)"   >>"$NET_LOG"
[ -s "$PWR_LOG" ] || echo "$(now) $(get_power_state)" >>"$PWR_LOG"
collector_running || start_collector
install_cron
}
uninstall() {
[ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null
if have crontab; then crontab -l 2>/dev/null | grep -v '# sysdash' | crontab - 2>/dev/null; fi
rm -rf "$SD_DIR"
echo "sysdash: collector stopped, cron entries and history removed."
}
log_stats() { # file good bad  -> S_STATE S_SINCE S_FLOOR S_GOOD S_BAD S_UNK S_START S_OUTS S_LONG
local hb=0; [ -r "$HB_FILE" ] && read -r hb <"$HB_FILE"
case $hb in ''|*[!0-9]*) hb=0;; esac
S_STATE=""; S_SINCE=0; S_FLOOR=0; S_GOOD=0; S_BAD=0; S_UNK=0; S_START=0; S_OUTS=0; S_LONG=0
[ -s "$1" ] || return 1
read -r S_STATE S_SINCE S_FLOOR S_GOOD S_BAD S_UNK S_START S_OUTS S_LONG <<<"$(awk -v now="$(now)" -v hb="$hb" -v grace="$GRACE" -v good="$2" -v bad="$3" '
{ ts[NR]=$1; st[NR]=$2 }
END {
end=now; if (hb>0 && now-hb>grace) end=hb
for (i=1;i<=NR;i++) {
nx=(i<NR)?ts[i+1]:end; d=nx-ts[i]; if(d<0)d=0
tot[st[i]]+=d
if (st[i]==bad) { outs++; if (d>lg) lg=d }
}
fl=(NR==1 || st[NR-1]=="unknown")?1:0
printf "%s %d %d %d %d %d %d %d %d
", st[NR], ts[NR], fl, tot[good], tot[bad], tot["unknown"], ts[1], outs, lg
}' "$1")"
}
# ----------------------------------------------------------------------------
#  dependency installer
# ----------------------------------------------------------------------------
detect_pm() { PM=""; local p; for p in apt-get dnf yum pacman zypper apk brew pkg; do have "$p" && { PM=$p; return; }; done; }
can_install() {
[ -n "$PM" ] || return 1
SUDO=""
[ "$PM" = brew ] && return 0
[ "$(id -u)" = 0 ] && return 0
have sudo || return 1
SUDO=sudo
[ -t 0 ] && return 0
sudo -n true 2>/dev/null
}
pkg_name() {
case "$1:$PM" in
iproute:dnf|iproute:yum) echo iproute;;
iproute:*) echo iproute2;;
procps:dnf|procps:yum|procps:pacman) echo procps-ng;;
*) echo "$1";;
esac
}
pkg_install() {
case $PM in
apt-get) $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@";;
dnf|yum) $SUDO "$PM" install -y -q "$@";;
pacman)  $SUDO pacman -S --noconfirm --needed "$@";;
zypper)  $SUDO zypper --non-interactive install "$@";;
apk)     $SUDO apk add --quiet "$@";;
brew)    brew install "$@";;
pkg)     $SUDO pkg install -y "$@";;
*) return 1;;
esac
}
try_install() {
local name=$1 pkg; pkg=$(pkg_name "$name")
grep -qx "$name:$PM" "$TRIED_FILE" 2>/dev/null && return 1
echo "$name:$PM" >>"$TRIED_FILE"
printf '%s▸%s installing %s%s%s … ' "$ACC" "$RST" "$BOLD" "$pkg" "$RST"
if [ "$PM" = apt-get ] && [ -z "${APT_UPDATED:-}" ]; then $SUDO apt-get update -qq >>"$INSTALL_LOG" 2>&1; APT_UPDATED=1; fi
if pkg_install "$pkg" >>"$INSTALL_LOG" 2>&1; then printf '%sok%s
' "$OK" "$RST"; return 0
else printf '%sunavailable%s %s(using built-in fallback)%s
' "$WARN" "$RST" "$DIM" "$RST"; return 1; fi
}
ensure_deps() {
detect_pm
local missing=()
have tuptime   || missing+=(tuptime)
[ "$OS_KIND" = Linux ] && ! have ss && ! have netstat && missing+=(iproute)
[ "$OS_KIND" = Linux ] && ! have ps && missing+=(procps)
[ "${#missing[@]}" -eq 0 ] && return 0
if ! can_install; then
printf '%s▸ missing optional tools: %s (no package manager/sudo available — using fallbacks)%s
' "$DIM" "${missing[*]}" "$RST"
return 0
fi
mkdir -p "$SD_DIR"
local m
for m in "${missing[@]}"; do
case $m in
tuptime)   try_install tuptime && { $SUDO tuptime -x >/dev/null 2>&1; } ;;
*)         try_install "$m" ;;
esac
done
}
# ----------------------------------------------------------------------------
#  live resource history (kept in-memory for the current --live session)
# ----------------------------------------------------------------------------
H_CPU=(); H_MEM=(); H_DISK=(); H_GPU=(); H_NET=()
H_PREV_RX=""; H_PREV_TX=""; NET_LAST_RATE=0; H_GPU_AVAILABLE=0
hist_push() { # array name, value; keep newest 48 samples
local name=$1 value=$2
eval "$name+=(\"\$value\")"
eval '[ "${#'"$name"'[@]}" -gt 48 ]' && eval "$name=(\"\${$name[@]:1}\")"
}
sample_history() {
local mem=0 disk=0 gpu=0 net=0 rx=0 tx=0
[ "${MEM_TOTAL:-0}" -gt 0 ] && mem=$((MEM_USED * 100 / MEM_TOTAL))
disk=$(df -Pk / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')
if have nvidia-smi; then
gpu=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -cd '0-9')
if [ -n "$gpu" ]; then H_GPU_AVAILABLE=1; else gpu=0; fi
fi
if [ -n "${NET_RX:-}" ] && [ -n "${NET_TX:-}" ]; then
rx=$NET_RX; tx=$NET_TX
if [ -n "$H_PREV_RX" ]; then
net=$(( ((rx - H_PREV_RX) + (tx - H_PREV_TX)) * 2 / 1024 ))
[ "$net" -lt 0 ] && net=0
[ "$net" -gt 100000 ] && net=100000
fi
H_PREV_RX=$rx; H_PREV_TX=$tx
fi
NET_LAST_RATE=$net
hist_push H_CPU "${G_USAGE:-0}"
hist_push H_MEM "$mem"
hist_push H_DISK "${disk:-0}"
hist_push H_GPU "$gpu"
hist_push H_NET "$net"
}
sparkline() { # history array name, output width, color
local name=$1 width=$2 color=$3 count i idx v max=0 chars out=""
local -a vals
eval 'vals=( "${'"$name"'[@]}" )'
count=${#vals[@]}
[ "$count" -eq 0 ] && { printf '%s%s%s' "$DIM" "$(rep '-' "$width")" "$RST"; return; }
for v in "${vals[@]}"; do [ "$v" -gt "$max" ] && max=$v; done
[ "$max" -lt 1 ] && max=1
if [ "$UNI" = 1 ]; then chars='▁▂▃▄▅▆▇█'; else chars='._:-=+*#'; fi
for ((i=0; i<width; i++)); do
idx=$((count - width + i))
if [ "$idx" -lt 0 ]; then out="${out} "; continue; fi
v=${vals[idx]:-0}
local level=$((v * 7 / max)); [ "$level" -gt 7 ] && level=7
out="${out}${chars:level:1}"
done
printf '%s%s%s' "$color" "$out" "$RST"
}
plot_history() { # array-name width height max-value color
local name=$1 width=$2 height=$3 maxval=$4 color=$5
local -a vals points rows
local count i idx v level prev x row glyph
eval 'vals=( "${'"$name"'[@]}" )'
count=${#vals[@]}
[ "$maxval" -lt 1 ] && maxval=1
[ "$width" -lt 3 ] && width=3
[ "$height" -lt 2 ] && height=2
points=()
for ((x=0; x<width; x++)); do
if [ "$count" -gt 0 ]; then
idx=$(( (x * count) / width )); [ "$idx" -ge "$count" ] && idx=$((count - 1))
v=${vals[idx]:-0}
else v=0; fi
level=$((v * (height - 1) / maxval))
[ "$level" -lt 0 ] && level=0; [ "$level" -ge "$height" ] && level=$((height - 1))
points[x]=$level
done
for ((i=0; i<height; i++)); do rows[i]=""; done
for ((x=0; x<width; x++)); do
level=${points[x]}
for ((i=0; i<height; i++)); do
glyph=" "
if [ "$i" -eq $((height - 1 - level)) ]; then
glyph='●'
if [ "$UNI" -ne 1 ]; then glyph='*'; fi
elif [ $((i % 2)) -eq 0 ]; then
glyph='·'
if [ "$UNI" -ne 1 ]; then glyph='.'; fi
fi
rows[i]="${rows[i]}${glyph}"
done
done
for ((i=0; i<height; i++)); do printf '%s%s%s
' "$color" "${rows[i]}" "$RST"; done
}
render_graphs() { # width, target total line count (fills remaining left column)
local w=$1 total_h=$2 cell plotw ploth i j c row line current maxnet palette="" swatches="" extra panelw
local -a labels=(CPU MEMORY DISK GPU NETWORK)
local -a arrays=(H_CPU H_MEM H_DISK H_GPU H_NET)
local -a colors=("$ACC" "$OK" "$WARN" "$ACC2" "$OK")
local -a currents plots widths
[ "$total_h" -lt 8 ] && total_h=8
cell=$(((w - 4) / 5)); [ "$cell" -lt 6 ] && cell=6
extra=$(((w - 4) - cell * 5))
for ((i=0; i<5; i++)); do panelw=$cell; [ "$i" -lt "$extra" ] && panelw=$((panelw + 1)); widths[i]=$panelw; done
plotw=$((cell - 2)); [ "$plotw" -lt 3 ] && plotw=3
# Use all available history-panel height for the graphs.
ploth=$((total_h - 6))
[ "$ploth" -lt 2 ] && ploth=2
maxnet=1
for v in "${H_NET[@]}"; do [ "$v" -gt "$maxnet" ] && maxnet=$v; done
currents=("${G_USAGE:-0}%" "$((MEM_TOTAL > 0 ? MEM_USED * 100 / MEM_TOTAL : 0))%" "$(df -Pk / 2>/dev/null | awk 'NR==2 {print $5}')" )
if [ "$H_GPU_AVAILABLE" = 1 ]; then currents+=("$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1)%"); else currents+=("N/A"); fi
currents+=("$(hbytes "$((NET_LAST_RATE * 1024))")/s")
box_top "RESOURCE HISTORY"
# Five equal-width panels; each is a multi-row time-series plot.
row=""
for ((i=0; i<5; i++)); do
line="${BOLD}${colors[i]}${labels[i]}${RST}"
row+="$(padv "$line" "${widths[i]}")"
done
box_line "$row"
row=""
for ((i=0; i<5; i++)); do row+="$(padv "${BOLD}${currents[i]}${RST}" "${widths[i]}")"; done
box_line "$row"
# Plot rows are aligned across all five panels.
plots=()
for ((i=0; i<5; i++)); do
case $i in 4) plots[i]="$(plot_history "${arrays[i]}" "$plotw" "$ploth" "$maxnet" "${colors[i]}")";;
*) plots[i]="$(plot_history "${arrays[i]}" "$plotw" "$ploth" 100 "${colors[i]}")";; esac
done
for ((j=0; j<ploth; j++)); do
row=""
for ((i=0; i<5; i++)); do
line=$(printf '%s
' "${plots[i]}" | sed -n "$((j + 1))p")
row+="$(padv "$line" "${widths[i]}")"
done
box_line "$row"
done
# Separate the time-series plots from the full-width ANSI palette.
box_sep
for c in {0..15}; do swatches+=$'\033[48;5;'"${c}"$'m  '; done
box_line "${DIM}COLOR PALETTE${RST}  ${swatches}${RST}"
box_bot
}
# ----------------------------------------------------------------------------
#  sections
# ----------------------------------------------------------------------------
render_header() {
local user actual_user host up
actual_user=$(id -un 2>/dev/null || echo "$USER"); user=$actual_user; host=$(hostname -s 2>/dev/null || hostname)
if [ "$OPT_SHOWCASE" = 1 ]; then
[ "$OPT_SHOWCASE_UN" = 1 ] || user="[hidden]"
[ "$OPT_SHOWCASE_SN" = 1 ] || host="[hidden]"
fi
up=$(uptime_secs)
box_top "SYSTEM $SEP USER"
box_center "${BOLD}${ACC}${user}${RST}${DIM}@${RST}${BOLD}${ACC}${host}${RST}"
box_center "${DIM}$(os_name)  ${SEP}  $(uname -sr)  ${SEP}  $(uname -m)${RST}"
box_sep
LA=(); LB=(); LC=(); ROW_MARGIN=''
local wa=$(((IW - 3) / 2)) vw sess who_n who_l grp
vw=$((wa - 10))
LA+=("$(kv OS "$(trunc "$(os_name)" "$vw")")")
LA+=("$(kv Kernel "$(trunc "$(uname -r) ($(uname -m))" "$vw")")")
local host_info="$host $(host_model)"
[ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_SN" != 1 ] && host_info="[hidden]"
LA+=("$(kv Host "$(trunc "$host_info" "$vw")")")
LA+=("$(kv Uptime "$(fmt_dur "$up") ${DIM}since $(fmt_epoch $(($(now) - up)))${RST}")")
LA+=("$(kv Shell "$(trunc "${SHELL##*/} ${SEP} ${TERM_PROGRAM:-${TERM:-n/a}}" "$vw")")")
if [ "$OPT_SHOWCASE" = 1 ]; then
if [ "$OPT_SHOWCASE_UN" = 1 ]; then LC+=("$(kv User "${user} ${DIM}(uid $(id -u))${RST}")"); else LC+=("$(kv User "[hidden]")"); fi
else LC+=("$(kv User "${user} ${DIM}(uid $(id -u))${RST}")"); fi
grp=$(id -Gn 2>/dev/null | tr ' ' ',')
[ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_G" != 1 ] && grp="[hidden]"
LC+=("$(kv Groups "$(trunc "$grp" "$vw")")")
if [ -n "${SSH_CLIENT:-}" ]; then sess="ssh from ${SSH_CLIENT%% *}"; else if [ -t 0 ]; then sess="local $(tty 2>/dev/null | sed 's|/dev/||')"; else sess="non-interactive"; fi; fi
[ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_S" != 1 ] && sess="[hidden]"
LC+=("$(kv Session "$(trunc "$sess" "$vw")")")
who_l=$(who 2>/dev/null | awk '{print $1}' | sort -u | tr '
' ',' | sed 's/,$//'); who_n=$(who 2>/dev/null | wc -l | tr -d ' ')
[ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_OUN" != 1 ] && who_l="[hidden]"
LC+=("$(kv Logged-in "${who_n} ${DIM}($(trunc "${who_l:-none}" $((vw - 6))))${RST}")")
if [ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_OS" = 1 ]; then
local other_sessions
other_sessions=$(who 2>/dev/null | awk '{print $2}' | sort -u | tr '
' ',' | sed 's/,$//')
LC+=("$(kv Other-sess "$(trunc "${other_sessions:-none}" "$vw")")")
fi
if [ "$OPT_SHOWCASE" = 1 ] && [ "$OPT_SHOWCASE_OG" = 1 ]; then
local other_groups other_user
other_groups=$(who 2>/dev/null | awk -v me="$actual_user" '$1 != me {print $1}' | sort -u | while IFS= read -r other_user; do [ -n "$other_user" ] && id -Gn "$other_user" 2>/dev/null; done | tr ' ' '
' | sort -u | tr '
' ',' | sed 's/,$//')
LC+=("$(kv Other-grp "$(trunc "${other_groups:-none}" "$vw")")")
fi
LC+=("$(kv Time "$(trunc "$(date '+%a %d %b %Y %H:%M:%S %Z')" "$vw")")")
WA=$wa; WB=0; WC=$((IW - 3 - wa))
emit_rows
box_bot
}
build_left() { # width
local w=$1 vw=$(($1 - 10)) model cores ghz usage temp load mp sp
mem_info
model=$(cpu_model); cores=$(ncpu); ghz=$(cpu_ghz); usage=${G_USAGE:-$(cpu_usage)}; temp=$(cpu_temp); load=$(load_avg)
usage=${usage:-0}
LA+=("$(sec CPU "$w")")
LA+=("$(kv Model "$(trunc "$model" "$vw")")")
LA+=("$(kv Cores "${cores} thread$([ "$cores" -gt 1 ] && echo s)${ghz:+ ${DIM}@ ${ghz}${RST}}")")
LA+=("$(kv Usage "$(bar "$usage" $((vw - 5))) $(printf '%3d%%' "$usage")")")
LA+=("$(kv Load "$load")")
if [ -n "$temp" ]; then
local tc=$OK; [ "$temp" -ge 60 ] && tc=$WARN; [ "$temp" -ge 80 ] && tc=$BAD
LA+=("$(kv Temp "${tc}${temp}${DEG}C${RST}")")
fi
LA+=("")
LA+=("$(sec MEMORY "$w")")
mp=0; [ "$MEM_TOTAL" -gt 0 ] && mp=$((MEM_USED * 100 / MEM_TOTAL))
LA+=("$(kv Used "$(hkb "$MEM_USED") / $(hkb "$MEM_TOTAL")")")
LA+=("$(kv "" "$(bar "$mp" $((vw - 5))) $(printf '%3d%%' "$mp")")")
LA+=("$(kv Cache "$(hkb "$MEM_CACHE")")")
if [ "$SWAP_TOTAL" -gt 0 ]; then
sp=$((SWAP_USED * 100 / SWAP_TOTAL))
LA+=("$(kv Swap "$(hkb "$SWAP_USED") / $(hkb "$SWAP_TOTAL")")")
LA+=("$(kv "" "$(bar "$sp" $((vw - 5))) $(printf '%3d%%' "$sp")")")
else
LA+=("$(kv Swap "${DIM}none${RST}")")
fi
}
build_right() { # width
local w=$1 mnt pct size used avail l r gap
LC+=("$(sec STORAGE "$w")")
while IFS='|' read -r mnt pct size used avail; do
[ -z "$mnt" ] && continue
l=$(trunc "$mnt" $((w - 16))); r="$(hkb "$used") / $(hkb "$size")"
gap=$((w - ${#l} - ${#r})); [ "$gap" -lt 1 ] && gap=1
LC+=("$(printf '%s%s%s%*s%s%s%s' "$BOLD" "$l" "$RST" "$gap" "" "$DIM" "$r" "$RST")")
LC+=("$(bar "${pct:-0}" $((w - 5))) $(printf '%3d%%' "${pct:-0}")")
done <<<"${G_DISKS-$(disk_list)}"
LC+=("")
LC+=("$(sec NETWORK "$w")")
net_info
if [ "$OPT_SHOWCASE" = 1 ]; then
LC+=("$(kv Iface "[hidden]")")
if [ "$OPT_SHOWCASE_IIP" = 1 ]; then LC+=("$(kv Internal IPv4 "${NET_IP:-n/a}")")
else LC+=("$(kv Internal IPv4 "[address hidden]")"); fi
if [ "$OPT_SHOWCASE_EIP" = 1 ]; then LC+=("$(kv External IPv4 "$(external_ip)")"); fi
else
LC+=("$(kv Iface "${NET_IF:-n/a}")")
LC+=("$(kv IPv4 "${NET_IP:-n/a}")")
LC+=("$(kv External IPv4 "$(external_ip)")")
fi
if [ -n "$NET_RX" ]; then
local rx tx sfx=""; rx=$(hbytes "$NET_RX"); tx=$(hbytes "$NET_TX")
[ $((${#rx} + ${#tx} + 8 + 11)) -le $((w - 10)) ] && sfx=" ${DIM}since boot${RST}"
LC+=("$(kv Traffic "${OK}${AD}${RST} ${rx}  ${ACC}${AU}${RST} ${tx}${sfx}")")
fi
}
render_hero() {
LA=(); LB=(); LC=(); ROW_MARGIN=''
local gap=3 half i
box_top "HARDWARE"
half=$(((IW - gap) / 2))
if [ "$half" -ge 30 ]; then
build_left "$half"
build_right "$half"
WA=$half; WB=0; WC=$half
emit_rows
else
build_left "$IW"
build_right "$IW"
for ((i = 0; i < ${#LA[@]}; i++)); do box_line "${LA[i]}"; done
for ((i = 0; i < ${#LC[@]}; i++)); do box_line "${LC[i]}"; done
fi
box_bot
}
build_extra() { # container / orchestrator / cron summary (badges + counts)
G_EXTRA=""; G_EXTRA_X=0
local cnt names crons
if have docker; then
names=$(tmo 3 docker ps --format '{{.Names}}' 2>/dev/null | head -n 4 | tr '
' ',' | sed 's/,$//')
[ "$OPT_SHOWCASE" = 1 ] && names="[hidden]"
cnt=$(tmo 3 docker ps -q 2>/dev/null | wc -l | tr -d ' ')
if [ "${cnt:-0}" -gt 0 ]; then icon_of docker; G_EXTRA="$G_EXTRA$ICON ${cnt} containers ($(trunc "$names" 30))   "; G_EXTRA_X=$((G_EXTRA_X + ICON_X)); fi
fi
if have kubectl; then
cnt=$(tmo 3 kubectl get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${cnt:-0}" -gt 0 ]; then icon_of k8s; G_EXTRA="$G_EXTRA$ICON ${cnt} pods   "; G_EXTRA_X=$((G_EXTRA_X + ICON_X)); fi
fi
if have crontab; then
crons=$(crontab -l 2>/dev/null | grep -vE '^\s*(#|$)|# sysdash' | wc -l | tr -d ' ')
if [ "${crons:-0}" -gt 0 ]; then icon_of cron; G_EXTRA="$G_EXTRA$ICON ${crons} cron jobs   "; G_EXTRA_X=$((G_EXTRA_X + ICON_X)); fi
fi
}
render_procs() {
box_top "PROCESSES $SEP TOP BY CPU"
local cmdw=$((IW - 53)) cpu mem pid user args cmd n=0 pc cc head me
me=$(id -un 2>/dev/null || echo "$USER")
[ "$cmdw" -lt 8 ] && cmdw=8
box_line "${DIM}$(printf '%-3s%7s %6s %-6s %5s %-9s %-11s %s' '' PID CPU% '' MEM% USER TYPE COMMAND)${RST}"
while IFS='|' read -r cpu mem pid user args; do
[ -z "$pid" ] && continue
cmd=${args%% *}; cmd=${cmd##*/}
classify "$cmd" "$args"; icon_of "$KIND"
pc=${cpu%.*}; case $pc in ''|*[!0-9]*) pc=0;; esac
cc=$(pctcol "$pc")
if [ "$OPT_SHOWCASE" = 1 ]; then
if [ "$user" = "$me" ]; then [ "$OPT_SHOWCASE_UN" = 1 ] || user="[hidden]"
else [ "$OPT_SHOWCASE_OUN" = 1 ] || user="[hidden]"; fi
args="$cmd"
fi
box_line "$(printf '%s %7s %s%5s%%%s %s %5s %-9s %s%-11s%s %s' "$ICON" "$pid" "$cc" "$cpu" "$RST" \
"$(bar "$pc" 6)" "$mem" "$(trunc "$user" 9)" "$ACC" "$KLBL" "$RST" "$(trunc "$args" "$cmdw")")" "$ICON_X"
n=$((n + 1))
done <<<"${G_PROCS-$(top_procs 8)}"
[ "$n" -eq 0 ] && box_line "${DIM}(process list unavailable on this system)${RST}"
box_sep
head="${DIM}${G_TOTAL} processes${RST}"
strip_ansi "${head}   ${SEP}   ${G_EXTRA}"
if [ -z "$G_EXTRA" ]; then box_line "$head"
elif [ $((${#STRIPPED} + G_EXTRA_X)) -le "$IW" ]; then box_line "${head}   ${SEP}   ${G_EXTRA}" "$G_EXTRA_X"
else box_line "$head"; box_line "$G_EXTRA" "$G_EXTRA_X"; fi
box_bot
}
render_ports() {
box_top "OPEN PORTS"
local rows cw=27 cols cells=() p proto vis proc svc name txt dot i=0 line n total
rows=$(printf '%s
' "$LISTEN_DATA" | awk -F'|' '
NF>=3 { sub(/6$/,"",$1); k=$1"/"$3; if(!(k in seen)){seen[k]=1; order[++n]=k}
if ($2 !~ /^(127\.|::1$|localhost)/) pub[k]=1; if ($4!="" && pr[k]=="") pr[k]=$4 }
END { for(i=1;i<=n;i++){ k=order[i]; split(k,x,"/"); print x[2] "|" x[1] "|" (pub[k]?"public":"local") "|" pr[k] } }' | sort -t'|' -k1,1n)
total=$(printf '%s
' "$rows" | grep -c .)
if [ "$total" -eq 0 ]; then
box_line "${DIM}no listening sockets found (is ss/netstat/lsof installed?)${RST}"
else
cols=$((IW / cw)); [ "$cols" -lt 1 ] && cols=1
while IFS='|' read -r p proto vis proc; do
[ -z "$p" ] && continue
[ "$i" -ge $((cols * 4)) ] && break
svc=$(svc_name "$p"); name=${svc:-${proc:--}}
if [ "$vis" = public ]; then dot="${WARN}${DOT}${RST}"; else dot="${OK}${DOT}${RST}"; fi
if [ "$OPT_SHOWCASE" = 1 ]; then p="[hidden]"; name="service"; fi
txt="$dot $(printf '%-9s' "$p/$proto") ${ACC}$(trunc "$name" 13)${RST}"
cells+=("$(padv "$txt" "$cw")")
i=$((i + 1))
if [ $((i % cols)) -eq 0 ]; then line=""; for c in "${cells[@]}"; do line="$line$c"; done; box_line "$line"; cells=(); fi
done <<<"$rows"
if [ "${#cells[@]}" -gt 0 ]; then line=""; for c in "${cells[@]}"; do line="$line$c"; done; box_line "$line"; fi
n=$((total - i)); [ "$n" -gt 0 ] && box_line "${DIM}… and ${n} more${RST}"
fi
box_sep
box_line "${WARN}${DOT}${RST}${DIM} all interfaces   ${RST}${OK}${DOT}${RST}${DIM} localhost only   (sudo shows process names)${RST}"
box_bot
}
tuptime_lines() {
have tuptime || return 1
local out
out=$(tuptime 2>/dev/null </dev/null | sed "s/${ESC}\[[0-9;]*m//g" | tr '\t' ' ')
if ! printf '%s
' "$out" | grep -q 'uptime'; then
have sudo && sudo -n true 2>/dev/null && out=$(sudo -n tuptime 2>/dev/null </dev/null | sed "s/${ESC}\[[0-9;]*m//g" | tr '\t' ' ')
fi
printf '%s
' "$out" | grep -E '^(System startups|System shutdowns|System uptime|System downtime|System life|Largest uptime|Shortest uptime|Average uptime|Current uptime)' | sed -E 's/[[:space:]]+/ /g'
}
render_uptime() {
box_top "SYSTEM UPTIME $SEP TUPTIME"
LA=(); LB=(); LC=(); ROW_MARGIN=''
local half=$(((IW - 3) / 2)) vw tl line label val i=0 all=()
vw=$((half - 10))
tl=${G_TUP-$(tuptime_lines)}
if [ -n "$tl" ]; then
while IFS= read -r line; do
[ -z "$line" ] && continue
label=${line%%:*}; val=${line#*: }; label=${label#System }; label=${label% uptime}
label="$(printf '%s' "$label" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
all+=("$(kv "$label" "$(trunc "$val" "$vw")")")
done <<<"$tl"
local h=$(((${#all[@]} + 1) / 2))
for ((i = 0; i < ${#all[@]}; i++)); do if [ "$i" -lt "$h" ]; then LA+=("${all[i]}"); else LC+=("${all[i]}"); fi; done
else
local up lr; up=$(uptime_secs)
LA+=("$(kv Up "$(fmt_dur "$up")")")
LA+=("$(kv Booted "$(fmt_epoch $(($(now) - up)))")")
lr=$(last -x reboot 2>/dev/null | grep -c '^reboot')
LC+=("$(kv Reboots "${lr:-0} ${DIM}on record (wtmp)${RST}")")
LC+=("${DIM}$(trunc "tuptime not available — install for history" $((IW - 3 - half)))${RST}")
fi
WA=$half; WB=0; WC=$((IW - 3 - half))
emit_rows
box_bot
}
render_netpower() {
box_top "INTERNET UPTIME $SEP POWER CONTINUITY"
LA=(); LB=(); LC=(); ROW_MARGIN=''
local half=$(((IW - 3) / 2)) vw n_now dur av st lbl pre tot
vw=$((half - 10)); n_now=$(now)
# ---- internet
LA+=("$(sec "INTERNET" "$half")")
if log_stats "$NET_LOG" up down; then
case $S_STATE in
up)   st="${OK}${DOT} ONLINE${RST}";  lbl="Connected";;
down) st="${BAD}${DOT} OFFLINE${RST}"; lbl="Down for";;
*)    st="${WARN}${DOT} PAUSED${RST} ${DIM}(collector idle)${RST}"; lbl="Since";;
esac
dur=$((n_now - S_SINCE)); pre=""; [ "$S_FLOOR" = 1 ] && [ "$S_STATE" = up ] && pre="$GE "
LA+=("$(kv Status "$st")")
LA+=("$(kv "$lbl" "${BOLD}${pre}$(fmt_dur "$dur")${RST}")")
tot=$((S_GOOD + S_BAD))
if [ "$tot" -gt 0 ]; then
av=$(awk -v g="$S_GOOD" -v t="$tot" 'BEGIN{printf "%.2f", g*100/t}')
LA+=("$(kv Uptime "$(bar_good "${av%.*}" $((vw - 8))) ${av}%")")
fi
LA+=("$(kv Monitored "$(fmt_dur $((n_now - S_START)))")")
LA+=("$(kv Outages "${S_OUTS} ${DIM}(longest $(fmt_dur "$S_LONG"))${RST}")")
LA+=("$(kv Probe "${DIM}1.1.1.1 / 8.8.8.8 / 9.9.9.9 every ${INTERVAL}s${RST}")")
else
LA+=("${DIM}no data yet — the background collector starts on first run${RST}")
LA+=("${DIM}(disabled with --no-daemon)${RST}")
fi
# ---- power
LC+=("$(sec "POWER" "$((IW - 3 - half))")")
if log_stats "$PWR_LOG" ac bat; then
battery_info
case $S_STATE in
ac)   st="${OK}${DOT} AC power${RST}";  lbl="On AC";;
bat)  st="${WARN}${DOT} Battery${RST}"; lbl="On batt";;
none) st="${OK}${DOT} Mains${RST} ${DIM}(no battery)${RST}"; lbl="Streak";;
*)    st="${WARN}${DOT} PAUSED${RST} ${DIM}(collector idle)${RST}"; lbl="Since";;
esac
if [ "$S_STATE" = none ]; then dur=$(uptime_secs); pre="$GE "; else dur=$((n_now - S_SINCE)); pre=""; [ "$S_FLOOR" = 1 ] && pre="$GE "; fi
LC+=("$(kv Source "$st")")
LC+=("$(kv "$lbl" "${BOLD}${pre}$(fmt_dur "$dur")${RST}${DIM}$([ "$S_STATE" = none ] && echo ' (since boot)')${RST}")")
if [ -n "$BAT_PCT" ]; then
LC+=("$(kv Battery "$(bar_inv "$BAT_PCT" $((vw - 6))) $(printf '%3d%%' "$BAT_PCT")")")
LC+=("$(kv Status "${BAT_STATUS:-unknown}")")
[ -n "$BAT_ETA" ] && LC+=("$(kv Remaining "$(fmt_dur "$BAT_ETA") ${DIM}$([ "$BAT_STATUS" = Charging ] && echo 'to full' || echo 'left')${RST}")")
LC+=("$(kv Unplugged "${S_OUTS}x ${DIM}(total $(fmt_dur "$S_BAD"))${RST}")")
fi
else
LC+=("${DIM}no data yet${RST}")
fi
WA=$half; WB=0; WC=$((IW - 3 - half))
emit_rows
box_bot
}
bar_inv() { # compatibility alias: positive-quality meter, high = good
bar_good "$@"
}
render_conns() {
box_top "INBOUND CONNECTIONS"
local ports est n=0 p conns peers inet lan loc best origin cmdw
ports=",$(printf '%s
' "$LISTEN_DATA" | awk -F'|' '$1 ~ /^tcp/ {printf "%s,", $3}')"
est=$(printf '%s
' "$G_EST" | awk -v ports="$ports" '
{ if (index(ports, "," $1 ",") == 0) next
p=$1; a=$2; conns[p]++
k=p SUBSEP a
if (!(k in seen)) { seen[k]=1; peers[p]++
if (a ~ /^127\./ || a=="::1") loc[p]++
else if (a ~ /^10\./ || a ~ /^192\.168\./ || a ~ /^172\.(1[6-9]|2[0-9]|3[01])\./ || a ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ || a ~ /^f[cd]/ || a ~ /^fe80/ || a ~ /^169\.254\./) lan[p]++
else net[p]++ }
c[k]++; if (c[k] > bc[p]) { bc[p]=c[k]; best[p]=a }
if (!(p in ord)) { ord[p]=1; pl[++np]=p } }
END { for(i=1;i<=np;i++){ p=pl[i]; print p "|" conns[p] "|" peers[p] "|" net[p]+0 "|" lan[p]+0 "|" loc[p]+0 "|" best[p] } }' |
sort -t'|' -k2,2nr)
cmdw=$((IW - 62)); [ "$cmdw" -lt 6 ] && cmdw=6
if [ -n "$est" ]; then
box_line "${DIM}$(printf '%-3s%-15s %-6s %-10s %-24s %s' '' SERVICE PORT CONNS ORIGIN BUSIEST)${RST}"
while IFS='|' read -r p conns peers inet lan loc best; do
[ -z "$p" ] && continue
port_kind "$p"; icon_of "$KIND"
origin=""
if [ "$OPT_SHOWCASE" = 1 ]; then p="[hidden]"; best="[address hidden]"; origin="[hidden]"; fi
if [ "$OPT_SHOWCASE" != 1 ]; then
[ "$inet" -gt 0 ] && origin="${origin}internet ${inet}"
[ "$lan"  -gt 0 ] && origin="${origin:+$origin $SEP }lan ${lan}"
[ "$loc"  -gt 0 ] && origin="${origin:+$origin $SEP }local ${loc}"
fi
box_line "$(printf '%s %-15s %s%-6s%s %-10s %-24s %s' "$ICON" "$PLBL" "$ACC" ":$p" "$RST" "${conns} conns" "$(trunc "$origin" 24)" "$(trunc "$best" "$cmdw")")" "$ICON_X"
n=$((n + 1)); [ "$n" -ge 7 ] && break
done <<<"$est"
else
box_line "${DIM}no active inbound TCP connections right now${RST}"
fi
box_sep
box_line "${DIM}TCP peers only; UDP services appear under OPEN PORTS.${RST}"
box_bot
}
# ----------------------------------------------------------------------------
#  plugin manager
#  Plugin contract: metadata assignments + sysdash_plugin_<id>() renderer.
#  The optional OS-logo plugin uses fastfetch --logo-only, with neofetch fallback.
#  Renderers receive the panel width and emit content rows using box_line.
#  Privacy contract: showcase mode exports SYSDASH_SHOWCASE=1 plus category
#  allow-list flags (SYSDASH_SHOWCASE_UN/OUN/SN/OSN/G/OG/S/OS/EM/OEM/PN/OPN/EIP/OEIP/IIP) before plugins load.
#  Plugins must hide each category by default and honor its matching allow-list.
# ----------------------------------------------------------------------------
plugin_cache_get() { # cache key, max age seconds; prints cached response when fresh
local key=$1 ttl=$2 file="$SD_DIR/plugin-cache/$1.json" mtime current
[ -s "$file" ] || return 1
mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || return 1
case $mtime in ''|*[!0-9]*) return 1;; esac
current=$(date +%s)
[ "$((current - mtime))" -le "$ttl" ] || return 1
cat "$file"
}
plugin_cache_set() { # cache key; reads response from stdin
local key=$1 dir="$SD_DIR/plugin-cache" tmp
mkdir -p "$dir" || return 1
chmod 700 "$dir" 2>/dev/null || :
tmp=$(mktemp "$dir/$key.XXXXXX") || return 1
cat > "$tmp" || { rm -f "$tmp"; return 1; }
chmod 600 "$tmp" 2>/dev/null || :
mv -f "$tmp" "$dir/$key.json"
}
plugin_order_read() {
ORDER_IDS=()
local id file found checkid
if [ -f "$PLUGIN_ORDER" ]; then
while IFS= read -r id; do
[ -n "$id" ] || continue
[ -f "$PLUGIN_DIR/$id.sh" ] || continue
found=0
for checkid in "${ORDER_IDS[@]}"; do [ "$checkid" = "$id" ] && found=1; done
[ "$found" = 0 ] && ORDER_IDS+=("$id")
done < "$PLUGIN_ORDER"
fi
for file in "$PLUGIN_DIR"/*.sh; do
[ -f "$file" ] || continue
id=${file##*/}; id=${id%.sh}; found=0
for checkid in "${ORDER_IDS[@]}"; do [ "$checkid" = "$id" ] && found=1; done
[ "$found" = 0 ] && ORDER_IDS+=("$id")
done
}
plugin_order_write() {
mkdir -p "$SD_DIR" "$PLUGIN_DIR" 2>/dev/null
: > "$PLUGIN_ORDER" || return 1
local id
for id in "${ORDER_IDS[@]}"; do [ -f "$PLUGIN_DIR/$id.sh" ] && printf '%s
' "$id" >> "$PLUGIN_ORDER"; done
}
plugin_resolve() {
local wanted raw file id name wid wname
wanted=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
RESOLVED_PLUGIN_ID=""
for file in "$PLUGIN_DIR"/*.sh; do
[ -f "$file" ] || continue
id=$(sed -n 's/^SYSDASH_PLUGIN_ID="\([a-zA-Z0-9_-]*\)".*/\1/p' "$file" | head -n 1)
name=$(sed -n 's/^SYSDASH_PLUGIN_NAME="\(.*\)".*/\1/p' "$file" | head -n 1)
wid=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
wname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
if [ "$wanted" = "$wid" ] || [ "$wanted" = "$wname" ]; then RESOLVED_PLUGIN_ID=$id; return 0; fi
done
return 1
}
plugin_fetch() { # URL -> downloaded temporary plugin; only validates metadata/syntax, does not execute it.
local url=$1 tmp normalized id name
case $url in http://*|https://*) ;; *) url="https://$url" ;; esac
case $url in https://*|http://*) ;; *) echo "Invalid plugin URL" >&2; return 2 ;; esac
tmp=$(mktemp "${TMPDIR:-/tmp}/sysdash-plugin.XXXXXX") || return 1
if have curl; then curl -fL --connect-timeout 8 --max-time 45 -sS "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
elif have wget; then wget -q --timeout=15 -O "$tmp" "$url" || { rm -f "$tmp"; return 1; }
else echo "curl or wget is required to install plugins" >&2; rm -f "$tmp"; return 1; fi
# Pastebin and editors on Windows may serve CRLF files. Normalize downloaded
# plugins to Unix LF before parsing, so carriage returns cannot corrupt tokens.
normalized="$tmp.lf"
if ! tr -d '\r' < "$tmp" > "$normalized"; then
echo "Could not normalize plugin line endings" >&2
rm -f "$tmp" "$normalized"
return 1
fi
mv -f "$normalized" "$tmp" || { rm -f "$tmp" "$normalized"; return 1; }
if ! bash -n "$tmp"; then echo "Plugin failed Bash syntax validation" >&2; rm -f "$tmp"; return 1; fi
id=$(sed -n 's/^SYSDASH_PLUGIN_ID="\([a-zA-Z0-9_-]*\)".*/\1/p' "$tmp" | head -n 1)
name=$(sed -n 's/^SYSDASH_PLUGIN_NAME="\(.*\)".*/\1/p' "$tmp" | head -n 1)
case $id in ''|*[!a-zA-Z0-9_-]*) echo "Plugin is missing a valid SYSDASH_PLUGIN_ID" >&2; rm -f "$tmp"; return 1;; esac
[ -n "$name" ] || { echo "Plugin is missing SYSDASH_PLUGIN_NAME" >&2; rm -f "$tmp"; return 1; }
FETCHED_PLUGIN=$tmp
FETCHED_PLUGIN_ID=$id
FETCHED_PLUGIN_NAME=$name
}
plugin_install() {
[ $# -ge 1 ] || { echo "Usage: i URL" >&2; return 2; }
mkdir -p "$PLUGIN_DIR" "$SD_DIR" || return 1
plugin_fetch "$1" || return $?
local id=$FETCHED_PLUGIN_ID name=$FETCHED_PLUGIN_NAME
if [ -f "$PLUGIN_DIR/$id.sh" ]; then
echo "Plugin '$name' is already installed; use --update $id URL" >&2
rm -f "$FETCHED_PLUGIN"; return 1
fi
mv "$FETCHED_PLUGIN" "$PLUGIN_DIR/$id.sh" || return 1
plugin_order_read; plugin_order_write
echo "Installed $name ($id). It is enabled by default."
echo "Review the plugin source before running sysdash: installed plugins execute shell code."
}
plugin_update() {
[ $# -ge 2 ] || { echo "Usage: update NAME URL" >&2; return 2; }
plugin_resolve "$1" || { echo "Plugin not found: $1" >&2; return 1; }
local old=$RESOLVED_PLUGIN_ID
plugin_fetch "$2" || return $?
if [ "$FETCHED_PLUGIN_ID" != "$old" ]; then
echo "Update rejected: downloaded plugin ID '$FETCHED_PLUGIN_ID' does not match '$old'" >&2
rm -f "$FETCHED_PLUGIN"; return 1
fi
mv "$FETCHED_PLUGIN" "$PLUGIN_DIR/$old.sh" || return 1
echo "Updated $FETCHED_PLUGIN_NAME ($old); enabled state and order preserved."
}
plugin_list() {
mkdir -p "$PLUGIN_DIR" "$SD_DIR" 2>/dev/null
plugin_order_read
if [ "${#ORDER_IDS[@]}" -eq 0 ]; then echo "No plugins installed."; return 0; fi
local i id name span state file
i=0
for id in "${ORDER_IDS[@]}"; do
file="$PLUGIN_DIR/$id.sh"
name=$(sed -n 's/^SYSDASH_PLUGIN_NAME="\(.*\)".*/\1/p' "$file" | head -n 1)
span=$(sed -n 's/^SYSDASH_PLUGIN_SPAN="\(.*\)".*/\1/p' "$file" | head -n 1)
[ -n "$span" ] || span=auto
if [ -f "$PLUGIN_DIR/$id.disabled" ]; then state=OFF; else state=ON; fi
i=$((i + 1))
printf '%2d. %-24s %-3s %-5s (%s)
' "$i" "$name" "$state" "$span" "$id"
done
}
plugin_remove() {
[ $# -ge 1 ] || { echo "Usage: rm NAME" >&2; return 2; }
plugin_resolve "$1" || { echo "Plugin not found: $1" >&2; return 1; }
local id=$RESOLVED_PLUGIN_ID
rm -f "$PLUGIN_DIR/$id.sh" "$PLUGIN_DIR/$id.disabled"
plugin_order_read
local -a kept
kept=()
for id in "${ORDER_IDS[@]}"; do [ "$id" = "$RESOLVED_PLUGIN_ID" ] || kept+=("$id"); done
ORDER_IDS=("${kept[@]}"); plugin_order_write
echo "Removed plugin $RESOLVED_PLUGIN_ID."
}
plugin_toggle() {
[ $# -ge 1 ] || { echo "Usage: toggle NAME [on|off]" >&2; return 2; }
plugin_resolve "$1" || { echo "Plugin not found: $1" >&2; return 1; }
local id=$RESOLVED_PLUGIN_ID action=${2:-toggle}
case $action in
on) rm -f "$PLUGIN_DIR/$id.disabled"; echo "$id enabled.";;
off) : > "$PLUGIN_DIR/$id.disabled"; echo "$id disabled.";;
toggle) if [ -f "$PLUGIN_DIR/$id.disabled" ]; then rm -f "$PLUGIN_DIR/$id.disabled"; echo "$id enabled."; else : > "$PLUGIN_DIR/$id.disabled"; echo "$id disabled."; fi;;
*) echo "Expected on or off" >&2; return 2;;
esac
}
plugin_reorder() {
[ $# -ge 2 ] || { echo "Usage: reorder NAME up|down" >&2; return 2; }
plugin_resolve "$1" || { echo "Plugin not found: $1" >&2; return 1; }
local id=$RESOLVED_PLUGIN_ID direction=$2 i j target tmp
case $direction in up) target=-1;; down) target=1;; *) echo "Expected up or down" >&2; return 2;; esac
plugin_order_read
for ((i=0; i<${#ORDER_IDS[@]}; i++)); do [ "${ORDER_IDS[i]}" = "$id" ] && break; done
[ "$i" -lt "${#ORDER_IDS[@]}" ] || return 1
j=$((i + target)); [ "$j" -ge 0 ] && [ "$j" -lt "${#ORDER_IDS[@]}" ] || { echo "Already at that end of the order."; return 0; }
tmp=${ORDER_IDS[i]}; ORDER_IDS[i]=${ORDER_IDS[j]}; ORDER_IDS[j]=$tmp
plugin_order_write; echo "Moved $id $direction."
}
plugin_swap() {
[ $# -ge 2 ] || { echo "Usage: swap NAME NAME" >&2; return 2; }
plugin_resolve "$1" || { echo "Plugin not found: $1" >&2; return 1; }; local a=$RESOLVED_PLUGIN_ID
plugin_resolve "$2" || { echo "Plugin not found: $2" >&2; return 1; }; local b=$RESOLVED_PLUGIN_ID
plugin_order_read; local i j tmp
for ((i=0; i<${#ORDER_IDS[@]}; i++)); do [ "${ORDER_IDS[i]}" = "$a" ] && break; done
for ((j=0; j<${#ORDER_IDS[@]}; j++)); do [ "${ORDER_IDS[j]}" = "$b" ] && break; done
[ "$i" -lt "${#ORDER_IDS[@]}" ] && [ "$j" -lt "${#ORDER_IDS[@]}" ] || return 1
tmp=${ORDER_IDS[i]}; ORDER_IDS[i]=${ORDER_IDS[j]}; ORDER_IDS[j]=$tmp
plugin_order_write; echo "Swapped $a and $b."
}
load_plugins() {
mkdir -p "$PLUGIN_DIR" "$SD_DIR" 2>/dev/null
plugin_order_read
PLUGIN_IDS=(); PLUGIN_NAMES=(); PLUGIN_SPANS=(); PLUGIN_FPS=(); PLUGIN_FULL_IDS=(); PLUGIN_FULL_NAMES=(); PLUGIN_FULL_FPS=()
ANIM_COUNT=0
local id file name span fn fps
for id in "${ORDER_IDS[@]}"; do
[ -f "$PLUGIN_DIR/$id.disabled" ] && continue
file="$PLUGIN_DIR/$id.sh"
SYSDASH_PLUGIN_ID=""; SYSDASH_PLUGIN_NAME=""; SYSDASH_PLUGIN_SPAN="auto"; SYSDASH_PLUGIN_FPS=""
# Plugins are trusted local shell code; installation validates syntax, not safety.
. "$file" || { echo "Warning: failed to load plugin $id" >&2; continue; }
id=${SYSDASH_PLUGIN_ID:-$id}; name=${SYSDASH_PLUGIN_NAME:-$id}; span=${SYSDASH_PLUGIN_SPAN:-auto}
case $id in ''|*[!a-zA-Z0-9_-]*) continue;; esac
case $span in full|half|auto) ;; *) span=auto;; esac
fn="sysdash_plugin_$id"
declare -f "$fn" >/dev/null 2>&1 || declare -f "${fn}_frame" >/dev/null 2>&1 || { echo "Warning: plugin $id has no $fn renderer" >&2; continue; }
# Animation API: SYSDASH_PLUGIN_FPS (1-30) + sysdash_plugin_<id>_frame(); ignored when either is missing.
fps=${SYSDASH_PLUGIN_FPS:-0}
case $fps in ''|*[!0-9]*) fps=0;; esac
[ "$fps" -gt 30 ] && fps=30
declare -f "${fn}_frame" >/dev/null 2>&1 || fps=0
[ "$fps" -gt 0 ] && ANIM_COUNT=$((ANIM_COUNT + 1))
PLUGIN_IDS+=("$id"); PLUGIN_NAMES+=("$name"); PLUGIN_SPANS+=("$span"); PLUGIN_FPS+=("$fps")
done
}
render_plugin_panel() { # plugin id, width, display name
local id=$1 width=$2 name=$3 fn="sysdash_plugin_$1"
set_width "$width"
box_top "$name"
if declare -f "$fn" >/dev/null 2>&1; then "$fn" "$width"; else "${fn}_frame" "$width" 0 0; fi
box_bot
}
ANIM_PANELS=()
anim_register() { # id row col width panel-lines fps  -> remembered so live mode can redraw it in place
[ "${6:-0}" -gt 0 ] 2>/dev/null && ANIM_PANELS+=("$1|$2|$3|$4|$5|$6")
return 0
}
plugin_capture_panel() { # id width name -> global PANEL_LINES[]
local rendered line
rendered=$(render_plugin_panel "$1" "$2" "$3") || return 1
PANEL_LINES=()
while IFS= read -r line; do PANEL_LINES+=("$line"); done <<EOF_PANEL
$rendered
EOF_PANEL
}
plugin_col_height() {
case $1 in
0) echo "${#C0[@]}";;
1) echo "${#C1[@]}";;
2) echo "${#C2[@]}";;
*) echo 0;;
esac
}
plugin_pad_col() {
local col=$1 target=$2
case $col in
0) while [ "${#C0[@]}" -lt "$target" ]; do C0+=(""); done;;
1) while [ "${#C1[@]}" -lt "$target" ]; do C1+=(""); done;;
2) while [ "${#C2[@]}" -lt "$target" ]; do C2+=(""); done;;
esac
}
plugin_append_col() {
case $1 in 0) C0+=("$2");; 1) C1+=("$2");; 2) C2+=("$2");; esac
}
plugin_append_panel() { # column index, start row; uses PANEL_LINES[]
local col=$1 start=$2 line
plugin_pad_col "$col" "$start"
for line in "${PANEL_LINES[@]}"; do plugin_append_col "$col" "$line"; done
}
plugin_find_short_columns() { # dashboard column count -> PLUGIN_COL_A / PLUGIN_COL_B
local count=$1 c h best=999999 second=999999
PLUGIN_COL_A=0; PLUGIN_COL_B=1
for ((c=0; c<count; c++)); do
h=$(plugin_col_height "$c")
if [ "$h" -lt "$best" ]; then
second=$best; PLUGIN_COL_B=$PLUGIN_COL_A
best=$h; PLUGIN_COL_A=$c
elif [ "$h" -lt "$second" ]; then
second=$h; PLUGIN_COL_B=$c
fi
done
}
render_plugin_panels() { # dashboard column count, one dashboard column width
    [ "${#PLUGIN_IDS[@]}" -gt 0 ] || { PLUGIN_FULL_IDS=(); PLUGIN_FULL_NAMES=(); PLUGIN_FULL_FPS=(); return 0; }
    local dashboard_cols=$1 col_width=$2 pgap=${3:-2} i span next_span pair start h1 h2 hmin hmax c id name
    PLUGIN_FULL_IDS=(); PLUGIN_FULL_NAMES=(); PLUGIN_FULL_FPS=()
    i=0
    while [ "$i" -lt "${#PLUGIN_IDS[@]}" ]; do
        id=${PLUGIN_IDS[i]}; name=${PLUGIN_NAMES[i]}; span=${PLUGIN_SPANS[i]}
        next_span=""
        [ "$((i + 1))" -lt "${#PLUGIN_IDS[@]}" ] && next_span=${PLUGIN_SPANS[$((i + 1))]}
        pair=0
        if [ "$dashboard_cols" -ge 2 ] && [ "$i" -lt "$(( ${#PLUGIN_IDS[@]} - 1 ))" ]; then
            case $span:$next_span in half:half|half:auto|auto:half|auto:auto) pair=1;; esac
        fi
        if [ "$span" = full ] || [ "$dashboard_cols" -lt 2 ]; then
            PLUGIN_FULL_IDS+=("$id"); PLUGIN_FULL_NAMES+=("$name"); PLUGIN_FULL_FPS+=("${PLUGIN_FPS[i]:-0}")
            i=$((i + 1)); continue
        fi
        # --- NEW LOGIC: Always place in the shortest column to allow stacking ---
        plugin_find_short_columns "$dashboard_cols"
        h1=$(plugin_col_height "$PLUGIN_COL_A")
        plugin_capture_panel "$id" "$col_width" "$name" || { i=$((i + 1)); continue; }
        plugin_append_panel "$PLUGIN_COL_A" "$h1"
        anim_register "$id" "$h1" "$((PLUGIN_COL_A * (col_width + pgap) + 1))" "$col_width" "${#PANEL_LINES[@]}" "${PLUGIN_FPS[i]:-0}"
        i=$((i + 1))
        # -----------------------------------------------------------------------
    done
}
render_full_plugin_panels() { # width, first screen row (0-based) of the full-width area
local i row=${2:-0}
[ "${#PLUGIN_FULL_IDS[@]}" -gt 0 ] || return 0
set_width "$1"
for ((i=0; i<${#PLUGIN_FULL_IDS[@]}; i++)); do
plugin_capture_panel "${PLUGIN_FULL_IDS[i]}" "$1" "${PLUGIN_FULL_NAMES[i]}" || continue
printf '%s\n' "${PANEL_LINES[@]}"
anim_register "${PLUGIN_FULL_IDS[i]}" "$row" 1 "$1" "${#PANEL_LINES[@]}" "${PLUGIN_FULL_FPS[i]:-0}"
row=$((row + ${#PANEL_LINES[@]}))
done
}
render_footer() {
local cs
if collector_running; then cs="${OK}collector running${RST}"; else cs="${WARN}collector off${RST}"; fi
local privacy_hint=""
[ "$OPT_SHOWCASE" = 1 ] && privacy_hint="  ${SEP}  SHOWCASE: sensitive values hidden"
printf '  %s%s %s %s%s %s %s%s%s
' "$DIM" "sysdash v$SD_VERSION" "$SEP" "$(date '+%H:%M:%S')" "$RST" "$SEP" "$cs" "$DIM" "  ${SEP}  watch · help${privacy_hint}${RST}"
}
render_section() { # name width
set_width "$2"
case $1 in
header) render_header;; hero) render_hero;; procs) render_procs;; ports) render_ports;;
uptime) render_uptime;; netpower) render_netpower;; conns) render_conns;;
esac
}
prepare_data() { # collect everything once, so each layout pass only has to draw
G_USAGE=$(cpu_usage); G_PROCS=$(top_procs 8); G_DISKS=$(disk_list)
LISTEN_DATA=$(get_listeners); G_EST=$(get_established); G_TUP=$(tuptime_lines)
G_TOTAL=$(ps -e 2>/dev/null | wc -l | tr -d ' '); G_TOTAL=$((G_TOTAL > 0 ? G_TOTAL - 1 : 0))
mem_info; net_info; sample_history
build_extra
}
hsum() { local s=0 x; for ((x = $1; x < $2; x++)); do s=$((s + HT[x])); done; echo "$s"; }
partition() { # k n  (uses HT[]) -> GRP[] (column of each section, order kept) and PMAX
local k=$1 n=$2 i j a b c m best=999999 s1=0 s2=0
GRP=()
case $k in
1) PMAX=$(hsum 0 "$n"); for ((i = 0; i < n; i++)); do GRP[i]=0; done;;
2) for ((i = 1; i < n; i++)); do
a=$(hsum 0 $i); b=$(hsum $i "$n"); m=$((a > b ? a : b))
[ "$m" -lt "$best" ] && { best=$m; s1=$i; }
done
PMAX=$best; for ((i = 0; i < n; i++)); do if [ "$i" -lt "$s1" ]; then GRP[i]=0; else GRP[i]=1; fi; done;;
3) for ((i = 1; i < n - 1; i++)); do for ((j = i + 1; j < n; j++)); do
a=$(hsum 0 $i); b=$(hsum $i $j); c=$(hsum j "$n"); m=$((a > b ? a : b)); m=$((m > c ? m : c))
[ "$m" -lt "$best" ] && { best=$m; s1=$i; s2=$j; }
done; done
PMAX=$best
for ((i = 0; i < n; i++)); do if [ "$i" -lt "$s1" ]; then GRP[i]=0; elif [ "$i" -lt "$s2" ]; then GRP[i]=1; else GRP[i]=2; fi; done;;
esac
}
render_all() {
ANIM_PANELS=()
setup_term
prepare_data
local names=(header hero procs ports uptime netpower conns) n=7 gap=2 avail=$COLS
local kmax kmin k cw i idx chosen=0 best_k=1 best_max=999999 line blank gapstr text g r rows art_idx art_line
local -a OUT CW GRPS C0 C1 C2 G
kmax=$(((avail + gap) / (72 + gap))); [ "$kmax" -lt 1 ] && kmax=1; [ "$kmax" -gt 3 ] && kmax=3
kmin=1; [ "$avail" -ge 150 ] && kmin=2; [ "$kmin" -gt "$kmax" ] && kmin=$kmax
for ((k = kmin; k <= kmax; k++)); do                 # fewest columns that fit the window height
cw=$(((avail - (k - 1) * gap) / k)); [ "$cw" -gt 140 ] && cw=140
HT=()
for ((i = 0; i < n; i++)); do
idx=$(((k - 1) * n + i))
OUT[idx]=$(render_section "${names[i]}" "$cw")
HT[i]=$(printf '%s
' "${OUT[idx]}" | wc -l | tr -d ' ')
done
partition "$k" "$n"
CW[k]=$cw; GRPS[k]="${GRP[*]}"
if [ "$PMAX" -le $((TERM_ROWS - 2)) ]; then chosen=$k; break; fi
if [ "$PMAX" -lt "$best_max" ]; then best_max=$PMAX; best_k=$k; fi
done
[ "$chosen" -eq 0 ] && chosen=$best_k
k=$chosen; cw=${CW[k]}; read -ra G <<<"${GRPS[k]}"
for ((i = 0; i < n; i++)); do
text=${OUT[$(((k - 1) * n + i))]}
while IFS= read -r line; do
case ${G[i]} in 0) C0+=("$line");; 1) C1+=("$line");; 2) C2+=("$line");; esac
done <<<"$text"
done
# Fill the entire remaining lower-left sector, matching the tallest right column.
rows=${#C0[@]}; [ "${#C1[@]}" -gt "$rows" ] && rows=${#C1[@]}; [ "${#C2[@]}" -gt "$rows" ] && rows=${#C2[@]}
set_width "$cw"
local graph_text graph_height right_rows
right_rows=${#C1[@]}; [ "${#C2[@]}" -gt "$right_rows" ] && right_rows=${#C2[@]}
graph_height=$((right_rows - ${#C0[@]}))
[ "$graph_height" -lt 8 ] && graph_height=8
graph_text=$(render_graphs "$cw" "$graph_height")
while IFS= read -r line; do C0+=("$line"); done <<<"$graph_text"
# Place half-width plugin panels in the shortest dashboard columns before
# calculating the logo position. Full-width panels are queued for below.
render_plugin_panels "$k" "$cw" "$gap"
rows=${#C0[@]}; [ "${#C1[@]}" -gt "$rows" ] && rows=${#C1[@]}; [ "${#C2[@]}" -gt "$rows" ] && rows=${#C2[@]}
blank=$(rep ' ' "$cw"); gapstr=$(rep ' ' "$gap")
for ((r = 0; r < rows; r++)); do
line="${C0[r]:-$blank}"
[ "$k" -ge 2 ] && line="$line$gapstr${C1[r]:-$blank}"
[ "$k" -ge 3 ] && line="$line$gapstr${C2[r]:-$blank}"
printf '%s
' "$line"
done
render_full_plugin_panels "$avail" "$rows"
render_footer
}
# ----------------------------------------------------------------------------
#  main
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
#  live animation engine (plugins with SYSDASH_PLUGIN_FPS, up to 30 fps)
#  A background renderer builds the whole dashboard (slow: it gathers data) and
#  publishes it to a temp dir. The foreground loop paints the newest frame and
#  redraws only the animated panels, in place, at their own frame rate, so an
#  animation never has to wait for data collection.
# ----------------------------------------------------------------------------
now_ms() { # -> NOW_MS (no fork on bash 5)
local t s
if [ -n "${EPOCHREALTIME:-}" ]; then t=${EPOCHREALTIME//[.,]/}; NOW_MS=$((t / 1000))
else
s=$(date +%s%N 2>/dev/null)
case $s in ''|*[!0-9]*) NOW_MS=$(( $(date +%s) * 1000 ));; *) NOW_MS=$((s / 1000000));; esac
fi
}
NAP_FD=""
sleep_ms() { # builtin timed read on a never-written fifo (no fork) when available, else sleep
local s; [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
printf -v s '%d.%03d' $(($1 / 1000)) $(($1 % 1000))
if [ -n "$NAP_FD" ]; then read -r -t "$s" -u "$NAP_FD" s || :; else sleep "$s"; fi
}
live_renderer() { # dir  (background process: full dashboard every 0.5 s)
local dir=$1 seq=0 t0 p nl
SD_LIVE_BG=1
# data gathering must never steal CPU from the animation (matters on 1-core hosts)
[ -n "${BASHPID:-}" ] && have renice && renice -n 10 -p "$BASHPID" >/dev/null 2>&1
while :; do
now_ms; t0=$NOW_MS
render_all >"$dir/frame.tmp" 2>/dev/null
nl=$(wc -l <"$dir/frame.tmp" 2>/dev/null); nl=${nl//[!0-9]/}
{ printf '%s %s %s\n' "${TERM_ROWS:-0}" "${TERM_COLS:-0}" "${nl:-0}"; for p in "${ANIM_PANELS[@]}"; do printf '%s\n' "$p"; done; } >"$dir/layout.tmp"
mv -f "$dir/frame.tmp" "$dir/frame" && mv -f "$dir/layout.tmp" "$dir/layout"
seq=$((seq + 1)); printf '%s\n' "$seq" >"$dir/seq.tmp" && mv -f "$dir/seq.tmp" "$dir/seq"
now_ms; sleep_ms $((500 - (NOW_MS - t0)))
done
}
LV_ID=(); LV_ROW=(); LV_COL=(); LV_W=(); LV_H=(); LV_FPS=(); LV_NEXT=(); LV_FN=()
LV_STATIC=""; LV_ROWS=0; LV_COLS=0; LV_OFF=0; LV_T0=0; LIVE_OUT=""; LIVE_BG=""; LIVE_DIR=""
live_load_layout() { # dir -> LV_* (static frame + animated panel table)
local dir=$1 line first=1 id row col w h fps n j nl=0
local -a old_id old_fn
[ -s "$dir/frame" ] && [ -s "$dir/layout" ] || return 1
old_id=("${LV_ID[@]}"); old_fn=("${LV_FN[@]}")
LV_ID=(); LV_ROW=(); LV_COL=(); LV_W=(); LV_H=(); LV_FPS=(); LV_NEXT=(); LV_FN=()
while IFS= read -r line; do
if [ "$first" = 1 ]; then read -r LV_ROWS LV_COLS nl <<<"$line"; first=0; continue; fi
[ -n "$line" ] || continue
IFS='|' read -r id row col w h fps <<<"$line"
n=0
for ((j = 0; j < ${#old_id[@]}; j++)); do [ "${old_id[j]}" = "$id" ] && { n=${old_fn[j]}; break; }; done
LV_ID+=("$id"); LV_ROW+=("$row"); LV_COL+=("$col"); LV_W+=("$w"); LV_H+=("$h"); LV_FPS+=("$fps"); LV_NEXT+=(0); LV_FN+=("$n")
done <"$dir/layout"
LV_STATIC=$(<"$dir/frame")
LV_OFF=$((nl - LV_ROWS)); [ "$LV_OFF" -lt 0 ] && LV_OFF=0     # a frame taller than the window scrolls
return 0
}
live_draw_panel() { # index elapsed-ms -> appends cursor-addressed rows to LIVE_OUT
local i=$1 ms=$2 id w row col h text line k=0 r
id=${LV_ID[i]}; w=${LV_W[i]}; row=${LV_ROW[i]}; col=${LV_COL[i]}; h=${LV_H[i]}
text=$(set_width "$w"; "sysdash_plugin_${id}_frame" "$w" "${LV_FN[i]}" "$ms" 2>/dev/null) || return 0
while IFS= read -r line; do
[ "$k" -lt $((h - 2)) ] || break                 # content rows only; the box stays untouched
r=$((row + k + 2 - LV_OFF)); k=$((k + 1))
[ "$r" -ge 1 ] && [ "$r" -le "$LV_ROWS" ] && LIVE_OUT+=$'\033['"${r};${col}H${line}"
done <<<"$text"
}
live_stop() {
[ -n "${LIVE_BG:-}" ] && kill "$LIVE_BG" 2>/dev/null
[ -n "${LIVE_DIR:-}" ] && rm -rf "$LIVE_DIR"
printf '\033[?7h\033[?25h\033[?1049l'
}
live_anim_loop() {
local dir last_seq="" seq i period n wake d ms redraw started=0
dir=$(mktemp -d "${TMPDIR:-/tmp}/sysdash-live.XXXXXX") || return 1
LIVE_DIR=$dir
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ] && mkfifo "$dir/nap" 2>/dev/null && exec 9<>"$dir/nap"; then NAP_FD=9; fi
exec 3<&0                                         # keep the tty on stdin for the renderer's Session row
live_renderer "$dir" <&3 3<&- &
LIVE_BG=$!
exec 3<&-
trap 'exit 0' INT TERM HUP
trap live_stop EXIT
now_ms; LV_T0=$NOW_MS
while :; do
redraw=0
read -r seq 2>/dev/null <"$dir/seq"
if [ -n "$seq" ] && [ "$seq" != "$last_seq" ] && live_load_layout "$dir"; then last_seq=$seq; redraw=1; started=1; fi
[ "$started" = 1 ] || { sleep 0.05; continue; }
now_ms; ms=$((NOW_MS - LV_T0)); wake=$((NOW_MS + 50)); LIVE_OUT=""
[ "$redraw" = 1 ] && LIVE_OUT=$'\033[H'"$LV_STATIC"$'\033[J'
for ((i = 0; i < ${#LV_ID[@]}; i++)); do
if [ "$redraw" = 1 ] || [ "$NOW_MS" -ge "${LV_NEXT[i]}" ]; then
live_draw_panel "$i" "$ms"
period=$((1000 / LV_FPS[i]))
n=$((LV_NEXT[i] + period)); [ "$n" -le "$NOW_MS" ] && n=$((NOW_MS + period))
LV_NEXT[i]=$n; LV_FN[i]=$((LV_FN[i] + 1))
fi
[ "${LV_NEXT[i]}" -lt "$wake" ] && wake=${LV_NEXT[i]}
done
[ -n "$LIVE_OUT" ] && printf '%s' "$LIVE_OUT"
now_ms; d=$((wake - NOW_MS)); sleep_ms "$d"
done
}
plugin_command_help() {
case "$1" in
i|install|--install) echo "Usage: sysdash install URL"; echo "Downloads and installs a plugin from a raw HTTP(S) URL.";;
list|--list) echo "Usage: sysdash list"; echo "Lists installed plugins, order, span, and enabled state.";;
rm|remove|--rm) echo "Usage: sysdash rm NAME"; echo "Removes an installed plugin and its enabled-state marker.";;
toggle|--toggle) echo "Usage: sysdash toggle NAME [on|off]"; echo "Enables, disables, or toggles an installed plugin.";;
reorder|--reorder) echo "Usage: sysdash reorder NAME up|down"; echo "Moves a plugin one position in display order.";;
swap|--swap) echo "Usage: sysdash swap NAME NAME"; echo "Swaps the positions of two installed plugins.";;
update|upd|--update) echo "Usage: sysdash update NAME URL   (shorthand: sysdash upd NAME URL)"; echo "Replaces a plugin from a raw URL while preserving its ID, order, and state.";;
keys|kyes|key|--keys) echo "Usage: sysdash keys [list|set KEY VALUE|get KEY|unset KEY]"; echo "  sysdash keys            list the names of your stored keys (one per line; values are never shown)"; echo "  sysdash keys set K V    store or replace a key      sysdash keys get K    print a key's value"; echo "  sysdash keys unset K    remove a key"; echo "Keys are stored with mode 600 in $KEYS_FILE and exported to plugins as environment variables."; echo "'kyes' is accepted as an alias for 'keys'.";;
showcase|--showcase) echo "Usage: sysdash showcase [FLAGS|default] [live|watch [N]]"; echo "Hides sensitive values for screenshots. Everything is hidden unless you allow it with a flag:"; echo "  un/oun=usernames (self/others)   sn/osn=system names   g/og=groups   s/os=sessions"; echo "  em/oem=email   pn/opn=phone   eip/oeip=external IP   iip=internal IPs"; echo "  default          shorthand for: sn osn g og pn opn oeip iip"; echo "Example: sysdash showcase default live";;
default|--default) echo "Usage: sysdash showcase default [live]"; echo "Shorthand for: sysdash showcase sn osn g og pn opn oeip iip";;
live|--live) echo "Usage: sysdash live"; echo "Refreshes dashboard data every 0.5 seconds. Plugins that declare SYSDASH_PLUGIN_FPS are"; echo "redrawn in place at up to 30 fps between data refreshes (see: sysdash help api).";;
api|plugin|plugins|--api) cat <<'APIHELP'
Plugin API
  Metadata   SYSDASH_PLUGIN_ID="id"  SYSDASH_PLUGIN_NAME="Name"  SYSDASH_PLUGIN_SPAN="auto|half|full"
  Renderer   sysdash_plugin_<id> WIDTH   print the panel's content rows with box_line

  Animation (live mode only, up to 30 fps)
    SYSDASH_PLUGIN_FPS="30"            requested frame rate, 1-30 (higher values are capped at 30)
    sysdash_plugin_<id>_frame W N MS   draw ONE frame: print content rows with box_line
                                       (no box_top/box_bot)
                                         W  = panel width
                                         N  = frame counter (0 = static snapshot)
                                         MS = milliseconds since live mode started
    - Keep the number of rows constant; rows are redrawn in place.
    - If sysdash_plugin_<id> is missing, the _frame function is used (N=0) for static views.
    - Use MS (not N) for motion so speed stays constant if frames are dropped.
    - Frames run in a subshell each time: avoid network calls and long pipelines.
    - SYSDASH_LIVE=1 is exported to plugins in live mode.
APIHELP
;;
watch|--watch) echo "Usage: sysdash watch [SECONDS]"; echo "Refreshes the dashboard at the requested interval (default 5 seconds).";;
no-install|--no-install) echo "Usage: sysdash no-install"; echo "Prevents automatic installation of missing dependencies.";;
no-daemon|--no-daemon) echo "Usage: sysdash no-daemon"; echo "Does not start or install the background collector.";;
uninstall|--uninstall) echo "Usage: sysdash uninstall"; echo "Stops and removes the sysdash background collector and its history.";;
*) usage;;
esac
}
main() {
# Friendly command names: both bare words and legacy --options are accepted.
if [ $# -gt 0 ]; then
if [ "$1" = help ] || [ "$1" = --help ] || [ "$1" = -h ]; then
if [ $# -ge 2 ]; then plugin_command_help "$2"; else usage; fi
exit 0
fi
if [ "${2:-}" = help ] || [ "${2:-}" = --help ] || [ "${2:-}" = -h ]; then plugin_command_help "$1"; exit 0; fi
case "$1" in
keys|kyes|key|--keys)
shift
case "${1:-}" in
set) keys_set "$2" "$3"; exit $?;;
get) keys_get "$2"; exit $?;;
unset) keys_unset "$2"; exit $?;;
list|"") keys_list; exit $?;;
*) echo "Usage: sysdash keys [list|set KEY VALUE|get KEY|unset KEY]" >&2; exit 2;;
esac
;;
i|install|--install) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help install; exit 0; fi; shift; plugin_install "$@"; exit $?;;
list|--list) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help list; exit 0; fi; plugin_list; exit $?;;
rm|remove|--rm) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help rm; exit 0; fi; shift; plugin_remove "$@"; exit $?;;
toggle|--toggle) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help toggle; exit 0; fi; shift; plugin_toggle "$@"; exit $?;;
reorder|--reorder) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help reorder; exit 0; fi; shift; plugin_reorder "$@"; exit $?;;
swap|--swap) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help swap; exit 0; fi; shift; plugin_swap "$@"; exit $?;;
update|upd|--update) if [ "${2:-}" = help ] || [ "${2:-}" = --help ]; then plugin_command_help update; exit 0; fi; shift; plugin_update "$@"; exit $?;;
esac
fi
while [ $# -gt 0 ]; do
case $1 in
showcase|--showcase) OPT_SHOWCASE=1 ;;
un) [ "$OPT_SHOWCASE" = 1 ] || { echo "'un' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_UN=1;;
oun) [ "$OPT_SHOWCASE" = 1 ] || { echo "'oun' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OUN=1;;
sn) [ "$OPT_SHOWCASE" = 1 ] || { echo "'sn' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_SN=1;;
osn) [ "$OPT_SHOWCASE" = 1 ] || { echo "'osn' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OSN=1;;
g) [ "$OPT_SHOWCASE" = 1 ] || { echo "'g' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_G=1;;
og) [ "$OPT_SHOWCASE" = 1 ] || { echo "'og' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OG=1;;
s) [ "$OPT_SHOWCASE" = 1 ] || { echo "'s' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_S=1;;
os) [ "$OPT_SHOWCASE" = 1 ] || { echo "'os' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OS=1;;
em) [ "$OPT_SHOWCASE" = 1 ] || { echo "'em' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_EM=1;;
oem) [ "$OPT_SHOWCASE" = 1 ] || { echo "'oem' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OEM=1;;
pn) [ "$OPT_SHOWCASE" = 1 ] || { echo "'pn' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_PN=1;;
opn) [ "$OPT_SHOWCASE" = 1 ] || { echo "'opn' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OPN=1;;
eip) [ "$OPT_SHOWCASE" = 1 ] || { echo "'eip' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_EIP=1;;
oeip) [ "$OPT_SHOWCASE" = 1 ] || { echo "'oeip' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_OEIP=1;;
iip) [ "$OPT_SHOWCASE" = 1 ] || { echo "'iip' must follow showcase" >&2; exit 2; }; OPT_SHOWCASE_IIP=1;;
default) [ "$OPT_SHOWCASE" = 1 ] || { echo "'default' must follow showcase" >&2; exit 2; }
OPT_SHOWCASE_SN=1; OPT_SHOWCASE_OSN=1; OPT_SHOWCASE_G=1; OPT_SHOWCASE_OG=1
OPT_SHOWCASE_PN=1; OPT_SHOWCASE_OPN=1; OPT_SHOWCASE_OEIP=1; OPT_SHOWCASE_IIP=1;;
no-install|--no-install) OPT_INSTALL=0 ;;
no-daemon|--no-daemon) OPT_DAEMON=0 ;;
watch|-w|--watch) OPT_WATCH=1; if [[ ${2:-} =~ ^[0-9]+([.][0-9]+)?$ ]]; then WATCH_SECS=$2; shift; fi ;;
live|--live) OPT_WATCH=1; OPT_LIVE=1; WATCH_SECS=0.5 ;;
collect|--collect) collector_loop; exit 0;;
ensure|--ensure) mkdir -p "$SD_DIR"; collector_running || start_collector; exit 0;;
uninstall|--uninstall) uninstall; exit 0;;
help|-h|--help) usage; exit 0;;
*) echo "unknown command: $1 (try help)" >&2; exit 2 ;;
esac
shift
done
export_showcase_flags
export SYSDASH_LIVE="$OPT_LIVE"
mkdir -p "$SD_DIR" 2>/dev/null
setup_style
[ "$OPT_INSTALL" = 1 ] && ensure_deps
[ "$OPT_DAEMON"  = 1 ] && ensure_collector
load_keys
load_plugins
if [ "$OPT_WATCH" = 1 ]; then
printf '\033[?1049h\033[?25l\033[?7l'      # alt screen, hide cursor, no line-wrap
if [ "$OPT_LIVE" = 1 ] && [ "$ANIM_COUNT" -gt 0 ] && live_anim_loop; then exit 0; fi   # animated plugins present
trap 'exit 0' INT TERM HUP
trap live_stop EXIT
local frame
while :; do
local frame_start frame_elapsed frame_wait
frame_start=$(date +%s%N 2>/dev/null)
frame=$(render_all)
printf '\033[H%s
\033[J' "$frame"
if [ "$OPT_LIVE" = 1 ] && [[ "$frame_start" =~ ^[0-9]+$ ]]; then
frame_elapsed=$(awk -v a="$frame_start" -v b="$(date +%s%N)" 'BEGIN{printf "%.3f",(b-a)/1000000000}')
frame_wait=$(awk -v e="$frame_elapsed" 'BEGIN{r=0.5-e; if(r>0) printf "%.3f",r; else print "0"}')
[ "$frame_wait" != 0 ] && sleep "$frame_wait"
else
sleep "$WATCH_SECS"
fi
done
else
render_all
fi
}
main "$@"