#!/bin/sh

#  _________   _________   _________
# |         | |         | |         |
# |   six   | |    2    | |   one   |
# |_________| |_________| |_________|
#     |||         |||         |||
# -----------------------------------
#       ifspeedtest.sh v3.42.0
# -----------------------------------

# Cross-platform network quality tester (macOS, Debian/Ubuntu, OpenWrt)
#
# Purpose:
#   Run a quick, repeatable (“synthetic”) check of end-to-end link quality and compare routes/targets.
#
# What it measures:
#   - Throughput (upload/download) via iperf3
#   - Latency / loss / jitter / hops via mtr (optional; ICMP/UDP/TCP probes)
#
# Key features:
#   - Test a single target (-i) or a list of targets (--ips <file>)
#   - Produces a per-target summary and a Scorecard (best upload/download, lowest latency, min hops)
#   - Optional interface binding, logging, and missing-tool auto-install (brew/apt/opkg where available)

# Author: https://github.com/russellgrapes/








# ----------------------------
# Defaults (can be overridden via env vars)
# ----------------------------
MTR_COUNT="${MTR_COUNT:-10}"                   # Total probe count per mtr run (-c). Higher = more stable stats, slower.
MTR_PROBE="${MTR_PROBE:-icmp}"                 # Probe mode: icmp|udp|tcp (tcp helps on networks that block ICMP)
MTR_INTERVAL="${MTR_INTERVAL:-1}"              # Seconds between probes (-i). Lower = faster, higher = gentler.
MTR_LOAD_COUNT="${MTR_LOAD_COUNT:-}"           # Probes during iperf3 load run (-c for the under-load mtr).
                                               #  ↳ If empty, auto-derives as floor(IPERF3_TIME / MTR_INTERVAL).
MTR_PORT="${MTR_PORT:-}"                       # Destination port for tcp/udp probes (-P).
                                               #  ↳ If empty and MTR_PROBE=tcp, defaults to 443. (UDP may default per mtr build.)
IPERF3_PORTS="${IPERF3_PORTS:-}"               # iperf3 server port or port range (e.g., 5201 or 5201-5210). Empty = default (5201).
IPERF3_TIME="${IPERF3_TIME:-10}"               # iperf3 test duration in seconds (-t)
IPERF3_PARALLEL="${IPERF3_PARALLEL:-10}"       # iperf3 parallel streams (-P). More streams can better saturate high-BDP links.
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5000}"     # ms; only used if the local iperf3 build supports a connect-timeout flag
ADDR_FAMILY="${ADDR_FAMILY:-auto}"             # Domain resolution family: auto|4|6 (auto prefers IPv4, falls back to IPv6)

# LOG_DIR default is OS-dependent; set after platform detection.
LOG_DIR_DEFAULT=""
LOG_DIR=""





# Main code

# ----------------------------
# Flags / args
# ----------------------------
MTR=false
IPERF3=false
LOG=false
AUTO_INSTALL=false

IP=""
IPS_FILE=""
INTERFACES=""

# Derived needs
NEED_DNS=false

# sudo control for mtr (macOS/Linux only)
SUDO_MODE="auto"     # auto|force|never
MTR_USE_SUDO=false
SUDO_PROMPTED=false

# mtr permission/privilege failures (macOS commonly needs sudo for ICMP)
MTR_PERM_RE='permission denied|operation not permitted|not permitted|must be root|raw socket|cannot open raw socket|failure to open raw socket|cap_net_raw|setcap|cannot create socket|can.t create socket'

# Colors (enabled only when stdout is a TTY and NO_COLOR is not set)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BLUE="$(printf '\033[1;34m')"
  YELLOW="$(printf '\033[1;33m')"
  GREEN="$(printf '\033[1;32m')"
  RED="$(printf '\033[1;31m')"
  NC="$(printf '\033[0m')"
else
  BLUE=""; YELLOW=""; GREEN=""; RED=""; NC=""
fi

# ----------------------------
# Platform globals / tool paths
# ----------------------------
PLATFORM="unknown"
BREW_BIN=""
OPKG_BIN=""

MTR_BIN=""
IPERF3_BIN=""
XMLLINT_BIN=""
RESOLVEIP_BIN=""
DIG_BIN=""
HOST_BIN=""
NSLOOKUP_BIN=""
GETENT_BIN=""

IP_BIN=""
UBUS_BIN=""
JSONFILTER_BIN=""

# mtr output mode: xml/report (set by platform/tool availability)
MTR_OUTPUT_MODE="report"

# ----------------------------
# Best-of aggregation (scorecard)
# ----------------------------
BEST_UPLOAD=""
BEST_UPLOAD_IP=""
BEST_UPLOAD_IFACE=""
BEST_DOWNLOAD=""
BEST_DOWNLOAD_IP=""
BEST_DOWNLOAD_IFACE=""
BEST_PING=""
BEST_PING_IP=""
BEST_PING_IFACE=""
MIN_HOPS=""
MIN_HOPS_IP=""
MIN_HOPS_IFACE=""

# Track ties for Scorecard (multiple winners)
BEST_UPLOAD_ENTRIES=""
BEST_DOWNLOAD_ENTRIES=""
BEST_PING_ENTRIES=""
MIN_HOPS_ENTRIES=""

# Per-target notes from --ips (shown in Scorecard)
TARGET_NOTE_MAP=""

# ----------------------------
# Current-run timestamps
# ----------------------------
RUN_STARTED_TS=""
RUN_ENDED_TS=""

# ----------------------------
# Current target metrics (Idle + Load)
# ----------------------------

# Idle ping metrics (from baseline mtr)
MTR_BEST="ERROR"
MTR_WRST="ERROR"
MTR_AVG="ERROR"
MTR_HOPS="ERROR"
MTR_LOSS="ERROR"
MTR_SENT="0"
MTR_JITTER="ERROR"

# Load metrics (during iperf upload/download)
MTR_UP_BEST="ERROR"
MTR_UP_WRST="ERROR"
MTR_UP_AVG="ERROR"
MTR_UP_HOPS="ERROR"
MTR_UP_LOSS="ERROR"
MTR_UP_SENT="0"
MTR_UP_JITTER="ERROR"

MTR_DOWN_BEST="ERROR"
MTR_DOWN_WRST="ERROR"
MTR_DOWN_AVG="ERROR"
MTR_DOWN_HOPS="ERROR"
MTR_DOWN_LOSS="ERROR"
MTR_DOWN_SENT="0"
MTR_DOWN_JITTER="ERROR"

# iperf averages
IPERF_UPLOAD_AVG="0"
IPERF_DOWNLOAD_AVG="0"

# ----------------------------
# Output formatting
# ----------------------------
SEP_SMALL="-----------------------------------------------------------"
SEP_BIG="==========================================================="

# ----------------------------
# Small helpers
# ----------------------------
now_stamp() {
  date "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date
}

trim() {
  # trim leading/trailing whitespace
  # shellcheck disable=SC2001
  printf '%s\n' "$1" | awk '{$1=$1};1'
}

is_number() {
  # accepts ints/floats
  printf '%s\n' "${1:-}" | grep -Eq '^[0-9]+([.][0-9]+)?$'
}

fmt3() {
  v="${1:-}"
  if is_number "$v"; then
    awk -v x="$v" 'BEGIN{printf "%.3f", x}'
  else
    printf '%s\n' "$v"
  fi
}

fmt2() {
  v="${1:-}"
  if is_number "$v"; then
    awk -v x="$v" 'BEGIN{printf "%.2f", x}'
  else
    printf '%s\n' "$v"
  fi
}

# ---- Colorize ERROR values in output ----
is_error() { [ "${1:-}" = "ERROR" ]; }

cval() {
  v="${1:-}"
  if is_error "$v"; then
    printf "%sERROR%s" "$RED" "$NC"
  else
    printf "%s" "$v"
  fi
}
    
# Ensure a space before a trailing percent sign (e.g. "0.000%" -> "0.000 %").
fmt_pct_sp() {
  v="${1:-}"
  [ "$v" = "ERROR" ] && { printf '%s\n' "ERROR"; return 0; }

  case "$v" in
    *%)
      # normalize any existing whitespace before the trailing %
      printf '%s\n' "$v" | sed 's/[[:space:]]*%$/ %/'
      ;;
    *)
      printf '%s\n' "$v"
      ;;
  esac
}

looks_like_ipv4() {
  printf '%s\n' "${1:-}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

strip_enclosing_brackets() {
  # Strips one leading '[' and one trailing ']' (useful for IPv6 literals like [2001:db8::1])
  s="${1:-}"
  case "$s" in
    \[*\]) s="${s#\[}"; s="${s%\]}";;
  esac
  printf '%s\n' "$s"
}

strip_ipv6_zone() {
  # Strips RFC4007 zone ID (e.g., "%en0") from an IPv6 literal.
  s="${1:-}"
  case "$s" in
    *%*) printf '%s\n' "${s%%\%*}" ;;
    *) printf '%s\n' "$s" ;;
  esac
}

looks_like_ipv6() {
  # Lightweight IPv6 literal detection (full validation is done in validate_ip_domain()).
  s="$(strip_enclosing_brackets "${1:-}")"
  s="$(strip_ipv6_zone "$s")"
  [ -z "$s" ] && return 1
  printf '%s\n' "$s" | grep -q ':' || return 1
  printf '%s\n' "$s" | grep -Eq '^[0-9A-Fa-f:.]+$'
}

ip_family_of() {
  s="$(strip_enclosing_brackets "${1:-}")"
  s="$(strip_ipv6_zone "$s")"
  if looks_like_ipv4 "$s"; then
    echo "4"
    return 0
  fi
  if looks_like_ipv6 "$s"; then
    echo "6"
    return 0
  fi
  echo ""
  return 1
}

looks_like_domain() {
  # Hostname/domain: allow single-label names (localhost, router, iperf-server) and dotted names.
  # Accept optional trailing dot (FQDN) like example.com.
  d="${1%.}"  # strip ONE trailing dot if present

  # Avoid treating IP literals as "domains" (e.g., 1.1.1.1, 2001:db8::1)
  looks_like_ipv4 "$d" && return 1
  looks_like_ipv6 "$d" && return 1

  # Labels: start/end with alnum; allow hyphen/underscore inside. No requirement for alpha-only TLD.
  printf '%s\n' "$d" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9_-]*[A-Za-z0-9])?))*$'
}

fmt_speed_mbps() {
  v="${1:-}"
  if is_number "$v"; then
    printf "%s Mbits/sec" "$(fmt2 "$v")"
  elif [ "$v" = "ERROR" ]; then
    printf "%sERROR%s" "$RED" "$NC"
  else
    printf "%s" "$v"
  fi
}
    
# ---- ANSI-safe padding for fixed-width columns ----
pad_right() {
  w="$1"; s="$2"
  fmt="%-${w}s"
  printf "$fmt" "$s"
}

cval_pad() {
  w="$1"; v="${2:-}"
  if is_error "$v"; then
    printf "%s" "$RED"
    pad_right "$w" "ERROR"
    printf "%s" "$NC"
  else
    pad_right "$w" "$(cval "$v")"
  fi
}

speed_pad() {
  w="$1"; v="${2:-}"
  if is_error "$v"; then
    printf "%s" "$RED"
    pad_right "$w" "ERROR"
    printf "%s" "$NC"
  else
    pad_right "$w" "$(fmt_speed_mbps "$v")"
  fi
}

float_lt() {
  a="$1"; b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN{exit !(a<b)}'
}

float_gt() {
  a="$1"; b="$2"
  awk -v a="$a" -v b="$b" 'BEGIN{exit !(a>b)}'
}

calc_delta_ms() {
  base="$1"
  load="$2"
  if is_number "$base" && is_number "$load"; then
    awk -v b="$base" -v l="$load" 'BEGIN{printf "%.3f", (l-b)}'
  else
    printf '%s\n' "ERROR"
  fi
}

mktemp_file() {
  pfx="$1"
  dir="${TMPDIR:-/tmp}"
  [ -d "$dir" ] || dir="/tmp"
  mktemp "$dir/ifspeedtest_${pfx}.XXXXXXXXXX" 2>/dev/null || mktemp "/tmp/ifspeedtest_${pfx}.XXXXXXXXXX"
}

# ----------------------------
# Notices (printed after each target's tables)
# ----------------------------
TARGET_COUNT=0
NOTICES=""

add_notice() {
  # Appends a single-line notice to be printed after the current target's output.
  msg="$1"
  [ -z "$msg" ] && return 0
  NOTICES="${NOTICES}${msg}
"
}

add_error() {
  msg="$1"
  [ -z "$msg" ] && return 0
  ERRORS="${ERRORS}${msg}
"
}

flush_errors() {
  [ -z "${ERRORS:-}" ] && return 0
  printf "%sErrors:%s\n" "$YELLOW" "$NC"
  printf "%s" "$ERRORS" | awk -v y="$YELLOW" -v n="$NC" 'NF{ if(!seen[$0]++){ print y " - " n $0 } }'
  ERRORS=""
}

flush_notices() {
  [ -z "${NOTICES:-}" ] && return 0
  printf "%s" "$NOTICES" | awk -v y="$YELLOW" -v n="$NC" 'NF{print y "Note: " n $0}'
  NOTICES=""
}
    
# ----------------------------
# Per-target notes (from --ips) for Scorecard
# ----------------------------
set_note_for_ip() {
  ip="$1"
  note="$2"

  [ -z "$ip" ] && return 0
  [ -z "$note" ] && return 0

  # Only set once (first note wins)
  if printf '%s' "${TARGET_NOTE_MAP:-}" | awk -F '|' -v k="$ip" '$1==k{found=1} END{exit !found}'; then
    return 0
  fi

  TARGET_NOTE_MAP="${TARGET_NOTE_MAP}${ip}|${note}
"
}

get_note_for_ip() {
  ip="$1"
  [ -z "$ip" ] && { echo ""; return 0; }

  printf '%s' "${TARGET_NOTE_MAP:-}" | awk -F '|' -v k="$ip" '$1==k{ sub(/^[^|]*[|]/, "", $0); print; exit }'
}


# ----------------------------
# Output layout
# ----------------------------
repeat_char() {
  ch="$1"; n="$2"
  out=""
  i=0
  while [ "$i" -lt "$n" ] 2>/dev/null; do
    out="${out}${ch}"
    i=$((i + 1))
  done
  echo "$out"
}

print_banner() {
  title="$1"
  ts="$2"
  base="============= $title: $ts"
  len="${#base}"
  filler=$((59 - len - 1))
  [ "$filler" -lt 0 ] 2>/dev/null && filler=0
  printf "%s%s %s%s\n" "$GREEN" "$base" "$(repeat_char '=' "$filler")" "$NC"
}

add_egress_ifaces() {
  # Accepts a single argument that may contain commas/whitespace and appends it to INTERFACES.
  # Usage examples:
  #   -I en0 -I en1
  #   -I "en0,en1"
  #   -I "en0 en1"
  raw="${1:-}"
  [ -z "$raw" ] && return 0

  # Turn commas into spaces, then split on IFS whitespace.
  list="$(printf '%s' "$raw" | tr ',' ' ')"

  for one in $list; do
    [ -z "$one" ] && continue
    # de-dup
    case " ${INTERFACES} " in
      *" ${one} "*) : ;;
      *) INTERFACES="${INTERFACES}${INTERFACES:+ }${one}" ;;
    esac
  done
}

get_egress_display_list() {
  # Returns a human-friendly egress display string for Settings (one or many interfaces).
  if [ -n "${INTERFACES:-}" ]; then
    out=""
    for one in $INTERFACES; do
      d="$(get_egress_display "$one")"
      if [ -z "$out" ]; then
        out="$d"
      else
        out="$out, $d"
      fi
    done
    echo "$out"
  else
    get_egress_display ""
  fi
}

get_egress_display() {
  iface_input="$1"
  iface_dev="$iface_input"

  if [ "$PLATFORM" = "openwrt" ] && [ -n "$iface_input" ]; then
    iface_dev="$(normalize_iface_openwrt "$iface_input")"
  fi

  if [ -z "$iface_dev" ]; then
    iface_dev="$(get_default_iface 2>/dev/null || true)"
  fi

  [ -z "$iface_dev" ] && iface_dev="(default)"
  echo "$iface_dev"
}

print_settings() {
  egress_display="$(get_egress_display_list)"

  printf "%sSettings%s\n" "$GREEN" "$NC"
  printf "%s%s%s\n" "$GREEN" "$SEP_SMALL" "$NC"

  if [ -n "${IPS_FILE:-}" ]; then
    ips_name="$(basename "$IPS_FILE")"
    printf "%sIPs:     %s%s\n" "$GREEN" "$NC" "$ips_name"
  fi

  printf "%sEgress:  %s%s\n" "$GREEN" "$NC" "$egress_display"
  
  # Address family preference only affects DOMAIN resolution (not literal IPs).
  case "$(printf '%s' "${ADDR_FAMILY:-auto}" | tr 'A-Z' 'a-z')" in
    4|ipv4|v4)
      printf "%sFamily:  %s%s\n" "$GREEN" "$NC" "IPv4 only (domains resolve A)"
      ;;
    6|ipv6|v6)
      printf "%sFamily:  %s%s\n" "$GREEN" "$NC" "IPv6 only (domains resolve AAAA)"
      ;;
  esac

  if [ "$LOG" = "true" ] && [ -n "${LOG_FILE:-}" ]; then
    printf "%sLog:     %s%s\n" "$GREEN" "$NC" "$LOG_FILE"
  fi

  if [ "$IPERF3" = "true" ]; then
    printf "%siperf3:  load for %s%s%s sec with %s%s%s parallel streams per Target%s\n" \
      "$GREEN" "$NC" "$IPERF3_TIME" "$GREEN" "$NC" "$IPERF3_PARALLEL" "$GREEN" "$NC"
    if [ -n "${IPERF3_PORT_SPEC_DISPLAY:-}" ]; then
      if [ "${IPERF3_PORT_IS_RANGE:-false}" = "true" ]; then
        printf "%s          ↳ using custom port-range%s %s%s\n" "$GREEN" "$NC" "$IPERF3_PORT_SPEC_DISPLAY" "$NC"
      else
        printf "%s          ↳ using custom port%s %s%s\n" "$GREEN" "$NC" "$IPERF3_PORT_SPEC_DISPLAY" "$NC"
      fi
    fi

  else
    printf "%siperf3:  (skipped)%s\n" "$GREEN" "$NC"
  fi

  if [ "$MTR" = "true" ]; then
    probe="$(printf '%s' "$MTR_PROBE" | tr '[:lower:]' '[:upper:]')"

    if [ "$MTR_PROBE" = "icmp" ]; then
      printf "%smtr:     %s%s%s mode with interval of %s%s%s sec%s\n" \
        "$GREEN" "$NC" "$probe" "$GREEN" "$NC" "$MTR_INTERVAL" "$GREEN" "$NC"
    else
      port_display="${MTR_PORT:-}"
      if [ -z "$port_display" ]; then
        if [ "$MTR_PROBE" = "tcp" ]; then port_display="443"; else port_display="(default)"; fi
      fi
      printf "%smtr:     %s%s%s mode on port %s%s%s with interval of %s%s%s sec%s\n" \
        "$GREEN" "$NC" "$probe" "$GREEN" "$NC" "$port_display" "$GREEN" "$NC" "$MTR_INTERVAL" "$GREEN" "$NC"
    fi

    printf "%s          ↳ %s%s%s test cycles for Idle%s\n" "$GREEN" "$NC" "$MTR_COUNT" "$GREEN" "$NC"
  else
    printf "%smtr:     (skipped)%s\n" "$GREEN" "$NC"
  fi

  printf "%s%s%s\n\n" "$GREEN" "$SEP_SMALL" "$NC"
}

