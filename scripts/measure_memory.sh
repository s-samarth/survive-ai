#!/usr/bin/env bash
#
# Sample Survive AI's memory on a connected Android device or emulator.
#
#   scripts/measure_memory.sh                  # sample until Ctrl-C
#   scripts/measure_memory.sh -i 2 -n 150      # every 2s, 150 samples
#   scripts/measure_memory.sh -o run1          # write run1.csv + run1.peak.txt
#
# Why this exists rather than Flutter DevTools: DevTools shows the **Dart
# heap**, which for this app is the least interesting number on the device.
# Gemma's weights are a native, memory-mapped allocation made by MediaPipe
# below the Dart VM, so DevTools reports a few tens of MB while the process is
# actually holding well over a gigabyte. `dumpsys meminfo` is the only view
# that sees all of it.
#
# Three numbers matter here, and they answer different questions:
#
#   TOTAL PSS      what this process costs the system, with shared pages
#                  divided among everyone mapping them. The headline number.
#   Native Heap    MediaPipe's own allocations — the KV cache lives here, so
#                  this is what should stay flat across turns if the session
#                  recycling in LlmService is working.
#   MemAvailable   what the *kernel* thinks is left, device-wide. The app can
#                  look fine while the device is one tab away from killing it,
#                  and this is the column that shows that.
#
# Mapped model pages are file-backed and clean, so the kernel can evict them
# under pressure and take them back later. That is the whole reason
# llm_service.dart pins the CPU backend. It also means TOTAL PSS overstates
# how much pressure the app really applies: some of it is reclaimable. Read it
# as a ceiling, not as a hard cost.
set -uo pipefail

PACKAGE="com.surviveai.survive_ai"
INTERVAL=5
SAMPLES=0          # 0 = until interrupted
OUT=""
SERIAL=()

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts "i:n:o:s:p:h" opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    n) SAMPLES="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    s) SERIAL=(-s "$OPTARG") ;;
    p) PACKAGE="$OPTARG" ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

command -v adb >/dev/null || { echo "adb not on PATH. See docs/TESTING.md." >&2; exit 1; }

if ! adb "${SERIAL[@]}" get-state >/dev/null 2>&1; then
  echo "No device. Start an emulator or plug one in; \`adb devices\` to check." >&2
  exit 1
fi

sh_() { adb "${SERIAL[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }

DEVICE=$(sh_ getprop ro.product.model)
API=$(sh_ getprop ro.build.version.sdk)
ABI=$(sh_ getprop ro.product.cpu.abi)
TOTAL_KB=$(sh_ cat /proc/meminfo | awk '/^MemTotal:/ {print $2}')

echo "device:     ${DEVICE:-unknown} (API ${API:-?}, ${ABI:-?})"
echo "device RAM: $(awk -v k="${TOTAL_KB:-0}" 'BEGIN{printf "%.1f GB", k/1048576}')"
echo "package:    $PACKAGE"
echo

# `abiFilters` is arm64-v8a only, so an x86_64 image cannot even load the
# engine. Say so now rather than letting it look like a model bug.
case "${ABI:-}" in
  arm64*) ;;
  "")     echo "warning: could not read the device ABI." >&2 ;;
  *)      echo "warning: device ABI is '$ABI'. This app ships arm64-v8a only" >&2
          echo "         and will not start here. On Apple silicon create the" >&2
          echo "         AVD from an arm64-v8a system image." >&2 ;;
esac

# First numeric field after the first colon, within the App Summary block only.
# The detailed section above it repeats several of these labels.
field() { awk -F: -v want="$1" '
  /App Summary/ { in_summary = 1 }
  in_summary && index($0, want) { split($2, a, " "); print a[1] + 0; exit }
' ; }

printf '%-9s %12s %12s %12s %10s %12s\n' \
  elapsed TOTAL_PSS NativeHeap JavaHeap Code MemAvail
printf '%-9s %12s %12s %12s %10s %12s\n' \
  -------- ------------ ------------ ------------ ---------- ------------

[ -n "$OUT" ] && echo "elapsed_s,total_pss_kb,native_heap_kb,java_heap_kb,code_kb,graphics_kb,mem_available_kb" > "$OUT.csv"

START=$(date +%s)
PEAK=0
i=0
while :; do
  i=$((i + 1))
  PID=$(sh_ pidof "$PACKAGE" | awk '{print $1}')
  if [ -z "$PID" ]; then
    if [ "$i" -eq 1 ]; then
      echo "Process not running. Launch the app, then re-run." >&2
      exit 1
    fi
    # The event this whole script exists to catch.
    echo
    echo "PROCESS GONE after $(( $(date +%s) - START ))s — peak TOTAL PSS was ${PEAK} KB."
    echo "Reason, if the kernel or ActivityManager logged one:"
    adb "${SERIAL[@]}" logcat -d -t 400 2>/dev/null \
      | grep -Ei 'lowmemorykiller|lmkd|Killing .*'"$PACKAGE"'|oom|am_kill' \
      | tail -12 | sed 's/^/  /'
    exit 3
  fi

  MEMINFO=$(adb "${SERIAL[@]}" shell dumpsys meminfo "$PID" 2>/dev/null | tr -d '\r')
  PSS=$(printf '%s\n' "$MEMINFO"    | field "TOTAL PSS")
  NATIVE=$(printf '%s\n' "$MEMINFO" | field "Native Heap")
  JAVA=$(printf '%s\n' "$MEMINFO"   | field "Java Heap")
  CODE=$(printf '%s\n' "$MEMINFO"   | field "Code")
  GFX=$(printf '%s\n' "$MEMINFO"    | field "Graphics")
  AVAIL=$(sh_ cat /proc/meminfo | awk '/^MemAvailable:/ {print $2}')
  ELAPSED=$(( $(date +%s) - START ))

  mb() { awk -v k="${1:-0}" 'BEGIN{printf "%.0f MB", k/1024}'; }
  printf '%-9s %12s %12s %12s %10s %12s\n' \
    "${ELAPSED}s" "$(mb "$PSS")" "$(mb "$NATIVE")" "$(mb "$JAVA")" "$(mb "$CODE")" "$(mb "$AVAIL")"

  if [ -n "$OUT" ]; then
    echo "$ELAPSED,${PSS:-},${NATIVE:-},${JAVA:-},${CODE:-},${GFX:-},${AVAIL:-}" >> "$OUT.csv"
  fi

  # Keep the full dumpsys from the worst moment. The summary says how much;
  # only the detailed section says which mapping it went into.
  if [ -n "${PSS:-}" ] && [ "${PSS:-0}" -gt "$PEAK" ] 2>/dev/null; then
    PEAK="$PSS"
    [ -n "$OUT" ] && printf '%s\n' "$MEMINFO" > "$OUT.peak.txt"
  fi

  [ "$SAMPLES" -ne 0 ] && [ "$i" -ge "$SAMPLES" ] && break
  sleep "$INTERVAL"
done

echo
echo "peak TOTAL PSS: $(awk -v k="$PEAK" 'BEGIN{printf "%.0f MB (%d KB)", k/1024, k}')"
if [ -n "$OUT" ]; then
  echo "samples:        $OUT.csv"
  echo "peak dumpsys:   $OUT.peak.txt"
fi