print_scorecard() {
  [ "${TARGET_COUNT:-0}" -gt 1 ] 2>/dev/null || return 0

  printf "%sScorecard%s\n" "$GREEN" "$NC"
  printf "%s%s%s\n" "$GREEN" "$SEP_SMALL" "$NC"
  SCORECARD_IP_W=39   # max IPv6 length (39); keeps inline notes aligned

  # Fixed-width columns (no tabs) so the '|' stays aligned across terminals/OSes.
  #  - Label column: 14 (fits "Best Download:")
  #  - Value column: 22 (fits "12345.67 Mbits/sec")

  if [ -n "${BEST_UPLOAD:-}" ]; then
    val="$(fmt2 "$BEST_UPLOAD") Mbits/sec"
    if [ -n "${BEST_UPLOAD_ENTRIES:-}" ]; then
      printf "%s" "$BEST_UPLOAD_ENTRIES" | while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        iface="${line%%|*}"
        ip="${line#*|}"
        note="$(get_note_for_ip "$ip")"
        ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip")"
        [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
        printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
          "$GREEN" "Best Upload:" "$NC" "$val" \
          "$GREEN" "$NC" "$GREEN" "$iface" "$NC" \
          "$GREEN" "$NC" "$ip_out"
      done
    else
      ip_key="${BEST_UPLOAD_IP:-}"
      note="$(get_note_for_ip "$ip_key")"
      ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip_key")"
      [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
      printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
        "$GREEN" "Best Upload:" "$NC" "$val" \
        "$GREEN" "$NC" "$GREEN" "${BEST_UPLOAD_IFACE:-}" "$NC" \
        "$GREEN" "$NC" "$ip_out"
    fi
  fi

  if [ -n "${BEST_DOWNLOAD:-}" ]; then
    val="$(fmt2 "$BEST_DOWNLOAD") Mbits/sec"
    if [ -n "${BEST_DOWNLOAD_ENTRIES:-}" ]; then
      printf "%s" "$BEST_DOWNLOAD_ENTRIES" | while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        iface="${line%%|*}"
        ip="${line#*|}"
        note="$(get_note_for_ip "$ip")"
        ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip")"
        [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
        printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
          "$GREEN" "Best Download:" "$NC" "$val" \
          "$GREEN" "$NC" "$GREEN" "$iface" "$NC" \
          "$GREEN" "$NC" "$ip_out"
      done
    else
      ip_key="${BEST_DOWNLOAD_IP:-}"
      note="$(get_note_for_ip "$ip_key")"
      ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip_key")"
      [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
      printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
        "$GREEN" "Best Download:" "$NC" "$val" \
        "$GREEN" "$NC" "$GREEN" "${BEST_DOWNLOAD_IFACE:-}" "$NC" \
        "$GREEN" "$NC" "$ip_out"
    fi
  fi

  if [ -n "${BEST_PING:-}" ]; then
    val="$(fmt3 "$BEST_PING") ms"
    if [ -n "${BEST_PING_ENTRIES:-}" ]; then
      printf "%s" "$BEST_PING_ENTRIES" | while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        iface="${line%%|*}"
        ip="${line#*|}"
        note="$(get_note_for_ip "$ip")"
        ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip")"
        [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
        printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
          "$GREEN" "Best Ping:" "$NC" "$val" \
          "$GREEN" "$NC" "$GREEN" "$iface" "$NC" \
          "$GREEN" "$NC" "$ip_out"
      done
    else
      ip_key="${BEST_PING_IP:-}"
      note="$(get_note_for_ip "$ip_key")"
      ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip_key")"
      [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
      printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
        "$GREEN" "Best Ping:" "$NC" "$val" \
        "$GREEN" "$NC" "$GREEN" "${BEST_PING_IFACE:-}" "$NC" \
        "$GREEN" "$NC" "$ip_out"
    fi
  fi

  if [ -n "${MIN_HOPS:-}" ]; then
    val="$MIN_HOPS"
    if [ -n "${MIN_HOPS_ENTRIES:-}" ]; then
      printf "%s" "$MIN_HOPS_ENTRIES" | while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        iface="${line%%|*}"
        ip="${line#*|}"
        note="$(get_note_for_ip "$ip")"
        ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip")"
        [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
        printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
          "$GREEN" "Min hops:" "$NC" "$val" \
          "$GREEN" "$NC" "$GREEN" "$iface" "$NC" \
          "$GREEN" "$NC" "$ip_out"
      done
    else
      ip_key="${MIN_HOPS_IP:-}"
      note="$(get_note_for_ip "$ip_key")"
      ip_out="$(printf "%-${SCORECARD_IP_W}s" "$ip_key")"
      [ -n "$note" ] && ip_out="${ip_out}  ${YELLOW}${note}${NC}"
      printf "%s%-14s%s %-22s %s|%s %s%s%s %s=>%s %s\n" \
        "$GREEN" "Min hops:" "$NC" "$val" \
        "$GREEN" "$NC" "$GREEN" "${MIN_HOPS_IFACE:-}" "$NC" \
        "$GREEN" "$NC" "$ip_out"
    fi
  fi

  printf "%s%s%s\n" "$GREEN" "$SEP_SMALL" "$NC"
}

# BusyBox sleep may not support fractions
SPINNER_DELAY="0.1"
sleep 0.1 2>/dev/null || SPINNER_DELAY="1"

# ----------------------------
# Cursor / cleanup
# ----------------------------
CURSOR_HIDDEN=false

# Track running background test processes so Ctrl-C doesn't leave strays.
ACTIVE_BG_PIDS=""

register_bg_pid() {
  p="$1"
  [ -z "$p" ] && return 0
  case " $ACTIVE_BG_PIDS " in
    *" $p "*) return 0 ;;
  esac
  ACTIVE_BG_PIDS="$ACTIVE_BG_PIDS $p"
}

unregister_bg_pid() {
  p="$1"
  [ -z "$p" ] && return 0
  ACTIVE_BG_PIDS="$(printf '%s\n' "$ACTIVE_BG_PIDS" | awk -v p="$p" '
    {
      for (i = 1; i <= NF; i++) {
        if ($i != p) {
          if (out != "") out = out OFS $i
          else out = $i
        }
      }
    }
    END { print out }
  ')"
}

kill_pid_tree() {
  p="$1"
  [ -z "$p" ] && return 0

  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -P "$p" 2>/dev/null || true
  fi
  kill "$p" 2>/dev/null || true

  # Only SIGKILL if still alive
  if kill -0 "$p" 2>/dev/null; then
    if command -v pkill >/dev/null 2>&1; then
      pkill -9 -P "$p" 2>/dev/null || true
    fi
    kill -9 "$p" 2>/dev/null || true
  fi
}

kill_active_bg_pids() {
  for p in $ACTIVE_BG_PIDS; do
    kill_pid_tree "$p"
  done
  ACTIVE_BG_PIDS=""
}

hide_cursor() {
  [ -t 1 ] || return 0
  if command -v tput >/dev/null 2>&1; then
    tput civis 2>/dev/null || true
  else
    printf '\033[?25l'
  fi
  CURSOR_HIDDEN=true
}

show_cursor() {
  [ "$CURSOR_HIDDEN" = "true" ] || return 0
  [ -t 1 ] || return 0
  if command -v tput >/dev/null 2>&1; then
    tput cnorm 2>/dev/null || true
  else
    printf '\033[?25h'
  fi
  CURSOR_HIDDEN=false
}

cleanup_on_exit() {
  clear_spinner_line
  show_cursor
  kill_active_bg_pids
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  [ -n "${MTR_OUT_FILE:-}" ] && rm -f "$MTR_OUT_FILE" 2>/dev/null || true
}
trap 'cleanup_on_exit' 0
trap 'cleanup_on_exit; exit 130' INT
trap 'cleanup_on_exit; exit 143' TERM

# ----------------------------
# UI
# ----------------------------
show_help() {
  main_iface="$(get_default_iface 2>/dev/null || true)"
  [ -z "$main_iface" ] && main_iface="(default)"

  cat <<EOF

-----------------------------------------------------------
ifspeedtest.sh helps you validate real-world link quality, not just “speed”.
It runs throughput tests (iperf3) and can also measure latency/loss/jitter (mtr).

If you have multiple possible routes/egress IPs/remote targets and want the best one,
put them in a file and use --ips. The script will test each target and show a Scorecard
highlighting the best upload/download and lowest-latency options.
-----------------------------------------------------------


Usage: $0 [options]

Options:
  -i, --ip <IPv4|IPv6|domain>  Target to test (literal IP or domain).
  --ips <file>                 File with targets (one per line; inline # comments allowed).
  --ipv4                       For domain targets, resolve/use IPv4 (A) only.
  --ipv6                       For domain targets, resolve/use IPv6 (AAAA) only.
  -I <iface>[,<iface>...]      Egress interface/device to use (can be repeated).
                                ↳ If 2+ egress interfaces are set, each target is tested across ALL of them.
  --mtr [count]                Run mtr. Optional cycles (default: $MTR_COUNT).
  --iperf3 [time]              Run iperf3. Optional duration seconds (default: $IPERF3_TIME).
  -P, --iperf3-parallel <n>    Parallel streams for iperf3 (default: $IPERF3_PARALLEL).
  -p, --iperf3-port <spec>     iperf3 server port or range (e.g., 5201 or 5201-5210; also supports comma lists).
  --mtr-probe <icmp|udp|tcp>   mtr probe mode (default: $MTR_PROBE).
  --mtr-port <port>            Destination port for mtr tcp/udp probes.
  --mtr-interval <seconds>     Seconds between mtr probes (default: $MTR_INTERVAL).
  --log [directory]            Save log in directory (default: OS-specific).
  --install-missing            Attempt to install missing tools (brew/apt/yum/dnf/pacman/opkg).
  --sudo                       Force sudo for mtr (prompt once up front where supported).
  --no-sudo                    Never use sudo for mtr (mtr may be skipped if it needs privileges).
  -h, --help                   Show this help and exit.

Examples:
-----------------------------------------------------------
  $0 -i 1.1.1.1
  $0 -i 2606:4700:4700::1111
  $0 -i example.com --mtr --iperf3 30 -I "$main_iface"
  $0 -i example.com --ipv6 --mtr --iperf3 30 -I "$main_iface"
  $0 -i example.com -I "enp0s3,enp0s8"
  $0 --ips ips.ini --mtr 30 --iperf3 30 -I enp0s3 -I enp0s8 --log ./logs
  $0 -i example.com --mtr # mtr only (no iperf3)

IPs file format (--ips):
-----------------------------------------------------------
  - One target per line: IPv4 address, IPv6 address, or domain name.
  - Empty lines are ignored.
  - Lines starting with # are ignored.
  - Inline notes are supported after # and will be shown next to the Target line.

    Example of ips.txt:
      1.1.1.1              # route A (ISP1)
      2606:4700:4700::1111 # route A (IPv6)
      example.com          # route B (ISP2)
      9.9.9.9

Output hints:
-----------------------------------------------------------
  - If -i/--ip is a domain, it is resolved to an IP and shown as: <domain> (<resolved IP>) on the Target line.
     ↳  By default, domains resolve to IPv4 (A) if available, then fall back to IPv6 (AAAA).
        Use --ipv4 or --ipv6 to force the family for domain targets.
     ↳  A reverse DNS (PTR) lookup is then attempted for that IP.
        The PTR name is appended only when it exists; for domain inputs it is omitted when it matches the domain.

EOF
}

# Track whether a spinner line is currently on screen (so we can clear it before normal output)
SPINNER_ONSCREEN="false"

clear_spinner_line() {
  [ -t 1 ] || return 0
  [ "${SPINNER_ONSCREEN:-false}" = "true" ] || return 0
  printf "\r\033[K"
  SPINNER_ONSCREEN="false"
}

show_spinner() {
  pid="$1"
  message="$2"

  [ -t 1 ] || return 0

  hide_cursor
  i=0
  frames='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    c="$(printf '%s' "$frames" | cut -c $(( (i % 4) + 1 )) )"
    # Clear each frame (prevents leftovers when message length changes).
    # DO NOT clear at the end -> prevents blank gaps between stages.
    printf "\r\033[K[%s] %s" "$c" "$message"
    SPINNER_ONSCREEN="true"
    i=$((i + 1))
    sleep "$SPINNER_DELAY"
  done
  show_cursor
}

run_cmd_bg() {
  # Usage: run_cmd_bg "Message" <outfile> <cmd...>
  message="$1"
  outfile="$2"
  shift 2

  "$@" >"$outfile" 2>&1 &
  pid=$!
  register_bg_pid "$pid"
  show_spinner "$pid" "$message"
  wait "$pid"
  rc=$?
  clear_spinner_line
  unregister_bg_pid "$pid"
  return $rc
}

BG_PID=""
start_cmd_bg() {
  # Usage: start_cmd_bg <outfile> <cmd...>
  outfile="$1"
  shift
  "$@" >"$outfile" 2>&1 &
  BG_PID=$!
  register_bg_pid "$BG_PID"
}

# ----------------------------
# Platform detection
# ----------------------------
is_openwrt() {
  [ -r /etc/openwrt_release ] && return 0
  if [ -r /etc/os-release ]; then
    grep -qiE '(^ID="?openwrt"?$|openwrt)' /etc/os-release 2>/dev/null && return 0
  fi
  return 1
}

detect_platform() {
  u="$(uname -s 2>/dev/null || echo unknown)"
  case "$u" in
    Darwin)
      PLATFORM="macos"
      LOG_DIR_DEFAULT="$(pwd)"
      ;;
    Linux)
      if is_openwrt; then
        PLATFORM="openwrt"
        LOG_DIR_DEFAULT="/tmp"
      else
        PLATFORM="linux"
        LOG_DIR_DEFAULT="$(pwd)"
      fi
      ;;
    *)
      PLATFORM="unknown"
      LOG_DIR_DEFAULT="$(pwd)"
      ;;
  esac
}

# ----------------------------
# Networking helpers (OS-specific)
# ----------------------------
get_default_iface() {
  case "$PLATFORM" in
    macos)
      route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}'
      ;;
    linux|openwrt)
      if command -v ip >/dev/null 2>&1; then
        ip route show default 2>/dev/null | awk '
          $1=="default" {
            for(i=1;i<=NF;i++){
              if($i=="dev"){print $(i+1); exit}
            }
          }'
      elif command -v route >/dev/null 2>&1; then
        route -n 2>/dev/null | awk '$1=="0.0.0.0" || $1=="default" {print $8; exit}'
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

iface_exists() {
  dev="$1"
  [ -z "$dev" ] && return 1

  if command -v ip >/dev/null 2>&1; then
    # iproute2: ip link show dev <if>
    ip link show dev "$dev" >/dev/null 2>&1 && return 0
    # BusyBox ip: ip link show <if>
    ip link show "$dev" >/dev/null 2>&1 && return 0
  fi

  # macOS (and some minimal Linux installs) only have ifconfig
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$dev" >/dev/null 2>&1 && return 0
  fi

  [ -d "/sys/class/net/$dev" ] && return 0
  return 1
}


ubus_iface_l3dev() {
  # OpenWrt only
  name="$1"
  [ -n "$UBUS_BIN" ] || return 1
  [ -n "$JSONFILTER_BIN" ] || return 1

  "$UBUS_BIN" call network.interface."$name" status 2>/dev/null | "$JSONFILTER_BIN" -e '@.l3_device' 2>/dev/null | tr -d '\n' | tr -d '"'
}

ubus_iface_ipv4() {
  # OpenWrt only - returns first ipv4 address for interface
  name="$1"
  [ -n "$UBUS_BIN" ] || return 1
  [ -n "$JSONFILTER_BIN" ] || return 1

  "$UBUS_BIN" call network.interface."$name" status 2>/dev/null | "$JSONFILTER_BIN" -e '@["ipv4-address"][0].address' 2>/dev/null | tr -d '\n' | tr -d '"'
}
            
ubus_iface_ipv6() {
  # OpenWrt only - returns first non-link-local ipv6 address for interface (best-effort)
  name="$1"
  [ -n "$UBUS_BIN" ] || return 1
  [ -n "$JSONFILTER_BIN" ] || return 1

  "$UBUS_BIN" call network.interface."$name" status 2>/dev/null \
    | "$JSONFILTER_BIN" -e '@["ipv6-address"][*].address' 2>/dev/null \
    | tr -d '"' \
    | tr ' ' '\n' \
    | awk 'NF && $0 !~ /^fe80:/ {print; exit}'
}

normalize_iface_openwrt() {
  # If input looks like a real device that exists, keep it.
  in="$1"
  [ -z "$in" ] && { echo ""; return 0; }

  if iface_exists "$in"; then
    echo "$in"
    return 0
  fi

  # Try ubus to map logical iface -> l3_device
  dev="$(ubus_iface_l3dev "$in" 2>/dev/null || true)"
  if [ -n "$dev" ] && iface_exists "$dev"; then
    echo "$dev"
    return 0
  fi

  echo "$in"
  return 0
}

get_interface_ip() {
  iface="$1"
  fam="${2:-4}"

  case "$fam" in
    6|ipv6|v6)
      case "$PLATFORM" in
        macos)
          # Prefer ifconfig parsing for IPv6 because ipconfig can return link-local first.
          addr="$(ifconfig "$iface" 2>/dev/null | awk '
            /inet6 / {
              a=$2
              sub(/%.*/, "", a)
              sub(/\/.*/, "", a)
              if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/ && a !~ /^fe80:/ && a != "::1" && a != "::") { print a; exit }
            }
          ')"

          if [ -z "$addr" ]; then
            # Fallback: ipconfig helpers (best-effort; still filter link-local/loopback).
            addr="$( (ipconfig getifaddr6 "$iface" 2>/dev/null || ipconfig getv6ifaddr "$iface" 2>/dev/null || true) | awk '
              NF {
                a=$1
                sub(/%.*/, "", a)
                sub(/\/.*/, "", a)
                if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/ && a !~ /^fe80:/ && a != "::1" && a != "::") { print a; exit }
              }
            ')"
          fi

          printf '%s\n' "$addr"
          ;;

        linux|openwrt)
          if command -v ip >/dev/null 2>&1; then
            addr="$(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '
              /inet6 / {
                a=$2
                sub(/\/.*/, "", a)
                sub(/%.*/, "", a)
                if (a != "::1") { print a; exit }
              }
            ')"
            if [ -z "$addr" ]; then
              addr="$(ip -6 addr show dev "$iface" 2>/dev/null | awk '
                /inet6 / {
                  a=$2
                  sub(/\/.*/, "", a)
                  sub(/%.*/, "", a)
                  if (a !~ /^fe80:/ && a != "::1") { print a; exit }
                }
              ')"
            fi
            printf '%s\n' "$addr"
          elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$iface" 2>/dev/null | awk '
              /inet6 / {
                for (i=1;i<=NF;i++) {
                  if ($i ~ /:/) {
                    a=$i
                    gsub(/^addr:/,"",a)
                    sub(/\/.*/, "", a)
                    sub(/%.*/, "", a)
                    if (a !~ /^fe80:/ && a != "::1") { print a; exit }
                  }
                }
              }
            '
          fi
          ;;
        *)
          echo ""
          ;;
      esac
      ;;
    *)
      # IPv4
      case "$PLATFORM" in
        macos)
          addr="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
          if [ -n "$addr" ]; then
            printf '%s\n' "$addr" | awk 'NF{print; exit}'
          else
            ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}'
          fi
          ;;
        linux|openwrt)
          if command -v ip >/dev/null 2>&1; then
            ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{a=$2; sub(/\/.*/, "", a); print a; exit}'
          elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig "$iface" 2>/dev/null | awk '/inet addr:/{sub("addr:","",$2); print $2; exit} /inet /{print $2; exit}'
          fi
          ;;
        *)
          echo ""
          ;;
      esac
      ;;
  esac
}

# ----------------------------
# sudo helpers (macOS/Linux)
# ----------------------------
have_sudo() {
  command -v sudo >/dev/null 2>&1
}

start_sudo_keepalive() {
  [ "$(id -u)" -eq 0 ] && return 0
  [ -n "${SUDO_KEEPALIVE_PID:-}" ] && return 0
  have_sudo || return 1

  (
    while true; do
      sudo -n true 2>/dev/null || exit 0
      sleep 60
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
  return 0
}

ensure_sudo() {
  # returns 0 if sudo -n will work afterwards
  [ "$(id -u)" -eq 0 ] && return 0
  have_sudo || return 1

  if sudo -n true 2>/dev/null; then
    start_sudo_keepalive >/dev/null 2>&1 || true
    return 0
  fi

  # Need interactive auth; don't attempt if no TTY.
  [ -t 0 ] || return 1
  
  clear_spinner_line

  if [ "$SUDO_PROMPTED" = "false" ]; then
    echo "mtr requires elevated privileges on some systems for ICMP probes."
    echo "You'll be prompted once for sudo; subsequent mtr runs use sudo -n."
    SUDO_PROMPTED=true
  fi

  sudo -v || return 1
  start_sudo_keepalive >/dev/null 2>&1 || true
  return 0
}

# ----------------------------
# Tool discovery / install (OS-specific)
# ----------------------------
find_brew() {
  if command -v brew >/dev/null 2>&1; then
    BREW_BIN="$(command -v brew)"
    return 0
  fi
  for c in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$c" ]; then
      BREW_BIN="$c"
      return 0
    fi
  done
  return 1
}

resolve_brew_bin() {
  rel="$1" # e.g. "sbin/mtr"
  [ -z "${BREW_BIN:-}" ] && find_brew >/dev/null 2>&1 || true
  [ -z "${BREW_BIN:-}" ] && return 1
  prefix="$("$BREW_BIN" --prefix 2>/dev/null)"
  [ -n "$prefix" ] && [ -x "$prefix/$rel" ] && { echo "$prefix/$rel"; return 0; }
  return 1
}

detect_linux_distro() {
  # debian|redhat|arch|unknown
  if [ -f /etc/debian_version ]; then
    echo "debian"
  elif [ -f /etc/redhat-release ]; then
    echo "redhat"
  elif [ -f /etc/arch-release ]; then
    echo "arch"
  else
    echo "unknown"
  fi
}

linux_install_cmd() {
  # prints best-effort install command for packages in $*
  pkgs="$*"
  distro="$(detect_linux_distro)"

  sudo_prefix=""
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_prefix="sudo "
    elif command -v doas >/dev/null 2>&1; then
      sudo_prefix="doas "
    fi
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "${sudo_prefix}apt-get update && ${sudo_prefix}apt-get install -y $pkgs"
  elif command -v apt >/dev/null 2>&1; then
    echo "${sudo_prefix}apt update && ${sudo_prefix}apt install -y $pkgs"
  elif command -v dnf >/dev/null 2>&1; then
    echo "${sudo_prefix}dnf install -y $pkgs"
  elif command -v yum >/dev/null 2>&1; then
    echo "${sudo_prefix}yum install -y $pkgs"
  elif command -v pacman >/dev/null 2>&1; then
    echo "${sudo_prefix}pacman -Syu --noconfirm $pkgs"
  elif command -v apk >/dev/null 2>&1; then
    echo "${sudo_prefix}apk add --no-cache $pkgs"
  else
    case "$distro" in
      debian) echo "${sudo_prefix}apt-get update && ${sudo_prefix}apt-get install -y $pkgs" ;;
      redhat) echo "${sudo_prefix}yum install -y $pkgs" ;;
      arch) echo "${sudo_prefix}pacman -Syu --noconfirm $pkgs" ;;
      *) echo "(install manually): $pkgs" ;;
    esac
  fi
}


install_missing_macos() {
  to_install="$1" # space-separated brew formulae

  if [ "$(id -u)" -eq 0 ]; then
    echo "You're running as root. Don't run Homebrew installs as root."
    echo "Re-run without sudo to install tools, then run again."
    return 1
  fi

  find_brew >/dev/null 2>&1 || {
    echo "Homebrew not found. Install Homebrew, then run:"
    echo "  brew install $to_install"
    return 1
  }

  if [ "$AUTO_INSTALL" = "true" ]; then
    # shellcheck disable=SC2086
    "$BREW_BIN" install $to_install || return 1
    return 0
  fi

  [ -t 0 ] || {
    echo "Missing tools: $to_install"
    echo "Run: brew install $to_install"
    return 1
  }

  printf "Install via Homebrew (%s)? (yes/no): " "$to_install"
  read -r ans
  if [ "$ans" != "yes" ]; then
    echo "Please install missing tools manually and re-run."
    return 1
  fi

  # shellcheck disable=SC2086
  "$BREW_BIN" install $to_install || return 1
  return 0
}

install_missing_openwrt() {
  pkgs="$1"
  [ -n "$OPKG_BIN" ] || { echo "Error: opkg not found."; return 1; }

  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: --install-missing requires root on OpenWrt (opkg needs root)."
    return 1
  fi

  tmpu="$(mktemp_file opkg_update)" || return 1
  tmpi="$(mktemp_file opkg_install)" || return 1

  run_cmd_bg "Running opkg update..." "$tmpu" "$OPKG_BIN" update || {
    clear_spinner_line
    echo "Error: opkg update failed."
    cat "$tmpu" 2>/dev/null || true
    rm -f "$tmpu" "$tmpi" 2>/dev/null || true
    return 1
  }

  # shellcheck disable=SC2086
  run_cmd_bg "Installing packages: $pkgs ..." "$tmpi" "$OPKG_BIN" install $pkgs || {
    clear_spinner_line
    echo "Error: opkg install failed."
    cat "$tmpi" 2>/dev/null || true
    rm -f "$tmpu" "$tmpi" 2>/dev/null || true
    return 1
  }

  clear_spinner_line
  rm -f "$tmpu" "$tmpi" 2>/dev/null || true
  return 0
}

install_missing_linux() {
  pkgs="$1"
  cmd="$(linux_install_cmd "$pkgs")"

  if [ "$AUTO_INSTALL" = "true" ]; then
    echo "Installing: $pkgs"
    # shellcheck disable=SC2086
    sh -c "$cmd" || return 1
    return 0
  fi

  [ -t 0 ] || {
    echo "Missing tools/packages: $pkgs"
    echo "Run: $cmd"
    return 1
  }

  printf "Install missing packages (%s)? (yes/no): " "$pkgs"
  read -r ans
  if [ "$ans" != "yes" ]; then
    echo "Please install missing packages and re-run."
    return 1
  fi

  # shellcheck disable=SC2086
  sh -c "$cmd" || return 1
  return 0
}

check_tools_macos() {
  find_brew >/dev/null 2>&1 || true

  # mtr (only if requested)
  if [ "$MTR" = "true" ]; then
    if command -v mtr >/dev/null 2>&1; then
      MTR_BIN="$(command -v mtr)"
    else
      MTR_BIN="$(resolve_brew_bin "sbin/mtr" || resolve_brew_bin "bin/mtr" || true)"
    fi
  fi

  # iperf3 (only if requested)
  if [ "$IPERF3" = "true" ]; then
    if command -v iperf3 >/dev/null 2>&1; then
      IPERF3_BIN="$(command -v iperf3)"
    else
      IPERF3_BIN="$(resolve_brew_bin "bin/iperf3" || true)"
    fi
  fi

  # xmllint (optional; enables XML parsing)
  XMLLINT_BIN="$(command -v xmllint 2>/dev/null || true)"
  if [ -z "$XMLLINT_BIN" ]; then
    libxml2_prefix=""
    if [ -n "${BREW_BIN:-}" ]; then
      libxml2_prefix="$("$BREW_BIN" --prefix libxml2 2>/dev/null || true)"
    fi
    if [ -n "$libxml2_prefix" ] && [ -x "$libxml2_prefix/bin/xmllint" ]; then
      XMLLINT_BIN="$libxml2_prefix/bin/xmllint"
    fi
  fi

  # DNS helpers (only required if domains are used)
  DIG_BIN="$(command -v dig 2>/dev/null || true)"
  HOST_BIN="$(command -v host 2>/dev/null || true)"
  NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"

  # Homebrew's bind is commonly keg-only; use its prefix if present.
  if [ -n "${BREW_BIN:-}" ]; then
    bind_prefix="$("$BREW_BIN" --prefix bind 2>/dev/null || true)"
    if [ -n "$bind_prefix" ]; then
      [ -z "$DIG_BIN" ] && [ -x "$bind_prefix/bin/dig" ] && DIG_BIN="$bind_prefix/bin/dig"
      [ -z "$HOST_BIN" ] && [ -x "$bind_prefix/bin/host" ] && HOST_BIN="$bind_prefix/bin/host"
      [ -z "$NSLOOKUP_BIN" ] && [ -x "$bind_prefix/bin/nslookup" ] && NSLOOKUP_BIN="$bind_prefix/bin/nslookup"
    fi
  fi

  missing=""
  brew_pkgs=""

  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && { missing="$missing mtr"; brew_pkgs="$brew_pkgs mtr"; }
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && { missing="$missing iperf3"; brew_pkgs="$brew_pkgs iperf3"; }

  if [ "$NEED_DNS" = "true" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ] && [ -z "$NSLOOKUP_BIN" ]; then
    missing="$missing dns"
    brew_pkgs="$brew_pkgs bind"
  fi

  brew_pkgs="$(trim "$brew_pkgs")"

  if [ -n "$missing" ]; then
    echo "Missing required tools:$missing"
    if [ "$AUTO_INSTALL" = "true" ]; then
      install_missing_macos "$brew_pkgs" || exit 1

      # Re-resolve
      if [ "$MTR" = "true" ]; then
        command -v mtr >/dev/null 2>&1 && MTR_BIN="$(command -v mtr)" || MTR_BIN="$(resolve_brew_bin "sbin/mtr" || resolve_brew_bin "bin/mtr" || true)"
      fi
      if [ "$IPERF3" = "true" ]; then
        command -v iperf3 >/dev/null 2>&1 && IPERF3_BIN="$(command -v iperf3)" || IPERF3_BIN="$(resolve_brew_bin "bin/iperf3" || true)"
      fi

      DIG_BIN="$(command -v dig 2>/dev/null || true)"
      HOST_BIN="$(command -v host 2>/dev/null || true)"
      NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
      if [ -n "${BREW_BIN:-}" ]; then
        bind_prefix="$("$BREW_BIN" --prefix bind 2>/dev/null || true)"
        if [ -n "$bind_prefix" ]; then
          [ -z "$DIG_BIN" ] && [ -x "$bind_prefix/bin/dig" ] && DIG_BIN="$bind_prefix/bin/dig"
          [ -z "$HOST_BIN" ] && [ -x "$bind_prefix/bin/host" ] && HOST_BIN="$bind_prefix/bin/host"
          [ -z "$NSLOOKUP_BIN" ] && [ -x "$bind_prefix/bin/nslookup" ] && NSLOOKUP_BIN="$bind_prefix/bin/nslookup"
        fi
      fi
    else
      if [ -z "${BREW_BIN:-}" ]; then
        echo "Homebrew not found. Install Homebrew, then run:"
      else
        echo "Install with:"
      fi
      echo "  brew install $brew_pkgs"
      echo "Or rerun with: --install-missing"
      exit 1
    fi
  fi

  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && { echo "Error: mtr missing."; exit 1; }
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && { echo "Error: iperf3 missing."; exit 1; }

  if [ "$NEED_DNS" = "true" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ] && [ -z "$NSLOOKUP_BIN" ]; then
    echo "Error: need at least one DNS tool for domain resolution: dig, host, or nslookup."
    exit 1
  fi

  # Prefer XML mode only when xmllint exists AND this mtr supports XML output (-x/--xml).
  if [ "$MTR" = "true" ]; then
    if [ -n "$XMLLINT_BIN" ] && "$MTR_BIN" -h 2>&1 | grep -qiE '(^|[[:space:]])-x([[:space:],]|$)|--xml'; then
      MTR_OUTPUT_MODE="xml"
    else
      MTR_OUTPUT_MODE="report"
    fi
  fi
}

check_tools_openwrt() {
  OPKG_BIN="$(command -v opkg 2>/dev/null || true)"
  IP_BIN="$(command -v ip 2>/dev/null || true)"
  UBUS_BIN="$(command -v ubus 2>/dev/null || true)"
  JSONFILTER_BIN="$(command -v jsonfilter 2>/dev/null || true)"

  MTR_BIN="$(command -v mtr 2>/dev/null || true)"
  IPERF3_BIN="$(command -v iperf3 2>/dev/null || true)"

  # DNS helpers (only required if domains are used)
  RESOLVEIP_BIN="$(command -v resolveip 2>/dev/null || true)"
  NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
  DIG_BIN="$(command -v dig 2>/dev/null || true)"
  HOST_BIN="$(command -v host 2>/dev/null || true)"

  # If we need DNS helpers and none exist, try to install one when --install-missing is set.
  if [ "$NEED_DNS" = "true" ] && [ -z "$RESOLVEIP_BIN" ] && [ -z "$NSLOOKUP_BIN" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ]; then
    if [ "$AUTO_INSTALL" = "true" ]; then
      # Try bind-dig first; fall back to bind-host.
      install_missing_openwrt "bind-dig" || install_missing_openwrt "bind-host" || true

      RESOLVEIP_BIN="$(command -v resolveip 2>/dev/null || true)"
      NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
      DIG_BIN="$(command -v dig 2>/dev/null || true)"
      HOST_BIN="$(command -v host 2>/dev/null || true)"
    fi
  fi

  if [ "$NEED_DNS" = "true" ] && [ -z "$RESOLVEIP_BIN" ] && [ -z "$NSLOOKUP_BIN" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ]; then
    echo "Error: need at least one resolver tool for domain resolution: resolveip, nslookup, dig, or host."
    echo "On OpenWrt, BusyBox usually provides nslookup. If not, install:"
    echo "  opkg update && opkg install bind-dig (or bind-host)"
    echo "Or rerun with: --install-missing"
    exit 1
  fi

  missing_pkgs=""
  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && missing_pkgs="$missing_pkgs mtr"
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && missing_pkgs="$missing_pkgs iperf3"

  if [ -n "$missing_pkgs" ]; then
    echo "Missing required tools:$missing_pkgs"
    if [ "$AUTO_INSTALL" = "true" ]; then
      install_missing_openwrt "$(trim "$missing_pkgs")" || exit 1
      MTR_BIN="$(command -v mtr 2>/dev/null || true)"
      IPERF3_BIN="$(command -v iperf3 2>/dev/null || true)"
    else
      echo "Install with:"
      echo "  opkg update"
      echo "  opkg install $(trim "$missing_pkgs")"
      echo "Or rerun with: --install-missing"
      exit 1
    fi
  fi

  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && { echo "Error: mtr missing."; exit 1; }
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && { echo "Error: iperf3 missing."; exit 1; }

  [ "$MTR" = "true" ] && MTR_OUTPUT_MODE="report"
}

check_tools_linux() {
  MTR_BIN="$(command -v mtr 2>/dev/null || true)"
  IPERF3_BIN="$(command -v iperf3 2>/dev/null || true)"
  XMLLINT_BIN="$(command -v xmllint 2>/dev/null || true)"

  DIG_BIN="$(command -v dig 2>/dev/null || true)"
  HOST_BIN="$(command -v host 2>/dev/null || true)"
  NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
  GETENT_BIN="$(command -v getent 2>/dev/null || true)"

  missing_pkgs=""
  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && missing_pkgs="$missing_pkgs mtr"
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && missing_pkgs="$missing_pkgs iperf3"

  if [ "$NEED_DNS" = "true" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ] && [ -z "$NSLOOKUP_BIN" ] && [ -z "$GETENT_BIN" ]; then
    dns_pkg="dnsutils"
    command -v dnf >/dev/null 2>&1 && dns_pkg="bind-utils"
    command -v yum >/dev/null 2>&1 && dns_pkg="bind-utils"
    command -v pacman >/dev/null 2>&1 && dns_pkg="bind"
    command -v apk >/dev/null 2>&1 && dns_pkg="bind-tools"
    missing_pkgs="$missing_pkgs $dns_pkg"
  fi

  pkgs="$(trim "$missing_pkgs")"

  if [ -n "$pkgs" ]; then
    echo "Missing required tools/packages: $pkgs"
    if [ "$AUTO_INSTALL" = "true" ]; then
      install_missing_linux "$pkgs" || exit 1

      MTR_BIN="$(command -v mtr 2>/dev/null || true)"
      IPERF3_BIN="$(command -v iperf3 2>/dev/null || true)"
      XMLLINT_BIN="$(command -v xmllint 2>/dev/null || true)"

      DIG_BIN="$(command -v dig 2>/dev/null || true)"
      HOST_BIN="$(command -v host 2>/dev/null || true)"
      NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
      GETENT_BIN="$(command -v getent 2>/dev/null || true)"
    else
      echo "Install with:"
      echo "  $(linux_install_cmd "$pkgs")"
      echo "Or rerun with: --install-missing"
      exit 1
    fi
  fi

  [ "$MTR" = "true" ] && [ -z "$MTR_BIN" ] && { echo "Error: mtr missing."; exit 1; }
  [ "$IPERF3" = "true" ] && [ -z "$IPERF3_BIN" ] && { echo "Error: iperf3 missing."; exit 1; }

  # Prefer XML mode only when xmllint exists AND this mtr supports XML output (-x/--xml).
  if [ "$MTR" = "true" ]; then
    if [ -n "$XMLLINT_BIN" ] && "$MTR_BIN" -h 2>&1 | grep -qiE '(^|[[:space:]])-x([[:space:],]|$)|--xml'; then
      MTR_OUTPUT_MODE="xml"
    else
      MTR_OUTPUT_MODE="report"
    fi
  fi

  if [ "$NEED_DNS" = "true" ] && [ -z "$DIG_BIN" ] && [ -z "$HOST_BIN" ] && [ -z "$NSLOOKUP_BIN" ] && [ -z "$GETENT_BIN" ]; then
    echo "Error: need at least one resolver tool for domain resolution: dig, host, nslookup, or getent."
    echo "On Debian/Ubuntu: sudo apt install dnsutils"
    exit 1
  fi
}

check_tools() {
  case "$PLATFORM" in
    macos) check_tools_macos ;;
    openwrt) check_tools_openwrt ;;
    linux) check_tools_linux ;;
    *)
      echo "Warning: unknown platform. Will try to use PATH tools only."
      MTR_BIN="$(command -v mtr 2>/dev/null || true)"
      IPERF3_BIN="$(command -v iperf3 2>/dev/null || true)"
      XMLLINT_BIN="$(command -v xmllint 2>/dev/null || true)"
      DIG_BIN="$(command -v dig 2>/dev/null || true)"
      HOST_BIN="$(command -v host 2>/dev/null || true)"
      NSLOOKUP_BIN="$(command -v nslookup 2>/dev/null || true)"
      GETENT_BIN="$(command -v getent 2>/dev/null || true)"
      ;;
  esac

}

# ----------------------------
# DNS resolve helper
# ----------------------------
resolve_domain_to_ipv4() {
  domain="$1"
  ip=""

  if [ -n "$RESOLVEIP_BIN" ]; then
    # OpenWrt resolveip usually supports -4/-6; try forcing IPv4 first.
    ip="$("$RESOLVEIP_BIN" -4 "$domain" 2>/dev/null | awk '
      {
        for (i=1;i<=NF;i++) {
          if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) { print $i; exit }
        }
      }' || true)"
    [ -z "$ip" ] && ip="$("$RESOLVEIP_BIN" "$domain" 2>/dev/null | awk '
      {
        for (i=1;i<=NF;i++) {
          if ($i ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/) { print $i; exit }
        }
      }' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$DIG_BIN" ]; then
    ip="$("$DIG_BIN" +short A "$domain" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/ {print; exit}' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$HOST_BIN" ]; then
    ip="$("$HOST_BIN" -t A "$domain" 2>/dev/null | awk '/has address/ {print $4; exit}' | awk '/^[0-9]+(\.[0-9]+){3}$/ {print; exit}' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$NSLOOKUP_BIN" ]; then
    # nslookup prints the resolver's own address before the answer section.
    # If the requested record type doesn't exist, naive parsing can accidentally return that server address.
    # Only accept Address lines after we've entered the answer section.
    ip="$("$NSLOOKUP_BIN" "$domain" 2>/dev/null | awk '
      BEGIN { in_answer=0; last="" }
      /^Non-authoritative answer:/ { in_answer=1; next }
      /^Authoritative answers can be found/ { in_answer=1; next }
      /^Name:[[:space:]]/ { in_answer=1; next }

      /^Address[[:space:]]+[0-9]+:[[:space:]]/ {
        if (!in_answer) next
        a=$3
        sub(/#.*/, "", a)
        if (a ~ /^[0-9]+(\.[0-9]+){3}$/) last=a
      }
      /^Address:[[:space:]]/ {
        if (!in_answer) next
        a=$2
        sub(/#.*/, "", a)
        if (a ~ /^[0-9]+(\.[0-9]+){3}$/) last=a
      }
      END { if (last != "") print last }
    ' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$GETENT_BIN" ]; then
    ip="$("$GETENT_BIN" ahostsv4 "$domain" 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $1; exit}' || true)"
    [ -z "$ip" ] && ip="$("$GETENT_BIN" hosts "$domain" 2>/dev/null | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ {print $1; exit}' || true)"
  fi

  [ -n "$ip" ] && { echo "$ip"; return 0; }
  return 1
}

resolve_domain_to_ipv6() {
  domain="$1"
  ip=""

  if [ -n "$RESOLVEIP_BIN" ]; then
    # OpenWrt resolveip usually supports -4/-6; try forcing IPv6 first.
    ip="$("$RESOLVEIP_BIN" -6 "$domain" 2>/dev/null | awk '
      {
        for (i=1;i<=NF;i++) {
          a=$i
          sub(/#.*/, "", a)
          if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/) { print a; exit }
        }
      }' || true)"
    [ -z "$ip" ] && ip="$("$RESOLVEIP_BIN" "$domain" 2>/dev/null | awk '
      {
        for (i=1;i<=NF;i++) {
          a=$i
          sub(/#.*/, "", a)
          if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/) { print a; exit }
        }
      }' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$DIG_BIN" ]; then
    ip="$("$DIG_BIN" +short AAAA "$domain" 2>/dev/null | awk '/:/ && $0 ~ /^[0-9A-Fa-f:.]+$/ {print; exit}' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$HOST_BIN" ]; then
    ip="$("$HOST_BIN" -t AAAA "$domain" 2>/dev/null | awk '
      /has IPv6 address/ {print $5; exit}
      /IPv6 address/ && /has/ {print $NF; exit}
    ' | awk '/:/ && $0 ~ /^[0-9A-Fa-f:.]+$/ {print; exit}' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$NSLOOKUP_BIN" ]; then
    # nslookup prints the resolver's own address before the answer section.
    # If AAAA doesn't exist, naive parsing can accidentally return the server address (esp. when server is IPv6).
    # Only accept Address lines after we've entered the answer section.
    ip="$("$NSLOOKUP_BIN" "$domain" 2>/dev/null | awk '
      BEGIN { in_answer=0; last="" }
      /^Non-authoritative answer:/ { in_answer=1; next }
      /^Authoritative answers can be found/ { in_answer=1; next }
      /^Name:[[:space:]]/ { in_answer=1; next }

      /^Address[[:space:]]+[0-9]+:[[:space:]]/ {
        if (!in_answer) next
        a=$3
        sub(/#.*/, "", a)
        sub(/%.*/, "", a)
        if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/) last=a
      }
      /^Address:[[:space:]]/ {
        if (!in_answer) next
        a=$2
        sub(/#.*/, "", a)
        sub(/%.*/, "", a)
        if (a ~ /:/ && a ~ /^[0-9A-Fa-f:.]+$/) last=a
      }
      END { if (last != "") print last }
    ' || true)"
  fi

  if [ -z "$ip" ] && [ -n "$GETENT_BIN" ]; then
    ip="$("$GETENT_BIN" ahostsv6 "$domain" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}' || true)"
    [ -z "$ip" ] && ip="$("$GETENT_BIN" hosts "$domain" 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}' || true)"
  fi

  # Normalize (strip brackets/zone if they ever appear)
  ip="$(strip_ipv6_zone "$(strip_enclosing_brackets "$ip")")"
  [ -n "$ip" ] || return 1
  printf '%s\n' "$ip" | grep -q ':' || return 1
  printf '%s\n' "$ip" | grep -Eq '^[0-9A-Fa-f:.]+$' || return 1

  echo "$ip"
  return 0
}

resolve_domain_to_ip() {
  domain="$1"
  fam="${2:-auto}"

  # Normalize family
  fam="$(printf '%s' "$fam" | tr 'A-Z' 'a-z')"
  case "$fam" in
    4|ipv4|v4) fam="4" ;;
    6|ipv6|v6) fam="6" ;;
    auto|"") fam="auto" ;;
    *) fam="auto" ;;
  esac

  case "$fam" in
    4)
      resolve_domain_to_ipv4 "$domain" && return 0
      ;;
    6)
      resolve_domain_to_ipv6 "$domain" && return 0
      ;;
    auto)
      resolve_domain_to_ipv4 "$domain" && return 0
      resolve_domain_to_ipv6 "$domain" && return 0
      ;;
  esac

  return 1
}

# ----------------------------
# Per-run DNS cache (domain + family -> IP)
# Keeps domain resolution stable across interfaces within a single script run.
# ----------------------------
DNS_CACHE=""

dns_norm_domain() {
  # normalize: lowercase + strip trailing dot
  echo "$1" | sed 's/\.$//' | tr 'A-Z' 'a-z'
}

dns_norm_family() {
  f="$(printf '%s' "${1:-auto}" | tr 'A-Z' 'a-z')"
  case "$f" in
    4|ipv4|v4) echo "4" ;;
    6|ipv6|v6) echo "6" ;;
    auto|"") echo "auto" ;;
    *) echo "auto" ;;
  esac
}

dns_cache_get() {
  _k="$1"
  _fam="$2"
  [ -n "$_k" ] || return 1
  _fam="$(dns_norm_family "$_fam")"
  printf '%s\n' "$DNS_CACHE" | awk -v k="$_k" -v f="$_fam" '$1==k && $2==f {print $3; exit}'
}

dns_cache_set() {
  _k="$1"
  _fam="$2"
  _ip="$3"
  [ -n "$_k" ] && [ -n "$_ip" ] || return 0
  _fam="$(dns_norm_family "$_fam")"
  DNS_CACHE="${DNS_CACHE}${_k} ${_fam} ${_ip}
"
}

reverse_dns_lookup() {
  ip_raw="$1"
  ip="$(strip_ipv6_zone "$(strip_enclosing_brackets "$ip_raw")")"
  name=""

  # Fast, local libc/NSS path first (works well on most Linux)
  if [ -z "$name" ] && [ -n "$GETENT_BIN" ]; then
    name="$("$GETENT_BIN" hosts "$ip" 2>/dev/null | awk '{print $2; exit}' || true)"
  fi

  # DNS tools fallback
  if [ -z "$name" ] && [ -n "$HOST_BIN" ]; then
    name="$("$HOST_BIN" "$ip" 2>/dev/null | awk '/domain name pointer/ {print $5; exit}' | sed 's/\.$//' || true)"
  fi

  if [ -z "$name" ] && [ -n "$DIG_BIN" ]; then
    name="$("$DIG_BIN" +short -x "$ip" 2>/dev/null | head -n 1 | sed 's/\.$//' || true)"
  fi

  if [ -z "$name" ] && [ -n "$NSLOOKUP_BIN" ]; then
    name="$("$NSLOOKUP_BIN" "$ip" 2>/dev/null | awk '
      /name =/ {print $4; exit}
      /^Name:/ {print $2; exit}
    ' | sed 's/\.$//' || true)"
  fi

  name="$(echo "$name" | awk '{print $1}')"
  [ -n "$name" ] && { echo "$name"; return 0; }
  return 1
}

validate_ipv6_literal() {
  # Returns normalized IPv6 literal on stdout, or nothing on failure.
  input="$1"
  s="$(strip_enclosing_brackets "$input")"
  addr="$s"
  zone=""

  case "$s" in
    *%*)
      addr="${s%%\%*}"
      zone="${s#*%}"
      ;;
  esac

  # Basic shape checks
  printf '%s\n' "$addr" | grep -q ':' || return 1
  printf '%s\n' "$addr" | grep -Eq '^[0-9A-Fa-f:.]+$' || return 1
  printf '%s\n' "$addr" | grep -q ':::' && return 1

  dbl="$(printf '%s\n' "$addr" | awk -F'::' '{print NF-1}')"
  echo "$dbl" | grep -Eq '^[0-9]+$' || dbl=0
  [ "$dbl" -le 1 ] 2>/dev/null || return 1

  # Full-ish IPv6 validation (supports :: compression and IPv4 tail)
  awk -v a="$addr" '
    function ishex(s){ return (s ~ /^[0-9A-Fa-f]{1,4}$/) }
    function isv4(s,   n,i,oct){
      n=split(s,oct,".")
      if(n!=4) return 0
      for(i=1;i<=4;i++){
        if(oct[i] !~ /^[0-9]+$/) return 0
        if((oct[i]+0) < 0 || (oct[i]+0) > 255) return 0
      }
      return 1
    }
    BEGIN{
      has_double = (index(a,"::")>0)
      n=split(a,parts,":")
      hextets=0
      for(i=1;i<=n;i++){
        p=parts[i]
        if(p=="") continue
        if(p ~ /\./){
          if(i!=n) exit 1
          if(!isv4(p)) exit 1
          hextets += 2
        } else {
          if(!ishex(p)) exit 1
          hextets++
        }
      }
      if(has_double){
        if(hextets>8) exit 1
      } else {
        if(hextets!=8) exit 1
      }
      exit 0
    }' || return 1

  if [ -n "$zone" ]; then
    printf '%s\n' "$zone" | grep -Eq '^[A-Za-z0-9_.-]+$' || return 1
  fi

  printf '%s\n' "$s"
  return 0
}

validate_ip_domain() {
  input="$1"
  input_norm="$(strip_enclosing_brackets "$input")"

  # IPv4
  echo "$input_norm" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  if [ $? -eq 0 ]; then
    oldIFS="$IFS"; IFS=.
    set -- $input_norm
    IFS="$oldIFS"
    for oct in "$@"; do
      case "$oct" in
        ''|*[!0-9]*)
          echo "Error: Invalid IP address: $input"
          return 1
          ;;
      esac
      [ "$oct" -lt 0 ] 2>/dev/null && { echo "Error: Invalid IP address: $input"; return 1; }
      [ "$oct" -gt 255 ] 2>/dev/null && { echo "Error: Invalid IP address: $input"; return 1; }
    done
    echo "$input_norm"
    return 0
  fi

  # IPv6
  if looks_like_ipv6 "$input"; then
    v6="$(validate_ipv6_literal "$input" 2>/dev/null || true)"
    if [ -n "$v6" ]; then
      echo "$v6"
      return 0
    fi
    echo "Error: Invalid IPv6 address: $input"
    return 1
  fi

  # Domain (accept optional trailing dot FQDN like example.com.)
  domain="${input_norm%.}"  # strip ONE trailing dot if present

  if looks_like_domain "$domain"; then
    domain_norm="$(dns_norm_domain "$domain")"
    fam_pref="$(dns_norm_family "${ADDR_FAMILY:-auto}")"

    cached_ip="$(dns_cache_get "$domain_norm" "$fam_pref" 2>/dev/null || true)"
    if [ -n "$cached_ip" ]; then
      echo "$cached_ip"
      return 0
    fi

    resolved_ip="$(resolve_domain_to_ip "$domain_norm" "$fam_pref" 2>/dev/null || true)"
    if [ -z "$resolved_ip" ]; then
      echo "Error: Unable to resolve domain to IP: $input"
      return 1
    fi

    dns_cache_set "$domain_norm" "$fam_pref" "$resolved_ip"
    echo "$resolved_ip"
    return 0
  fi

  echo "Error: Invalid IP or domain: $input"
  return 1
}

# ----------------------------
# mtr parsing (xml / report)
# ----------------------------
parse_mtr_metrics_xml() {
  xml_file="$1"
  tested_ip="$2"

  best="ERROR"
  wrst="ERROR"
  avg="ERROR"
  hops="0"
  loss="ERROR"
  sent="0"
  jitter="ERROR"

  [ -n "$XMLLINT_BIN" ] || {
    echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
    return 0
  }

  if [ ! -s "$xml_file" ]; then
    echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
    return 0
  fi

  # Permission errors
  grep -qiE 'permission denied|operation not permitted|raw socket|must be root' "$xml_file" 2>/dev/null && {
    echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
    return 0
  }

  # Count hops (mtr XML varies: some versions use <hub>, others use <host>)
  hop_xpath="//*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='HUB' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='HOST']"
  hops="$("$XMLLINT_BIN" --xpath "count($hop_xpath)" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  echo "$hops" | grep -Eq '^[0-9]+([.][0-9]+)?$' || hops="0"
  hops="$(awk -v x="$hops" 'BEGIN{printf "%d", x+0}')"

  # If no HUB/HOST nodes exist, fall back to: any node with an ip attribute and RTT/loss metrics
  if [ "$hops" = "0" ]; then
    hop_xpath="//*[(@ip or @IP or @Ip) and ( *[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='BEST' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='AVG' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='WRST' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='LOSS' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='STDEV' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='STDDEV'] or @best or @BEST or @Best or @avg or @AVG or @Avg or @wrst or @WRST or @Wrst or @loss or @LOSS or @Loss )]"
    hops="$("$XMLLINT_BIN" --xpath "count($hop_xpath)" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
    echo "$hops" | grep -Eq '^[0-9]+([.][0-9]+)?$' || hops="0"
    hops="$(awk -v x="$hops" 'BEGIN{printf "%d", x+0}')"
  fi

  # Find the hop matching tested_ip (or fall back to the last hop)
  hub_xpath="($hop_xpath)[./@ip='$tested_ip' or ./@IP='$tested_ip' or ./@Ip='$tested_ip']"
  have_hub="$("$XMLLINT_BIN" --xpath "count($hub_xpath)" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  echo "$have_hub" | grep -Eq '^[0-9]+([.][0-9]+)?$' || have_hub="0"

  if [ "$(awk -v x="$have_hub" 'BEGIN{print (x>0)?1:0}')" -ne 1 ]; then
    hub_xpath="($hop_xpath)[last()]"
  else
    hub_xpath="($hub_xpath)[1]"
  fi

  # Prefer MTRDATA/MTR / MTRNODE tests attribute if exists
  MTRNODE="//*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTR' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTRDATA']"
  # Many versions embed under <mtr><report>...; tests count is often in <MTR> node attributes
  # We'll try common attribute names
  sent="$("$XMLLINT_BIN" --xpath "string((//*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTR']/@tests | //*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTR']/@TESTS)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$sent" ] && sent="$("$XMLLINT_BIN" --xpath "string((//*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTR']/@cnt | //*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='MTR']/@CNT)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  echo "$sent" | grep -Eq '^[0-9]+$' || sent="0"

  best="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='BEST'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  wrst="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='WRST'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  avg="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='AVG'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  loss="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='LOSS'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$best" ] && best="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@best | ($hub_xpath)/@BEST | ($hub_xpath)/@Best)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$wrst" ] && wrst="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@wrst | ($hub_xpath)/@WRST | ($hub_xpath)/@Wrst)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$avg" ]  && avg="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@avg  | ($hub_xpath)/@AVG  | ($hub_xpath)/@Avg)[1])"  "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$loss" ] && loss="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@loss | ($hub_xpath)/@LOSS | ($hub_xpath)/@Loss)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  sent2="$("$XMLLINT_BIN" --xpath "string((($MTRNODE)/@*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='TESTS' or translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='CNT'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  if echo "$sent2" | grep -Eq '^[0-9]+$'; then
    # keep the better value if both exist
    if [ "$sent" = "0" ] || [ "$sent2" -gt "$sent" ]; then
      sent="$sent2"
    fi
  fi

  stdev="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='STDEV'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$stdev" ] && stdev="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/*[translate(local-name(),'abcdefghijklmnopqrstuvwxyz','ABCDEFGHIJKLMNOPQRSTUVWXYZ')='STDDEV'])[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  
  [ -z "$stdev" ] && stdev="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@stdev  | ($hub_xpath)/@STDEV  | ($hub_xpath)/@Stdev)[1])"  "$xml_file" 2>/dev/null | awk '{$1=$1};1')"
  [ -z "$stdev" ] && stdev="$("$XMLLINT_BIN" --xpath "string((($hub_xpath)/@stddev | ($hub_xpath)/@STDDEV | ($hub_xpath)/@Stddev)[1])" "$xml_file" 2>/dev/null | awk '{$1=$1};1')"

  loss="${loss%\%}"

  # Normalize numeric fields to keep downstream comparisons safe
  is_number "$best" && best="$(fmt3 "$best")" || best="ERROR"
  is_number "$wrst" && wrst="$(fmt3 "$wrst")" || wrst="ERROR"
  is_number "$avg" && avg="$(fmt3 "$avg")" || avg="ERROR"
  is_number "$loss" && loss="$(fmt3 "$loss")%" || loss="ERROR"
  echo "$sent" | grep -Eq '^[0-9]+$' || sent="0"

  if is_number "$stdev"; then
    jitter="$(fmt3 "$stdev")"
  elif is_number "$best" && is_number "$wrst"; then
    jitter="$(awk -v b="$best" -v w="$wrst" 'BEGIN{v=w-b; if(v<0) v=-v; printf "%.3f", v}')"
  else
    jitter="ERROR"
  fi

  loss_num="${loss%\%}"
  if [ "$sent" = "0" ] \
     || { is_number "$loss_num" && awk -v l="$loss_num" 'BEGIN{exit !(l>=100)}'; } \
     || { is_number "$avg"  && ! float_gt "$avg" "0"; } \
     || { is_number "$best" && ! float_gt "$best" "0"; } \
     || { is_number "$wrst" && ! float_gt "$wrst" "0"; }; then
    best="ERROR"; wrst="ERROR"; avg="ERROR"; jitter="ERROR"
  fi

  echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
  
}

parse_mtr_metrics_report() {
  file="$1"
  tested_ip="$2"

  best="ERROR"
  wrst="ERROR"
  avg="ERROR"
  hops="0"
  loss="ERROR"
  sent="0"
  jitter="ERROR"

  if [ ! -s "$file" ]; then
    echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
    return 0
  fi

  # Permission errors
  if grep -qiE 'permission denied|operation not permitted|raw socket|must be root' "$file" 2>/dev/null; then
    echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
    return 0
  fi

  # Hop count (always)
  hops="$(awk '/^[[:space:]]*[0-9]+[.]/ {n++} END{print n+0}' "$file" 2>/dev/null || echo 0)"
  [ -z "$hops" ] && hops="0"

  has_stdev="false"
  grep -qE 'StDev|Stdev|StdDev' "$file" 2>/dev/null && has_stdev="true"

  # Prefer the line that matches the tested IP (if present); otherwise fall back to last hop line.
  line="$(awk -v ip="$tested_ip" '
    /^[[:space:]]*[0-9]+[.]/{
      if (ip != "" && ($2==ip || $0 ~ ("\("ip"\)") || $0 ~ ("[[:space:]]"ip"[[:space:]]") || $0 ~ ("[[:space:]]"ip"$"))) {
        cand=$0; found=1
      }
      last=$0
    }
    END{
      if(found) print cand;
      else print last;
    }' "$file" 2>/dev/null)"
  [ -z "$line" ] && line="$(awk '/^[[:space:]]*[0-9]+[.]/ {last=$0} END{print last}' "$file" 2>/dev/null)"

  if [ -n "$line" ]; then
    if [ "$has_stdev" = "true" ]; then
      # With StDev column: index by header "StDev" typically, but assume:
      # Host Loss% Snt Last Avg Best Wrst StDev
      # Use Avg (6), Best (7), Wrst (8), Loss% (3), Snt (4), StDev (9)
      loss="$(echo "$line" | awk '{print $3}' 2>/dev/null)"
      sent="$(echo "$line" | awk '{print $4}' 2>/dev/null)"
      avg="$(echo "$line" | awk '{print $6}' 2>/dev/null)"
      best="$(echo "$line" | awk '{print $7}' 2>/dev/null)"
      wrst="$(echo "$line" | awk '{print $8}' 2>/dev/null)"
      jitter="$(echo "$line" | awk '{print $9}' 2>/dev/null)"
    else
      # Without StDev:
      # Host Loss% Snt Last Avg Best Wrst
      loss="$(echo "$line" | awk '{print $3}' 2>/dev/null)"
      sent="$(echo "$line" | awk '{print $4}' 2>/dev/null)"
      avg="$(echo "$line" | awk '{print $6}' 2>/dev/null)"
      best="$(echo "$line" | awk '{print $7}' 2>/dev/null)"
      wrst="$(echo "$line" | awk '{print $8}' 2>/dev/null)"
      # Fallback jitter estimate = |wrst-best|
      if is_number "$best" && is_number "$wrst"; then
        jitter="$(awk -v b="$best" -v w="$wrst" 'BEGIN{v=w-b; if(v<0) v=-v; printf "%.3f", v}')"
      else
        jitter="ERROR"
      fi
    fi
  fi

  # Normalize numeric fields (avoid ???/blank values)
  loss="${loss%\%}"

  if is_number "$best"; then best="$(fmt3 "$best")"; else best="ERROR"; fi
  if is_number "$wrst"; then wrst="$(fmt3 "$wrst")"; else wrst="ERROR"; fi
  if is_number "$avg";  then avg="$(fmt3 "$avg")";  else avg="ERROR";  fi

  if is_number "$loss"; then
    loss="$(fmt3 "$loss")%"
  else
    loss="ERROR"
  fi

  echo "$sent" | grep -Eq '^[0-9]+$' || sent="0"

  # Jitter: prefer StDev when available; otherwise estimate as |wrst-best|
  if [ "$has_stdev" = "true" ] && is_number "$jitter"; then
    jitter="$(fmt3 "$jitter")"
  elif is_number "$best" && is_number "$wrst"; then
    jitter="$(awk -v b="$best" -v w="$wrst" 'BEGIN{v=w-b; if(v<0) v=-v; printf "%.3f", v}')"
  else
    jitter="ERROR"
  fi

  loss_num="${loss%\%}"
  if [ "$sent" = "0" ] \
     || { is_number "$loss_num" && awk -v l="$loss_num" 'BEGIN{exit !(l>=100)}'; } \
     || { is_number "$avg"  && ! float_gt "$avg" "0"; } \
     || { is_number "$best" && ! float_gt "$best" "0"; } \
     || { is_number "$wrst" && ! float_gt "$wrst" "0"; }; then
    best="ERROR"; wrst="ERROR"; avg="ERROR"; jitter="ERROR"
  fi

  echo "$best|$wrst|$avg|$hops|$loss|$sent|$jitter"
}

mtr_failure_reason() {
  file="$1"

  [ -s "$file" ] || { echo ""; return 0; }
  # macOS (commonly Homebrew mtr): without sudo it can fail with:
  #   "mtr: Failure to start mtr-packet: Invalid argument"
  # Make it obvious how to fix it.
  if [ "$PLATFORM" = "macos" ] && grep -qi "failure to start mtr-packet" "$file" 2>/dev/null; then
    echo "failed to start mtr-packet (macOS). Re-run with --sudo or run this script via sudo."
    return 0
  fi


  # Privilege errors (handled elsewhere too)
  if grep -qiE "$MTR_PERM_RE" "$file" 2>/dev/null; then
    echo "needs elevated privileges for ICMP (raw socket)"
    return 0
  fi

  # Common connectivity/DNS failures across macOS/Linux/OpenWrt
  grep -qi "unknown host" "$file" 2>/dev/null && { echo "unknown host"; return 0; }
  grep -qi "name or service not known" "$file" 2>/dev/null && { echo "name/service not known"; return 0; }
  grep -qi "nodename nor servname provided" "$file" 2>/dev/null && { echo "DNS failure"; return 0; }
  grep -qi "temporary failure in name resolution" "$file" 2>/dev/null && { echo "temporary DNS failure"; return 0; }
  grep -qi "no route to host" "$file" 2>/dev/null && { echo "no route to host"; return 0; }
  grep -qi "network is unreachable" "$file" 2>/dev/null && { echo "network is unreachable"; return 0; }
  grep -qi "host is down" "$file" 2>/dev/null && { echo "host is down"; return 0; }

  # Last resort: show the first error-ish line (short)
  line="$(grep -iE '(^mtr:|\berror\b|\bfailed\b|cannot|permission denied|operation not permitted)' "$file" 2>/dev/null | head -n 1 | awk '{$1=$1};1')"
  [ -n "$line" ] && { echo "$line"; return 0; }

  echo ""
  return 0
}

parse_mtr_metrics() {
  file="$1"
  tested_ip="$2"

  # output vars passed by name
  _best="$3"
  _wrst="$4"
  _avg="$5"
  _hops="$6"
  _loss="$7"
  _sent="$8"
  _jitter="$9"

  out=""

  if [ "$MTR_OUTPUT_MODE" = "xml" ] && [ -n "$XMLLINT_BIN" ]; then
    out="$(parse_mtr_metrics_xml "$file" "$tested_ip")"
  else
    out="$(parse_mtr_metrics_report "$file" "$tested_ip")"
  fi

  best="$(echo "$out" | cut -d'|' -f1)"
  wrst="$(echo "$out" | cut -d'|' -f2)"
  avg="$(echo "$out" | cut -d'|' -f3)"
  hops="$(echo "$out" | cut -d'|' -f4)"
  loss="$(echo "$out" | cut -d'|' -f5)"
  sent="$(echo "$out" | cut -d'|' -f6)"
  jitter="$(echo "$out" | cut -d'|' -f7)"

  eval "$_best=\"\$best\""
  eval "$_wrst=\"\$wrst\""
  eval "$_avg=\"\$avg\""
  eval "$_hops=\"\$hops\""
  eval "$_loss=\"\$loss\""
  eval "$_sent=\"\$sent\""
  eval "$_jitter=\"\$jitter\""
}

# ----------------------------
# mtr runner
# ----------------------------
run_mtr_baseline() {
  ip="$1"
  iface="$2"
  iface_display="${3:-}"

  # Reset baseline vars
  MTR_BEST="ERROR"
  MTR_WRST="ERROR"
  MTR_AVG="ERROR"
  MTR_HOPS="0"
  MTR_LOSS="ERROR"
  MTR_SENT="0"
  MTR_JITTER="ERROR"

  MTR_OUT_FILE="$(mktemp_file mtr_base)" || return 1

  count="$MTR_COUNT"
  interval="$MTR_INTERVAL"

  # Build command list
  if [ "$MTR_OUTPUT_MODE" = "xml" ]; then
    set -- "$MTR_BIN" -rwxb -n -i "$interval" -c "$count"
  else
    set -- "$MTR_BIN" -r -w -n -i "$interval" -c "$count"
  fi

  case "$MTR_PROBE" in
    icmp) : ;;
    udp) set -- "$@" -u ;;
    tcp) set -- "$@" -T ;;
    *) echo "Error: invalid --mtr-probe '$MTR_PROBE' (use icmp|udp|tcp)"; return 1 ;;
  esac

  # Port for tcp/udp probes (if requested)
  if [ "$MTR_PROBE" = "tcp" ] || [ "$MTR_PROBE" = "udp" ]; then
    if [ -n "${MTR_PORT:-}" ] && echo "$MTR_PORT" | grep -Eq '^[0-9]+$' && [ "$MTR_PORT" -gt 0 ] 2>/dev/null; then
      set -- "$@" -P "$MTR_PORT"
    fi
  fi

  [ -n "$iface" ] && set -- "$@" -I "$iface"
  set -- "$@" "$ip"

  use_sudo="false"
  # If we're already root, never prefix sudo (even with --sudo).
  if [ "$(id -u)" -ne 0 ] && { [ "$MTR_USE_SUDO" = "true" ] || [ "$SUDO_MODE" = "force" ]; }; then
    use_sudo="true"
  fi

  if [ "$PLATFORM" = "openwrt" ]; then
    if [ "$SUDO_MODE" = "force" ] && [ "$(id -u)" -ne 0 ]; then
      echo "Error: --sudo not supported on OpenWrt (no sudo by default). Run as root or use --mtr-probe tcp/udp."
      return 1
    fi
    use_sudo="false"
  fi

  if [ "$use_sudo" = "true" ]; then
    ensure_sudo || {
      echo "Error: sudo requested but unavailable or not authenticated."
      return 1
    }
    set -- sudo -n "$@"
    MTR_USE_SUDO=true
  fi

  cmd_str="$*"
  if [ -n "$iface_display" ]; then
    mtr_msg="mtr: $iface_display => $ip..."
    mtr_msg_sudo="mtr: $iface_display => $ip (sudo)..."
  elif [ -n "$iface" ]; then
    mtr_msg="mtr: $iface => $ip..."
    mtr_msg_sudo="mtr: $iface => $ip (sudo)..."
  else
    mtr_msg="mtr: (default) => $ip..."
    mtr_msg_sudo="mtr: (default) => $ip (sudo)..."
  fi

  run_cmd_bg "$mtr_msg" "$MTR_OUT_FILE" "$@"

  rc=$?

  # Detect privilege failures (common on macOS without sudo for ICMP)
  perm_hit="false"
  if grep -qiE "$MTR_PERM_RE" "$MTR_OUT_FILE" 2>/dev/null; then
    perm_hit="true"
  fi
  # macOS Homebrew mtr can fail without sudo with: "Failure to start mtr-packet: Invalid argument"
  if [ "$PLATFORM" = "macos" ] && grep -qi "failure to start mtr-packet" "$MTR_OUT_FILE" 2>/dev/null; then
    perm_hit="true"
  fi

  # Auto-escalate only on privilege failures (not on random errors)
  if [ "$(id -u)" -ne 0 ] && [ "$SUDO_MODE" = "auto" ] && [ "$MTR_USE_SUDO" = "false" ] && [ "$PLATFORM" != "openwrt" ] && [ "$perm_hit" = "true" ]; then

    if ensure_sudo; then
      if [ "$MTR_OUTPUT_MODE" = "xml" ]; then
        set -- sudo -n "$MTR_BIN" -rwxb -n -i "$interval" -c "$count"
      else
        set -- sudo -n "$MTR_BIN" -r -w -n -i "$interval" -c "$count"
      fi

      case "$MTR_PROBE" in
        icmp) : ;;
        udp) set -- "$@" -u ;;
        tcp) set -- "$@" -T ;;
      esac

      if [ "$MTR_PROBE" = "tcp" ] || [ "$MTR_PROBE" = "udp" ]; then
        if [ -n "${MTR_PORT:-}" ] && echo "$MTR_PORT" | grep -Eq '^[0-9]+$' && [ "$MTR_PORT" -gt 0 ] 2>/dev/null; then
          set -- "$@" -P "$MTR_PORT"
        fi
      fi

      [ -n "$iface" ] && set -- "$@" -I "$iface"
      set -- "$@" "$ip"

      cmd_str="$*"
      MTR_USE_SUDO=true
      run_cmd_bg "$mtr_msg_sudo" "$MTR_OUT_FILE" "$@"
      rc=$?
    else
      add_error "mtr: needs elevated privileges for ICMP here; sudo was not granted. Re-run with sudo (or pass --sudo) or try --mtr-probe tcp/udp."
      rc=1
    fi
  fi

  # If sudo is disabled, still report why mtr is ERROR
  if [ "$SUDO_MODE" = "never" ] && grep -qiE "$MTR_PERM_RE" "$MTR_OUT_FILE" 2>/dev/null; then
    add_error "mtr: needs elevated privileges for ICMP here. Re-run with sudo (or pass --sudo) or try --mtr-probe tcp/udp."
    rc=1
  fi

  # Log
  if [ "$LOG" = "true" ]; then
    if ! {
      echo "=================================================================================="
      echo "# $cmd_str"
      cat "$MTR_OUT_FILE"
    } >> "$LOG_FILE" 2>/dev/null; then
      echo "Warning: failed to append to log file '$LOG_FILE' (logging disabled)." >&2
      LOG=false
      LOG_FILE=""
    fi
  fi

  # Parse into globals
  parse_mtr_metrics "$MTR_OUT_FILE" "$ip" MTR_BEST MTR_WRST MTR_AVG MTR_HOPS MTR_LOSS MTR_SENT MTR_JITTER
  
  # If mtr couldn't reach the destination, RTT metrics may come out as 0.000 on some versions.
  # After parsing, if we ended up with ERROR metrics (or mtr returned non-zero), emit a clear reason.
  if [ "$rc" -ne 0 ] 2>/dev/null || [ "$MTR_AVG" = "ERROR" ]; then
    mtr_reason="$(mtr_failure_reason "$MTR_OUT_FILE")"

    if [ -z "$mtr_reason" ]; then
      loss_num="${MTR_LOSS%\%}"
      if is_number "$loss_num" && awk -v l="$loss_num" 'BEGIN{exit !(l>=100)}'; then
        mtr_reason="destination unreachable (100% loss)"
      fi
    fi

    [ -n "$mtr_reason" ] && add_error "mtr: $mtr_reason"
  fi

  return $rc
}


# ----------------------------
# iperf3
# ----------------------------
iperf3_supports_connect_timeout() {
  "$IPERF3_BIN" -h 2>&1 | grep -q "connect-timeout"
}

expand_iperf3_port_spec() {
  # Expands a port spec like:
  #   5201
  #   5201-5210
  #   5201,5202-5204
  # into a space-separated list: "5201 5202 5203 5204"
  spec="$(printf "%s" "${1:-}" | awk '{gsub(/[[:space:]]/, ""); print}')"
  [ -z "$spec" ] && { echo ""; return 0; }

  out=""
  old_ifs="$IFS"
  IFS=','

  # Split on commas into "$@"
  set -- $spec

  IFS="$old_ifs"
  for tok in "$@"; do
    [ -z "$tok" ] && continue

    if printf "%s" "$tok" | grep -Eq '^[0-9]+$'; then
      p="$tok"
      [ "$p" -ge 1 ] 2>/dev/null && [ "$p" -le 65535 ] 2>/dev/null || {
        echo "Error: --iperf3-port out of range (1-65535): $p" >&2
        return 1
      }
      out="$out $p"
      continue
    fi

    if printf "%s" "$tok" | grep -Eq '^[0-9]+-[0-9]+$'; then
      a="${tok%-*}"
      b="${tok#*-}"
      [ "$a" -ge 1 ] 2>/dev/null && [ "$a" -le 65535 ] 2>/dev/null || {
        echo "Error: --iperf3-port out of range (1-65535): $a" >&2
        return 1
      }
      [ "$b" -ge 1 ] 2>/dev/null && [ "$b" -le 65535 ] 2>/dev/null || {
        echo "Error: --iperf3-port out of range (1-65535): $b" >&2
        return 1
      }
      [ "$a" -le "$b" ] 2>/dev/null || {
        echo "Error: invalid --iperf3-port range '$tok' (start > end)" >&2
        return 1
      }

      out="$out $(awk -v s="$a" -v e="$b" 'BEGIN{for(i=s;i<=e;i++){printf i; if(i<e) printf " "}}')"
      continue
    fi

    echo "Error: invalid --iperf3-port spec '$tok' (use N, N-M, or comma lists)" >&2
    return 1
  done

  echo "$out" | awk '{$1=$1};1'
}

iperf3_failure_reason() {
  file="$1"

  [ -s "$file" ] || { echo "unable to connect"; return 0; }

  # Common connection errors (keep these short / consistent)
  grep -qi "unable to connect to server" "$file" 2>/dev/null && { echo "unable to connect"; return 0; }
  grep -qi "connection refused" "$file" 2>/dev/null && { echo "connection refused"; return 0; }
  grep -qi "no route to host" "$file" 2>/dev/null && { echo "no route to host"; return 0; }
  grep -qi "network is unreachable" "$file" 2>/dev/null && { echo "network is unreachable"; return 0; }

  # Generic: pick the first informative line
  line="$(grep -iE 'iperf3: error|\berror\b|\bfailed\b' "$file" 2>/dev/null | head -n 1 | awk '{$1=$1};1')"
  [ -n "$line" ] && { echo "$line"; return 0; }

  echo ""
  return 0
}

calc_iperf_avg_mbps() {
  file="$1"
  role="$2" # sender|receiver

  # Canonical iperf3 throughput is the final summary line.
  # With -P > 1, iperf3 prints many interval [SUM] lines; take the *last* matching [SUM] line for the role.
  v="$(awk -v role="$role" '
    /Mbits\/sec/ && /\[SUM\]/ && $0 ~ ("[[:space:]]" role "([[:space:]]|$)") {
      for (i = 1; i <= NF; i++) if ($i == "Mbits/sec") val=$(i-1)
    }
    END { if (val != "") print val }
  ' "$file" 2>/dev/null)"

  # Fallback for single-stream output (no [SUM]): take the last matching role line.
  if [ -z "$v" ]; then
    v="$(awk -v role="$role" '
      /Mbits\/sec/ && $0 ~ ("[[:space:]]" role "([[:space:]]|$)") {
        for (i = 1; i <= NF; i++) if ($i == "Mbits/sec") val=$(i-1)
      }
      END { if (val != "") print val }
    ' "$file" 2>/dev/null)"
  fi

  if [ -z "$v" ]; then
    echo "ERROR"
    return 0
  fi

  # normalize formatting
  awk -v x="$v" 'BEGIN{
    if (x ~ /^[0-9]+(\.[0-9]+)?$/) printf "%.3f", x; else print "ERROR"
  }'
}

start_mtr_load() {
  # start a load mtr into a given file; sets BG_PID
  ip="$1"
  iface="$2"
  outfile="$3"
  count="$4"

  [ -z "$count" ] && count="$MTR_COUNT"
  interval="$MTR_INTERVAL"

  # Build command
  if [ "$MTR_OUTPUT_MODE" = "xml" ]; then
    set -- "$MTR_BIN" -rwxb -n -i "$interval" -c "$count"
  else
    set -- "$MTR_BIN" -r -w -n -i "$interval" -c "$count"
  fi

  case "$MTR_PROBE" in
    icmp) : ;;
    udp) set -- "$@" -u ;;
    tcp) set -- "$@" -T ;;
    *) : ;;
  esac

  if [ "$MTR_PROBE" = "tcp" ] || [ "$MTR_PROBE" = "udp" ]; then
    if [ -n "${MTR_PORT:-}" ] && echo "$MTR_PORT" | grep -Eq '^[0-9]+$' && [ "$MTR_PORT" -gt 0 ] 2>/dev/null; then
      set -- "$@" -P "$MTR_PORT"
    fi
  fi

  [ -n "$iface" ] && set -- "$@" -I "$iface"
  set -- "$@" "$ip"

  # sudo prefix if already in use / forced (never needed when already root)
  if [ "$(id -u)" -ne 0 ] && [ "$PLATFORM" != "openwrt" ] && { [ "$MTR_USE_SUDO" = "true" ] || [ "$SUDO_MODE" = "force" ]; }; then
    ensure_sudo >/dev/null 2>&1 || true
    if sudo -n true 2>/dev/null; then
      set -- sudo -n "$@"
      MTR_USE_SUDO=true
    fi
  fi

  start_cmd_bg "$outfile" "$@"
}

# Results from iperf3_run_with_port_fallback()
IPERF3_SELECTED_PORT=""
IPERF3_LAST_RC=1
IPERF3_LAST_MTR_OUT=""

iperf3_run_with_port_fallback() {
  # Usage:
  #   iperf3_run_with_port_fallback <iperf_outfile> <dir_label> <spinner_msg> <ip> <iface_dev> <mtr_count> <role> <iperf3 args...>

  pf_iperf_out="$1"
  pf_dir_label="$2"
  pf_spinner_msg="$3"
  pf_ip="$4"
  pf_iface_dev="$5"
  pf_mtr_count="$6"
  pf_role="$7"
  shift 7
  
  # Human label for notices/logs
  case "$pf_dir_label" in
    up) pf_dir_human="upload" ;;
    down) pf_dir_human="download" ;;
    *) pf_dir_human="$pf_dir_label" ;;
  esac

  pf_ports="${IPERF3_PORT_LIST:-}"
  [ -z "$pf_ports" ] && pf_ports="__DEFAULT__"

  pf_last_port="$(printf "%s" "$pf_ports" | awk '{print $NF}')"
  pf_retry_note=""
  pf_failed_ports=""

  IPERF3_SELECTED_PORT=""
  IPERF3_LAST_RC=1
  IPERF3_LAST_MTR_OUT=""

  for pf_port in $pf_ports; do
    pf_mtr_out=""
    pf_mtr_pid=""

    # Run load-mtr per attempt so failed ports don't stall retries
    if [ "$MTR" = "true" ]; then
      pf_mtr_out="$(mktemp_file "mtr_${pf_dir_label}")" || pf_mtr_out=""
      if [ -n "$pf_mtr_out" ]; then
        start_mtr_load "$pf_ip" "$pf_iface_dev" "$pf_mtr_out" "$pf_mtr_count"
        pf_mtr_pid="$BG_PID"
      fi
    fi

    if [ "$pf_port" = "__DEFAULT__" ]; then
      start_cmd_bg "$pf_iperf_out" "$@"
    else
      start_cmd_bg "$pf_iperf_out" "$@" -p "$pf_port"
    fi
    pf_pid="$BG_PID"

    # Spinner text: include port being tried; if previous port failed, show switch note on the next attempt.
    pf_attempt_msg="$pf_spinner_msg"
    if [ -n "${IPERF3_PORT_SPEC_DISPLAY:-}" ]; then
      if [ "$pf_port" = "__DEFAULT__" ]; then
        pf_attempt_msg="$pf_attempt_msg (port default)"
      else
        pf_attempt_msg="$pf_attempt_msg (port $pf_port)"
      fi
      [ -n "$pf_retry_note" ] && pf_attempt_msg="$pf_attempt_msg; $pf_retry_note"
    fi
    pf_attempt_msg="$pf_attempt_msg..."
    show_spinner "$pf_pid" "$pf_attempt_msg"

    wait "$pf_pid" 2>/dev/null
    pf_rc=$?
    clear_spinner_line
    unregister_bg_pid "$pf_pid"

    pf_reason="$(iperf3_failure_reason "$pf_iperf_out")"
    # Treat any detected failure reason as a failed attempt even if rc==0 (rare, but keeps state consistent)
    [ -n "$pf_reason" ] && pf_rc=1
    if [ "$pf_rc" -eq 0 ] 2>/dev/null && [ -z "$pf_reason" ]; then
      pf_avg="$(calc_iperf_avg_mbps "$pf_iperf_out" "$pf_role")"

      # If iperf3 produced no parsable throughput, treat as failure (even if rc==0)
      if [ -n "$pf_avg" ] && [ "$pf_avg" != "ERROR" ]; then
        IPERF3_LAST_RC="$pf_rc"
        IPERF3_LAST_MTR_OUT="$pf_mtr_out"
        if [ "$pf_port" != "__DEFAULT__" ]; then
          IPERF3_SELECTED_PORT="$pf_port"
        fi
        if [ -n "$pf_mtr_pid" ]; then
          # Keep the spinner alive while the under-load mtr finishes (otherwise UI goes blank here)
          case "$pf_dir_label" in
            up) _mtr_phase="upload" ;;
            down) _mtr_phase="download" ;;
            *) _mtr_phase="$pf_dir_label" ;;
          esac

          show_spinner "$pf_mtr_pid" "mtr during ${_mtr_phase}: $pf_ip..."
          wait "$pf_mtr_pid" 2>/dev/null || true
          unregister_bg_pid "$pf_mtr_pid"
          clear_spinner_line
        fi
        if [ "${IPERF3_PORT_IS_RANGE:-false}" = "true" ] && [ -n "$pf_failed_ports" ]; then
          pf_failed_ports="$(printf "%s" "$pf_failed_ports" | awk '{$1=$1};1')"
          pf_succ_port="$pf_port"
          [ "$pf_succ_port" = "__DEFAULT__" ] && pf_succ_port="default"
          add_notice "iperf3 ${pf_dir_human}: port fallback had failures (failed ports: $pf_failed_ports; succeeded on $pf_succ_port)"
        fi
        return 0
      fi
      pf_reason="no result (throughput parse failed)"
      pf_rc=1
    fi

    IPERF3_LAST_RC="$pf_rc"

    # Stop load-mtr immediately on failure so we can retry on next port
    if [ -n "$pf_mtr_pid" ]; then
      kill_pid_tree "$pf_mtr_pid"
      wait "$pf_mtr_pid" 2>/dev/null || true
      unregister_bg_pid "$pf_mtr_pid"
    fi
        # If using a port range/list, keep failed-attempt output in the log before the next run overwrites pf_iperf_out.
    if [ "${IPERF3_PORT_IS_RANGE:-false}" = "true" ] && [ "$pf_rc" -ne 0 ] 2>/dev/null; then
      pf_port_label="$pf_port"
      [ "$pf_port_label" = "__DEFAULT__" ] && pf_port_label="default"

      pf_fail_reason="$pf_reason"
      if [ -z "$pf_fail_reason" ]; then
        if [ ! -s "$pf_iperf_out" ]; then
          pf_fail_reason="no output"
        else
          pf_fail_reason="failed (exit $pf_rc)"
        fi
      fi

      pf_failed_ports="${pf_failed_ports} $pf_port_label"

      # Log only when another port will be tried (avoids duplicating the final attempt, which run_iperf3 logs anyway)
      if [ "$LOG" = "true" ] && [ -n "${LOG_FILE:-}" ] && [ "$pf_port" != "$pf_last_port" ]; then
        pf_cmd_str="$*"
        [ "$pf_port" != "__DEFAULT__" ] && pf_cmd_str="$pf_cmd_str -p $pf_port"
        if ! {
          echo "----------------------------------------------------------------------------------"
          echo "# iperf3 ${pf_dir_human} attempt failed (port $pf_port_label): $pf_cmd_str"
          echo "# reason: $pf_fail_reason"
          cat "$pf_iperf_out" 2>/dev/null || true
          if [ -n "$pf_mtr_out" ] && [ -s "$pf_mtr_out" ]; then
            echo "----------------------------------------------------------------------------------"
            echo "# mtr during failed ${pf_dir_human} attempt (port $pf_port_label)"
            cat "$pf_mtr_out" 2>/dev/null || true
          fi
        } >> "$LOG_FILE" 2>/dev/null; then
          echo "Warning: failed to append to log file '$LOG_FILE' (logging disabled)." >&2
          LOG=false
          LOG_FILE=""
        fi
      fi
    fi
    [ -n "$pf_mtr_out" ] && rm -f "$pf_mtr_out" 2>/dev/null || true

    # For the next attempt, show that we failed and are switching ports (only when a custom spec exists and more ports remain).
    if [ -n "${IPERF3_PORT_SPEC_DISPLAY:-}" ] && [ "$pf_port" != "$pf_last_port" ]; then
      pf_retry_note="port $pf_port failed; switching"
    else
      pf_retry_note=""
    fi
  done

  return 1
}

run_iperf3() {
  # Usage:
  #   run_iperf3 <ip> <iface_display> <iface_dev> <iface_ip>
  #
  # Notes:
  #   - iface_ip is the source IP (IPv4 or IPv6) to bind (-B) for iperf3; empty means "unbound" (default routing).
  #   - iface_dev is only used for mtr-under-load binding (-I); pass empty to keep it unbound.

  ip="$1"
  iface_display="$2"
  iface_dev="$3"
  iface_ip="$4"

  IPERF_UPLOAD_AVG="0"
  IPERF_DOWNLOAD_AVG="0"
  upload_speed="0 Mbits/sec"
  download_speed="0 Mbits/sec"

  # Reset load mtr metrics
  MTR_UP_BEST="ERROR"
  MTR_UP_WRST="ERROR"
  MTR_UP_AVG="ERROR"
  MTR_UP_HOPS="ERROR"
  MTR_UP_LOSS="ERROR"
  MTR_UP_SENT="0"
  MTR_UP_JITTER="ERROR"

  MTR_DOWN_BEST="ERROR"
  MTR_DOWN_WRST="ERROR"
  MTR_DOWN_AVG="ERROR"
  MTR_DOWN_HOPS="ERROR"
  MTR_DOWN_LOSS="ERROR"
  MTR_DOWN_SENT="0"
  MTR_DOWN_JITTER="ERROR"

  up_out="$(mktemp_file iperf_up)" || return 1
  down_out="$(mktemp_file iperf_down)" || return 1

  # Build iperf base args
  set -- "$IPERF3_BIN" -c "$ip" -f m -t "$IPERF3_TIME" -P "$IPERF3_PARALLEL"
  if iperf3_supports_connect_timeout && [ "${CONNECT_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
    set -- "$@" --connect-timeout "$CONNECT_TIMEOUT"
  fi
  [ -n "$iface_ip" ] && set -- "$@" -B "$iface_ip"
  base_cmd="$*"

  # Derive how many mtr cycles to run during load.
  mtr_load_count="${MTR_LOAD_COUNT:-}"
  if [ -z "$mtr_load_count" ]; then
    load_secs="$IPERF3_TIME"
    echo "$load_secs" | grep -Eq '^[0-9]+$' || load_secs="$MTR_COUNT"
    [ "$load_secs" -lt 1 ] 2>/dev/null && load_secs=1

    if is_number "$MTR_INTERVAL" && float_gt "$MTR_INTERVAL" "0"; then
      mtr_load_count="$(awk -v s="$load_secs" -v i="$MTR_INTERVAL" 'BEGIN{c=int(s/i); if(c<1) c=1; printf "%d", c}')"
    else
      mtr_load_count="$load_secs"
    fi
  fi

  # Upload
  up_mtr_out=""
  UP_PORT_USED=""
  up_msg="iperf3 upload: $iface_display => $ip"

  iperf3_run_with_port_fallback "$up_out" "up" "$up_msg" "$ip" "$iface_dev" "$mtr_load_count" "sender" "$@"
  up_rc="$IPERF3_LAST_RC"
  up_mtr_out="$IPERF3_LAST_MTR_OUT"
  UP_PORT_USED="$IPERF3_SELECTED_PORT"

  if [ -n "$up_mtr_out" ] && [ -s "$up_mtr_out" ]; then
    parse_mtr_metrics "$up_mtr_out" "$ip" MTR_UP_BEST MTR_UP_WRST MTR_UP_AVG MTR_UP_HOPS MTR_UP_LOSS MTR_UP_SENT MTR_UP_JITTER
  fi
  
  # Surface under-load mtr failures (otherwise you only see ERROR metrics)
  if [ -n "$up_mtr_out" ]; then
    up_mtr_reason="$(mtr_failure_reason "$up_mtr_out")"
    if [ -n "$up_mtr_reason" ] || [ ! -s "$up_mtr_out" ] || [ "$MTR_UP_AVG" = "ERROR" ]; then
      if [ -z "$up_mtr_reason" ]; then
        loss_num="${MTR_UP_LOSS%\%}"
        if is_number "$loss_num" && awk -v l="$loss_num" 'BEGIN{exit (l<100)}'; then
          up_mtr_reason="destination unreachable (100% loss)"
        elif [ ! -s "$up_mtr_out" ]; then
          up_mtr_reason="no output (mtr failed during upload)"
        else
          up_mtr_reason="unparseable output (see logs)"
        fi
      fi
      add_notice "mtr during upload: $up_mtr_reason"
      # If you want it under "Errors:" instead of "Note:", change add_notice -> add_error
    fi
  fi

  # Download
  down_mtr_out=""
  DOWN_PORT_USED=""
  down_msg="iperf3 download: $iface_display => $ip"

  iperf3_run_with_port_fallback "$down_out" "down" "$down_msg" "$ip" "$iface_dev" "$mtr_load_count" "receiver" "$@" -R
  down_rc="$IPERF3_LAST_RC"
  down_mtr_out="$IPERF3_LAST_MTR_OUT"
  DOWN_PORT_USED="$IPERF3_SELECTED_PORT"

  if [ -n "$down_mtr_out" ] && [ -s "$down_mtr_out" ]; then
    parse_mtr_metrics "$down_mtr_out" "$ip" MTR_DOWN_BEST MTR_DOWN_WRST MTR_DOWN_AVG MTR_DOWN_HOPS MTR_DOWN_LOSS MTR_DOWN_SENT MTR_DOWN_JITTER
  fi
  
  # Surface under-load mtr failures (otherwise you only see ERROR metrics)
  if [ -n "$down_mtr_out" ]; then
    down_mtr_reason="$(mtr_failure_reason "$down_mtr_out")"
    if [ -n "$down_mtr_reason" ] || [ ! -s "$down_mtr_out" ] || [ "$MTR_DOWN_AVG" = "ERROR" ]; then
      if [ -z "$down_mtr_reason" ]; then
        loss_num="${MTR_DOWN_LOSS%\%}"
        if is_number "$loss_num" && awk -v l="$loss_num" 'BEGIN{exit (l<100)}'; then
          down_mtr_reason="destination unreachable (100% loss)"
        elif [ ! -s "$down_mtr_out" ]; then
          down_mtr_reason="no output (mtr failed during download)"
        else
          down_mtr_reason="unparseable output (see logs)"
        fi
      fi
      add_notice "mtr during download: $down_mtr_reason"
      # If you want it under "Errors:" instead of "Note:", change add_notice -> add_error
    fi
  fi

  # Parse iperf3 results
  up_reason="$(iperf3_failure_reason "$up_out")"
  if [ "${up_rc:-0}" -ne 0 ] 2>/dev/null || [ -n "$up_reason" ]; then
    upload_speed="ERROR"
    IPERF_UPLOAD_AVG="ERROR"
    if [ -n "$up_reason" ]; then
      add_notice "iperf3 upload: $up_reason"
    else
      add_notice "iperf3 upload: failed (exit $up_rc)"
    fi
  else
    IPERF_UPLOAD_AVG="$(calc_iperf_avg_mbps "$up_out" "sender")"
    if is_number "$IPERF_UPLOAD_AVG"; then
      upload_speed="${IPERF_UPLOAD_AVG} Mbits/sec"
    else
      upload_speed="ERROR"
      IPERF_UPLOAD_AVG="ERROR"
      add_notice "iperf3 upload: no result"
    fi
  fi

  down_reason="$(iperf3_failure_reason "$down_out")"
  if [ "${down_rc:-0}" -ne 0 ] 2>/dev/null || [ -n "$down_reason" ]; then
    download_speed="ERROR"
    IPERF_DOWNLOAD_AVG="ERROR"
    if [ -n "$down_reason" ]; then
      add_notice "iperf3 download: $down_reason"
    else
      add_notice "iperf3 download: failed (exit $down_rc)"
    fi
  else
    IPERF_DOWNLOAD_AVG="$(calc_iperf_avg_mbps "$down_out" "receiver")"
    if is_number "$IPERF_DOWNLOAD_AVG"; then
      download_speed="${IPERF_DOWNLOAD_AVG} Mbits/sec"
    else
      download_speed="ERROR"
      IPERF_DOWNLOAD_AVG="ERROR"
      add_notice "iperf3 download: no result"
    fi
  fi

  # Port-range note
  if [ "${IPERF3_PORT_IS_RANGE:-false}" = "true" ]; then
    # In range/list mode, an empty *_PORT_USED means no port produced a valid iperf3 result.
    # (Future-proof: if a "__DEFAULT__" ever gets included, show it as default (5201) only on success.)
    if [ -n "${UP_PORT_USED:-}" ]; then
      up_used="$UP_PORT_USED"
    else
      if [ "${up_rc:-1}" -eq 0 ] 2>/dev/null && [ "${IPERF_UPLOAD_AVG:-ERROR}" != "ERROR" ]; then
        up_used="default (5201)"
      else
        up_used="failed"
      fi
    fi

    if [ -n "${DOWN_PORT_USED:-}" ]; then
      down_used="$DOWN_PORT_USED"
    else
      if [ "${down_rc:-1}" -eq 0 ] 2>/dev/null && [ "${IPERF_DOWNLOAD_AVG:-ERROR}" != "ERROR" ]; then
        down_used="default (5201)"
      else
        down_used="failed"
      fi
    fi

    add_notice "iperf3 port-range used: upload ${up_used}; download ${down_used}"
  fi

  # Logging
  if [ "$LOG" = "true" ]; then
    if ! {
      echo "=================================================================================="
      up_cmd="$base_cmd"
      [ -n "${UP_PORT_USED:-}" ] && up_cmd="$up_cmd -p $UP_PORT_USED"
      echo "# iperf3 upload: $up_cmd"
      cat "$up_out"
      if [ -n "$up_mtr_out" ]; then
        echo "----------------------------------------------------------------------------------"
        echo "# mtr during upload"
        cat "$up_mtr_out" 2>/dev/null || true
      fi
      echo "=================================================================================="
      down_cmd="$base_cmd -R"
      [ -n "${DOWN_PORT_USED:-}" ] && down_cmd="$down_cmd -p $DOWN_PORT_USED"
      echo "# iperf3 download: $down_cmd"
      cat "$down_out"
      if [ -n "$down_mtr_out" ]; then
        echo "----------------------------------------------------------------------------------"
        echo "# mtr during download"
        cat "$down_mtr_out" 2>/dev/null || true
      fi
    } >> "$LOG_FILE" 2>/dev/null; then
      echo "Warning: failed to append to log file '$LOG_FILE' (logging disabled)." >&2
      LOG=false
      LOG_FILE=""
    fi
  fi

  rm -f "$up_out" "$down_out" 2>/dev/null || true
  [ -n "$up_mtr_out" ] && rm -f "$up_mtr_out" 2>/dev/null || true
  [ -n "$down_mtr_out" ] && rm -f "$down_mtr_out" 2>/dev/null || true

  return 0
}

# ----------------------------
# Test runner
# ----------------------------
print_target_table() {
  # Fixed-width columns so the '|' stays aligned (more reliable than juggling \t).
  # "Download:" is 9 chars, speed column is wide enough for "12345.67 Mbits/sec"
  LABEL_W=9
  SPEED_W=18

  if [ "$MTR" = "true" ]; then
    printf "%s%-9s%s %-18s %s|%s %sPing:%s %s ms  %sLoss:%s %s  %sJitter:%s %s ms  [ %sHops:%s %s; %sBest:%s %s ms; %sWrst:%s %s ms ]\n" \
      "$GREEN" "Idle:" "$NC" "" \
      "$GREEN" "$NC" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_AVG")" \
      "$GREEN" "$NC" "$(cval_pad 9 "$(fmt_pct_sp "$MTR_LOSS")")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_JITTER")" \
      "$GREEN" "$NC" "$(cval_pad 3 "$MTR_HOPS")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_BEST")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_WRST")"
  fi

  [ "$IPERF3" = "true" ] || return 0

  up_speed="$(fmt_speed_mbps "$IPERF_UPLOAD_AVG")"
  down_speed="$(fmt_speed_mbps "$IPERF_DOWNLOAD_AVG")"

  if [ "$MTR" = "true" ]; then
    up_bloat="$(calc_delta_ms "$MTR_AVG" "$MTR_UP_AVG")"
    down_bloat="$(calc_delta_ms "$MTR_AVG" "$MTR_DOWN_AVG")"
    up_jbloat="$(calc_delta_ms "$MTR_JITTER" "$MTR_UP_JITTER")"
    down_jbloat="$(calc_delta_ms "$MTR_JITTER" "$MTR_DOWN_JITTER")"

    printf "%s%-9s%s %s %s|%s %sPing:%s %s ms  %sLoss:%s %s  %sJitter:%s %s ms  [ %sΔPing:%s %s ms; %sΔJitter:%s %s ms ]\n" \
      "$GREEN" "Upload:" "$NC" "$(speed_pad 18 "$IPERF_UPLOAD_AVG")" \
      "$GREEN" "$NC" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_UP_AVG")" \
      "$GREEN" "$NC" "$(cval_pad 9 "$(fmt_pct_sp "$MTR_UP_LOSS")")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_UP_JITTER")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$up_bloat")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$up_jbloat")"

    printf "%s%-9s%s %s %s|%s %sPing:%s %s ms  %sLoss:%s %s  %sJitter:%s %s ms  [ %sΔPing:%s %s ms; %sΔJitter:%s %s ms ]\n" \
      "$GREEN" "Download:" "$NC" "$(speed_pad 18 "$IPERF_DOWNLOAD_AVG")" \
      "$GREEN" "$NC" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_DOWN_AVG")" \
      "$GREEN" "$NC" "$(cval_pad 9 "$(fmt_pct_sp "$MTR_DOWN_LOSS")")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$MTR_DOWN_JITTER")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$down_bloat")" \
      "$GREEN" "$NC" "$(cval_pad 8 "$down_jbloat")"
  else
    # iperf only, no mtr -> still show a clean mini-table
    printf "%s%-9s%s %s\n" "$GREEN" "Upload:" "$NC" "$up_speed"
    printf "%s%-9s%s %s\n" "$GREEN" "Download:" "$NC" "$down_speed"
  fi
}

run_tests_for_ip() {
  ip_or_domain="$1"
  iface_input="$2"
  target_note="${3:-}"
  
  # Reset per-target notices / errors
  NOTICES=""
  ERRORS=""

  tested_ip="$(validate_ip_domain "$ip_or_domain")"
  vrc=$?
  if [ "$vrc" -ne 0 ] 2>/dev/null; then
    # validate_ip_domain prints the reason on stdout when failing; capture it as a per-target error.
    [ -n "$tested_ip" ] && add_error "$tested_ip" || add_error "Error: Invalid IP or domain: $ip_or_domain"

    clear_spinner_line

    # Print a minimal Target block so the failure is visible in --ips runs.
    iface_display="$(get_egress_display "$iface_input")"
    target_display="$ip_or_domain"

    show_egress="false"
    multi_egress="false"
    [ -n "$iface_input" ] && show_egress="true"
    case "${INTERFACES:-}" in
      *" "*) multi_egress="true"; show_egress="true" ;;
    esac

    if [ -n "$target_note" ]; then
      if [ "$multi_egress" = "true" ] && [ -n "$iface_input" ]; then
        printf "%sTarget:%s  %s => %s %s%s%s\n" \
          "$GREEN" "$NC" \
          "$iface_display" "$target_display" \
          "$YELLOW" "$target_note" "$NC"
      elif [ "$show_egress" = "true" ]; then
        printf "%sTarget:%s  %s %s%s%s  %s|%s %sEgress:%s %s\n" \
          "$GREEN" "$NC" "$target_display" "$YELLOW" "$target_note" "$NC" \
          "$GREEN" "$NC" "$GREEN" "$NC" "$iface_display"
      else
        printf "%sTarget:%s  %s %s%s%s\n" \
          "$GREEN" "$NC" "$target_display" "$YELLOW" "$target_note" "$NC"
      fi
    else
      if [ "$multi_egress" = "true" ] && [ -n "$iface_input" ]; then
        printf "%sTarget:%s  %s => %s\n" \
          "$GREEN" "$NC" \
          "$iface_display" "$target_display"
      elif [ "$show_egress" = "true" ]; then
        printf "%sTarget:%s  %s  %s|%s %sEgress:%s %s\n" \
          "$GREEN" "$NC" "$target_display" \
          "$GREEN" "$NC" "$GREEN" "$NC" "$iface_display"
      else
        printf "%sTarget:%s  %s\n" "$GREEN" "$NC" "$target_display"
      fi
    fi

    printf "%s%s%s\n" "$GREEN" "$SEP_BIG" "$NC"
    flush_errors
    flush_notices
    echo ""

    # Preserve old behavior for single --ip runs (fail fast), but continue for --ips.
    if [ -n "${IP:-}" ] && [ -z "${IPS_FILE:-}" ]; then
      exit 1
    fi
    return 1
  fi
  TARGET_COUNT=$((TARGET_COUNT + 1))
  
  # Preserve any per-target note (from --ips) for the Scorecard
  if [ -n "$target_note" ]; then
    set_note_for_ip "$tested_ip" "$target_note"
  fi

  target_display="$tested_ip"
  if looks_like_domain "$ip_or_domain"; then
    target_display="$ip_or_domain ($tested_ip)"
  fi
  
  rdns="$(reverse_dns_lookup "$tested_ip" 2>/dev/null || true)"
  if [ -n "$rdns" ]; then
    if looks_like_domain "$ip_or_domain"; then
      _host_norm="$(echo "$ip_or_domain" | sed 's/\.$//' | tr 'A-Z' 'a-z')"
      _rdns_norm="$(echo "$rdns" | sed 's/\.$//' | tr 'A-Z' 'a-z')"
      if [ "$_host_norm" != "$_rdns_norm" ]; then
        target_display="$target_display ($rdns)"
      fi
    else
      target_display="$target_display ($rdns)"
    fi
  fi

  # Resolve interface per platform
  iface_dev="$iface_input"
  if [ "$PLATFORM" = "openwrt" ] && [ -n "$iface_input" ]; then
    iface_dev="$(normalize_iface_openwrt "$iface_input")"
  fi

  # Human-readable egress display for this specific run (used in output + scorecard)
  iface_display="$(get_egress_display "$iface_input")"
  
  # If the user requested a specific egress (-I), make sure we can actually bind to it for the
  # correct address family (IPv4 vs IPv6).
  # iperf3 only binds by source IP (-B). If we can't derive a suitable source IP, we run unbound
  # but label it loudly.
  target_family="$(ip_family_of "$tested_ip")"
  [ -z "$target_family" ] && target_family="4"

  iface_ip=""
  if [ -n "$iface_input" ]; then
    if [ -n "$iface_dev" ] && iface_exists "$iface_dev"; then
      iface_ip="$(get_interface_ip "$iface_dev" "$target_family" 2>/dev/null | head -n 1)"
    fi

    # OpenWrt: also allow logical names (wan/wwan/etc) via ubus
    if [ -z "$iface_ip" ] && [ "$PLATFORM" = "openwrt" ]; then
      if [ "$target_family" = "6" ]; then
        iface_ip="$(ubus_iface_ipv6 "$iface_input" 2>/dev/null || true)"
      else
        iface_ip="$(ubus_iface_ipv4 "$iface_input" 2>/dev/null || true)"
      fi
    fi

    if [ -z "$iface_ip" ]; then
      fam_lbl="IPv4"
      [ "$target_family" = "6" ] && fam_lbl="IPv6"

      if [ -z "$iface_dev" ] || ! iface_exists "$iface_dev"; then
        add_error "egress: interface '$iface_input' not found; running unbound (default route)."
      else
        add_error "egress: interface '$iface_dev' has no $fam_lbl; running unbound (default route)."
      fi

      iface_display="${iface_display} ${RED}(unbound)${NC}"
      iface_dev=""   # don't pass -I to mtr/load-mtr either
    fi
    
    # OpenWrt edge-case: ubus can yield an IP for a logical iface even if we couldn't map it to a real device.
    # iperf3 can still bind via -B, but mtr -I needs a real device name.
    if [ -n "$iface_ip" ] && [ -n "$iface_dev" ] && ! iface_exists "$iface_dev"; then
      add_notice "egress: '$iface_input' bound for iperf3 via $iface_ip, but no device mapping for mtr; mtr will be unbound."
      iface_dev=""
    fi
  fi

  mtr_rc=0
  if [ "$MTR" = "true" ]; then
    run_mtr_baseline "$tested_ip" "$iface_dev" "$iface_display" || mtr_rc=$?
  fi

  if [ "$IPERF3" = "true" ]; then
      run_iperf3 "$tested_ip" "$iface_display" "$iface_dev" "$iface_ip" || true
  fi
  clear_spinner_line

  # If multiple egress interfaces were specified, show which iface is used for THIS run.
  show_egress="false"
  multi_egress="false"

  if [ -n "$iface_input" ]; then
    show_egress="true"
  fi

  case "${INTERFACES:-}" in
    *" "*) multi_egress="true"; show_egress="true" ;;
  esac

  if [ -n "$target_note" ]; then
    if [ "$multi_egress" = "true" ] && [ -n "$iface_input" ]; then
      printf "%sTarget:%s  %s => %s %s%s%s\n" \
        "$GREEN" "$NC" \
        "$iface_display" "$target_display" \
        "$YELLOW" "$target_note" "$NC"
    elif [ "$show_egress" = "true" ]; then
      printf "%sTarget:%s  %s %s%s%s  %s|%s %sEgress:%s %s\n" \
        "$GREEN" "$NC" "$target_display" "$YELLOW" "$target_note" "$NC" \
        "$GREEN" "$NC" "$GREEN" "$NC" "$iface_display"
    else
      printf "%sTarget:%s  %s %s%s%s\n" \
        "$GREEN" "$NC" "$target_display" "$YELLOW" "$target_note" "$NC"
    fi
  else
    if [ "$multi_egress" = "true" ] && [ -n "$iface_input" ]; then
      printf "%sTarget:%s  %s => %s\n" \
        "$GREEN" "$NC" \
        "$iface_display" "$target_display"
    elif [ "$show_egress" = "true" ]; then
      printf "%sTarget:%s  %s  %s|%s %sEgress:%s %s\n" \
        "$GREEN" "$NC" "$target_display" \
        "$GREEN" "$NC" "$GREEN" "$NC" "$iface_display"
    else
      printf "%sTarget:%s  %s\n" "$GREEN" "$NC" "$target_display"
    fi
  fi
  printf "%s%s%s\n" "$GREEN" "$SEP_BIG" "$NC"

  print_target_table

  printf "%s%s%s\n" "$GREEN" "$SEP_BIG" "$NC"
  flush_errors
  flush_notices
  echo ""

  # Best results tracking (ignore ERROR/0)
  
  # Best Ping (lower is better). Track ties by displayed value (fmt3).
  if is_number "$MTR_BEST" && float_gt "$MTR_BEST" "0"; then
    if [ -z "$BEST_PING" ] || { is_number "$BEST_PING" && float_lt "$MTR_BEST" "$BEST_PING"; }; then
      if [ -n "$BEST_PING" ] && [ "$(fmt3 "$MTR_BEST")" = "$(fmt3 "$BEST_PING")" ]; then
        # Display didn't change; keep existing ties and append
        BEST_PING="$MTR_BEST"
        BEST_PING_ENTRIES="${BEST_PING_ENTRIES}${iface_display}|${tested_ip}
"
      else
        BEST_PING="$MTR_BEST"
        BEST_PING_ENTRIES="${iface_display}|${tested_ip}
"
      fi
    else
      if [ -n "$BEST_PING" ] && [ "$(fmt3 "$MTR_BEST")" = "$(fmt3 "$BEST_PING")" ]; then
        BEST_PING_ENTRIES="${BEST_PING_ENTRIES}${iface_display}|${tested_ip}
"
      fi
    fi
  fi

  # Min hops (lower is better). Track all ties.
  # Only score hops when baseline mtr produced valid end-to-end metrics (destination reached).
  loss_num="${MTR_LOSS%\%}"

  # Destination reached check:
  # parse_mtr_metrics_* falls back to the last hop when the destination isn't present.
  # So MTR_AVG/MTR_LOSS can look "valid" even when the destination wasn't reached.
  mtr_reached=false
  if [ -n "${MTR_OUT_FILE:-}" ] && [ -s "$MTR_OUT_FILE" ]; then
    if [ "$MTR_OUTPUT_MODE" = "xml" ] && [ -n "$XMLLINT_BIN" ]; then
      hit="$("$XMLLINT_BIN" --xpath "count(//*[(@ip or @IP or @Ip)='$tested_ip'])" "$MTR_OUT_FILE" 2>/dev/null | awk '{$1=$1};1')"
      echo "$hit" | grep -Eq '^[0-9]+([.][0-9]+)?$' && [ "$(awk -v x="$hit" 'BEGIN{print (x>0)?1:0}')" -eq 1 ] && mtr_reached=true
    else
      # report mode is numeric (-n), so the hop column is the IP.
      grep -Fq " $tested_ip" "$MTR_OUT_FILE" 2>/dev/null && mtr_reached=true
      grep -Fq "($tested_ip)" "$MTR_OUT_FILE" 2>/dev/null && mtr_reached=true
    fi
  fi

  if echo "${MTR_HOPS:-}" | grep -Eq '^[0-9]+$' && [ "$MTR_HOPS" -gt 0 ] 2>/dev/null \
     && is_number "$MTR_AVG" && float_gt "$MTR_AVG" "0" \
     && is_number "$loss_num" && float_lt "$loss_num" "100" \
     && [ "$mtr_reached" = "true" ]; then
    if [ -z "$MIN_HOPS" ] || { echo "${MIN_HOPS:-}" | grep -Eq '^[0-9]+$' && [ "$MTR_HOPS" -lt "$MIN_HOPS" ] 2>/dev/null; }; then
      MIN_HOPS="$MTR_HOPS"
      MIN_HOPS_ENTRIES="${iface_display}|${tested_ip}
"
    elif [ "$MTR_HOPS" -eq "$MIN_HOPS" ] 2>/dev/null; then
      MIN_HOPS_ENTRIES="${MIN_HOPS_ENTRIES}${iface_display}|${tested_ip}
"
    fi
  fi

  # Best Upload (higher is better). Track ties by displayed value (fmt2).
  if is_number "$IPERF_UPLOAD_AVG" && float_gt "$IPERF_UPLOAD_AVG" "0"; then
    if [ -z "$BEST_UPLOAD" ] || { is_number "$BEST_UPLOAD" && float_gt "$IPERF_UPLOAD_AVG" "$BEST_UPLOAD"; }; then
      if [ -n "$BEST_UPLOAD" ] && [ "$(fmt2 "$IPERF_UPLOAD_AVG")" = "$(fmt2 "$BEST_UPLOAD")" ]; then
        BEST_UPLOAD="$IPERF_UPLOAD_AVG"
        BEST_UPLOAD_ENTRIES="${BEST_UPLOAD_ENTRIES}${iface_display}|${tested_ip}
"
      else
        BEST_UPLOAD="$IPERF_UPLOAD_AVG"
        BEST_UPLOAD_ENTRIES="${iface_display}|${tested_ip}
"
      fi
    else
      if [ -n "$BEST_UPLOAD" ] && [ "$(fmt2 "$IPERF_UPLOAD_AVG")" = "$(fmt2 "$BEST_UPLOAD")" ]; then
        BEST_UPLOAD_ENTRIES="${BEST_UPLOAD_ENTRIES}${iface_display}|${tested_ip}
"
      fi
    fi
  fi

  # Best Download (higher is better). Track ties by displayed value (fmt2).
  if is_number "$IPERF_DOWNLOAD_AVG" && float_gt "$IPERF_DOWNLOAD_AVG" "0"; then
    if [ -z "$BEST_DOWNLOAD" ] || { is_number "$BEST_DOWNLOAD" && float_gt "$IPERF_DOWNLOAD_AVG" "$BEST_DOWNLOAD"; }; then
      if [ -n "$BEST_DOWNLOAD" ] && [ "$(fmt2 "$IPERF_DOWNLOAD_AVG")" = "$(fmt2 "$BEST_DOWNLOAD")" ]; then
        BEST_DOWNLOAD="$IPERF_DOWNLOAD_AVG"
        BEST_DOWNLOAD_ENTRIES="${BEST_DOWNLOAD_ENTRIES}${iface_display}|${tested_ip}
"
      else
        BEST_DOWNLOAD="$IPERF_DOWNLOAD_AVG"
        BEST_DOWNLOAD_ENTRIES="${iface_display}|${tested_ip}
"
      fi
    else
      if [ -n "$BEST_DOWNLOAD" ] && [ "$(fmt2 "$IPERF_DOWNLOAD_AVG")" = "$(fmt2 "$BEST_DOWNLOAD")" ]; then
        BEST_DOWNLOAD_ENTRIES="${BEST_DOWNLOAD_ENTRIES}${iface_display}|${tested_ip}
"
      fi
    fi
  fi


  [ -n "${MTR_OUT_FILE:-}" ] && rm -f "$MTR_OUT_FILE" 2>/dev/null || true
  MTR_OUT_FILE=""

  return $mtr_rc
}
          
run_tests_for_target_across_ifaces() {
  ip_or_domain="$1"
  target_note="${2:-}"

  if [ -n "${INTERFACES:-}" ]; then
    for _iface in $INTERFACES; do
      run_tests_for_ip "$ip_or_domain" "$_iface" "$target_note"
    done
  else
    run_tests_for_ip "$ip_or_domain" "" "$target_note"
  fi
}


process_ips_from_file() {
  file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    raw="$(trim "$line")"
    [ -z "$raw" ] && continue

    # Full-line comments
    case "$raw" in
      \#*) continue ;;
    esac

    ip_part="$raw"
    note=""

    # Inline comments: "1.1.1.1 # comment"
    case "$raw" in
      *\#*)
        ip_part="$(trim "${raw%%#*}")"
        note_body="$(trim "${raw#*#}")"
        if [ -n "$note_body" ]; then
          note="# $note_body"
        fi
        ;;
    esac

    [ -z "$ip_part" ] && continue
    run_tests_for_target_across_ifaces "$ip_part" "$note"
  done < "$file"

  print_scorecard
}


# ----------------------------
# Arg parsing
# ----------------------------
detect_platform
LOG_DIR="$LOG_DIR_DEFAULT"

require_arg() {
  opt="$1"
  val="${2:-}"
  if [ -z "$val" ] || echo "$val" | grep -Eq '^-'; then
    echo "Error: $opt requires a value"
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--ip)
      require_arg "$1" "${2:-}"
      IP="$2"
      shift 2
      ;;
    --ips)
      require_arg "$1" "${2:-}"
      IPS_FILE="$2"
      shift 2
      ;;
    --ipv4)
      ADDR_FAMILY="4"
      shift
      ;;
    --ipv6)
      ADDR_FAMILY="6"
      shift
      ;;
    --mtr)
      MTR=true
      if [ -n "${2:-}" ] && ! echo "$2" | grep -Eq '^-'; then
        echo "$2" | grep -Eq '^[0-9]+$' && [ "$2" -ge 1 ] 2>/dev/null || {
          echo "Error: --mtr count must be an integer >= 1"
          exit 1
        }
        MTR_COUNT="$2"
        shift 2
      else
        shift
      fi
      ;;
    --mtr-probe)
      require_arg "$1" "${2:-}"
      MTR_PROBE="$2"
      shift 2
      ;;
    --mtr-port)
      require_arg "$1" "${2:-}"
      MTR_PORT="$2"
      shift 2
      ;;
    --mtr-interval)
      require_arg "$1" "${2:-}"
      MTR_INTERVAL="$2"
      shift 2
      ;;
    --iperf3)
      IPERF3=true
      if [ -n "${2:-}" ] && ! echo "$2" | grep -Eq '^-'; then
        echo "$2" | grep -Eq '^[0-9]+$' && [ "$2" -ge 1 ] 2>/dev/null || {
          echo "Error: --iperf3 time must be an integer >= 1"
          exit 1
        }
        IPERF3_TIME="$2"
        shift 2
      else
        shift
      fi
      ;;
    -P|--iperf3-parallel)
      [ -n "${2:-}" ] && echo "$2" | grep -Eq '^[0-9]+$' && [ "$2" -ge 1 ] 2>/dev/null || {
        echo "Error: --iperf3-parallel requires an integer >= 1"
        exit 1
      }
      IPERF3_PARALLEL="$2"
      # Do NOT set IPERF3=true here; -P only configures iperf3. Test selection is done by --iperf3/--mtr (or defaults).
      shift 2
      ;;
    -p|--iperf3-port)
      require_arg "$1" "${2:-}"
      IPERF3_PORTS="$2"
      # Do NOT set IPERF3=true here; -p only configures iperf3. Test selection is done by --iperf3/--mtr (or defaults).
      shift 2
      ;;
    -I)
      require_arg "$1" "${2:-}"
      add_egress_ifaces "$2"
      shift 2
      ;;
    --log)
      if [ -n "${2:-}" ] && echo "$2" | grep -qv '^-'; then
        LOG_DIR="$2"
        shift
      fi
      LOG=true
      shift
      ;;
    --install-missing)
      AUTO_INSTALL=true
      shift
      ;;
    --sudo)
      SUDO_MODE="force"
      shift
      ;;
    --no-sudo)
      SUDO_MODE="never"
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# ----------------------------
# Validate args / defaults
# ----------------------------
if [ -z "${IP:-}" ] && [ -z "${IPS_FILE:-}" ]; then
  echo "Error: You must specify either --ip or --ips."
  show_help
  exit 1
fi
          
if [ -n "${IP:-}" ] && [ -n "${IPS_FILE:-}" ]; then
  echo "Error: use either --ip or --ips (not both)."
  exit 1
fi

# Default both tests if not specified
if [ "$MTR" = "false" ] && [ "$IPERF3" = "false" ]; then
  MTR=true
  IPERF3=true
fi
          
# Validate iperf3 knobs (env-overridable) early to avoid confusing iperf errors
if [ "$IPERF3" = "true" ]; then
  echo "$IPERF3_TIME" | grep -Eq '^[0-9]+$' || {
    echo "Error: IPERF3_TIME must be an integer >= 1 (got: $IPERF3_TIME)"
    exit 1
  }
  [ "$IPERF3_TIME" -ge 1 ] 2>/dev/null || {
    echo "Error: IPERF3_TIME must be >= 1 (got: $IPERF3_TIME)"
    exit 1
  }

  echo "$IPERF3_PARALLEL" | grep -Eq '^[0-9]+$' || {
    echo "Error: IPERF3_PARALLEL must be an integer >= 1 (got: $IPERF3_PARALLEL)"
    exit 1
  }
  [ "$IPERF3_PARALLEL" -ge 1 ] 2>/dev/null || {
    echo "Error: IPERF3_PARALLEL must be >= 1 (got: $IPERF3_PARALLEL)"
    exit 1
  }

  # CONNECT_TIMEOUT: allow 0 to mean "don't pass --connect-timeout"
  echo "$CONNECT_TIMEOUT" | grep -Eq '^[0-9]+$' || {
    echo "Error: CONNECT_TIMEOUT must be an integer >= 0 ms (got: $CONNECT_TIMEOUT)"
    exit 1
  }
  [ "$CONNECT_TIMEOUT" -ge 0 ] 2>/dev/null || {
    echo "Error: CONNECT_TIMEOUT must be >= 0 (got: $CONNECT_TIMEOUT)"
    exit 1
  }
fi
          
# Expand/validate iperf3 port spec (if provided). Keeps a space-separated list for fast retries.
IPERF3_PORT_LIST=""
if [ -n "${IPERF3_PORTS:-}" ]; then
  IPERF3_PORT_LIST="$(expand_iperf3_port_spec "$IPERF3_PORTS")" || exit 1
fi
          
# Display form + whether the port spec expands to more than 1 port (range/list).
IPERF3_PORT_SPEC_DISPLAY=""
IPERF3_PORT_IS_RANGE="false"
if [ -n "${IPERF3_PORTS:-}" ]; then
  IPERF3_PORT_SPEC_DISPLAY="$(printf "%s" "$IPERF3_PORTS" | awk '{gsub(/[[:space:]]/, ""); print}')"
  port_count="$(printf "%s" "$IPERF3_PORT_LIST" | awk '{print NF}')"
  [ "$port_count" -gt 1 ] 2>/dev/null && IPERF3_PORT_IS_RANGE="true"
fi

# Validate mtr knobs only when mtr is enabled
if [ "$MTR" = "true" ]; then
  # Validate mtr cycles
  echo "$MTR_COUNT" | grep -Eq '^[0-9]+$' || {
    echo "Error: invalid --mtr count '$MTR_COUNT' (use an integer >= 1)"
    exit 1
  }
  [ "$MTR_COUNT" -ge 1 ] 2>/dev/null || {
    echo "Error: --mtr count must be >= 1 (got: $MTR_COUNT)"
    exit 1
  }
  # Validate load-mtr cycles override (env var). Only relevant when running iperf3 + mtr.
  if [ "$IPERF3" = "true" ] && [ -n "${MTR_LOAD_COUNT:-}" ]; then
    echo "$MTR_LOAD_COUNT" | grep -Eq '^[0-9]+$' || {
      echo "Error: MTR_LOAD_COUNT must be an integer >= 1 (or unset to auto-derive) (got: $MTR_LOAD_COUNT)"
      exit 1
    }
    [ "$MTR_LOAD_COUNT" -ge 1 ] 2>/dev/null || {
      echo "Error: MTR_LOAD_COUNT must be >= 1 (or unset to auto-derive) (got: $MTR_LOAD_COUNT)"
      exit 1
    }
  fi

  # Validate mtr probe
  case "$MTR_PROBE" in
    icmp|udp|tcp) : ;;
    *)
      echo "Error: invalid --mtr-probe '$MTR_PROBE' (use icmp|udp|tcp)"
      exit 1
      ;;
  esac

  # Validate interval
  if ! is_number "$MTR_INTERVAL" || ! float_gt "$MTR_INTERVAL" "0"; then
    echo "Error: invalid --mtr-interval '$MTR_INTERVAL' (use a number > 0, e.g. 1)"
    exit 1
  fi

  # Default TCP probe port if not set
  if [ "$MTR_PROBE" = "tcp" ] && [ -z "${MTR_PORT:-}" ]; then
    MTR_PORT="443"
  fi

  # Validate port (if provided)
  if [ -n "${MTR_PORT:-}" ]; then
    echo "$MTR_PORT" | grep -Eq '^[0-9]+$' || {
      echo "Error: invalid --mtr-port '$MTR_PORT' (use an integer port)"
      exit 1
    }
    [ "$MTR_PORT" -ge 1 ] 2>/dev/null && [ "$MTR_PORT" -le 65535 ] 2>/dev/null || {
      echo "Error: --mtr-port out of range (1-65535): $MTR_PORT"
      exit 1
    }
  fi
fi

# Tools
# Determine whether DNS tools are needed (only if domains are used).
NEED_DNS=false
if [ -n "${IP:-}" ] && looks_like_domain "$IP"; then
  NEED_DNS=true
fi

if [ -n "${IPS_FILE:-}" ] && [ -f "$IPS_FILE" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="$(trim "$_line")"
    [ -z "$_line" ] && continue

    # Full-line comments
    case "$_line" in
      \#*) continue ;;
    esac

    # Strip inline comments: "example.com # note"
    _probe="$(trim "${_line%%#*}")"
    [ -z "$_probe" ] && continue

    if looks_like_domain "$_probe"; then
      NEED_DNS=true
      break
    fi
  done < "$IPS_FILE"
fi

check_tools

# If user forced sudo for mtr, authenticate once up front (where supported)
if [ "$MTR" = "true" ] && [ "$SUDO_MODE" = "force" ] && [ "$(id -u)" -ne 0 ] && [ "$PLATFORM" != "openwrt" ]; then
  ensure_sudo || {
    echo "Error: --sudo requested but sudo auth failed or sudo is unavailable."
    exit 1
  }
  MTR_USE_SUDO=true
fi

# Log setup
if [ "$LOG" = "true" ]; then
  timestamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || date)"
  LOG_FILE=""

  orig_log_dir="$LOG_DIR"
  try_log_dir="$orig_log_dir"

  # Ensure directory exists (fallback to /tmp only when using the default dir)
  if ! mkdir -p "$try_log_dir" 2>/dev/null; then
    if [ "$orig_log_dir" = "$LOG_DIR_DEFAULT" ] && [ -d "/tmp" ] && mkdir -p "/tmp" 2>/dev/null; then
      try_log_dir="/tmp"
    else
      echo "Warning: cannot create log dir '$orig_log_dir' (logging disabled)." >&2
      LOG=false
    fi
  fi

  if [ "$LOG" = "true" ]; then
    LOG_DIR="$try_log_dir"
    LOG_FILE="${LOG_DIR%/}/log-$(basename "$0")-$timestamp.txt"

    # Verify we can actually write the log file (fallback to /tmp only when using the default dir)
    if ! echo "$0 test at $timestamp" > "$LOG_FILE" 2>/dev/null; then
      if [ "$orig_log_dir" = "$LOG_DIR_DEFAULT" ] && [ "$try_log_dir" != "/tmp" ] && [ -d "/tmp" ]; then
        LOG_DIR="/tmp"
        LOG_FILE="${LOG_DIR%/}/log-$(basename "$0")-$timestamp.txt"
      fi

      if ! echo "$0 test at $timestamp" > "$LOG_FILE" 2>/dev/null; then
        echo "Warning: cannot write log file '$LOG_FILE' (logging disabled)." >&2
        LOG=false
        LOG_FILE=""
      fi
    fi
  fi
fi

# ----------------------------
# Run tests (new output layout)
# ----------------------------
RUN_STARTED_TS="$(now_stamp)"

echo ""
print_banner "Started" "$RUN_STARTED_TS"
echo ""
print_settings

if [ -n "${IP:-}" ]; then
  run_tests_for_target_across_ifaces "$IP"
  print_scorecard
elif [ -n "${IPS_FILE:-}" ]; then
  if [ ! -f "$IPS_FILE" ]; then
    echo "Error: IPs file '$IPS_FILE' not found."
    exit 1
  fi
  process_ips_from_file "$IPS_FILE"
fi

RUN_ENDED_TS="$(now_stamp)"

echo ""
print_banner "Ended" "$RUN_ENDED_TS"
echo ""
