#!/bin/zsh
# Run the test suite unattended and end with ONE summary line.
#
#   scripts/test.sh                 whole suite: the 3 test modules run side by side
#   scripts/test.sh --filter X      only matching tests (swift test --filter), one process
#
# (run it as a background job; you get notified when it ends)
# - build once (slowbuild: efficiency cores, $JOBS=4 jobs), then run the tests at normal speed (nice 10,
#   3 processes: short bursts; background QoS made CPU-heavy tests 4x slower); logs in build/test*.log
# - output is unbuffered (NSUnbufferedIO), so the log shows each test as it runs
# - watchdog: once a module's tests are running, no output for $STALL seconds (default 15) =
#   stalled: the run is killed and the stuck test named. Building may be silent for
#   $BUILD_STALL (default 300 s). Slow tests must print "progress: …" lines every few seconds.
# - last line is always one of:
#     TESTS PASS: 405 tests in 70s
#     TESTS FAIL: 3 failures — <first failing tests>
#     TESTS CRASH: <fatal error line> (in <test>)
#     TESTS STALLED in <test> after <n>s without output
setopt no_nomatch
cd "$(dirname "$0")/.."
ROOT=$PWD
BP=.build-test
LOG=build/test.log
mkdir -p build
rm -f build/test-*.log
: > "$LOG"
STALL=${STALL:-15}
BUILD_STALL=${BUILD_STALL:-300}
export NSUnbufferedIO=YES
START=$(date +%s)

stuck_in() { grep "Test Case '.*' started" "$1" | tail -1 | sed -E "s/.*Test Case '-\[(.*)\]' started.*/\1/"; }

# watch <pid:log>... : wait for all; kill everything if one log goes quiet too long
watch() {
  typeset -A last quiet
  local running=1
  while (( running )); do
    sleep 1; running=0
    for pl in "$@"; do
      local pid=${pl%%:*} log=${pl#*:}
      kill -0 $pid 2>/dev/null || continue
      running=1
      local size=$(stat -f %z "$log")
      if [[ $size == ${last[$log]} ]]; then quiet[$log]=$(( ${quiet[$log]:-0} + 1 )); else quiet[$log]=0; last[$log]=$size; fi
      local limit=$BUILD_STALL; grep -q "Test Case '" "$log" && limit=$STALL
      if (( ${quiet[$log]} >= limit )); then
        local stuck=$(stuck_in "$log")
        for q in "$@"; do pkill -P ${q%%:*} 2>/dev/null; kill ${q%%:*} 2>/dev/null; done
        pkill -f "FloStateNativePackageTests.xctest" 2>/dev/null
        for f in build/test-*.log(N); do cat "$f" >> "$LOG"; done
        echo "TESTS STALLED in ${stuck:-build} after ${quiet[$log]}s without output (log: $log)"
        exit 3
      fi
    done
  done
}

# 1. build
JOBS=${JOBS:-4} slowbuild swift build --build-tests --build-path $BP -j ${JOBS:-4} >> "$LOG" 2>&1 &
BPID=$!
watch "$BPID:$LOG"
wait $BPID || { echo "TESTS CRASH: $(grep -m1 -E "error:" "$LOG" | cut -c1-200) (in build) (log: $LOG)"; exit 1; }

# 2. run
pids=()
if (( $# )); then
  nice -n 10 swift test --skip-build --build-path $BP "$@" > build/test-filtered.log 2>&1 &
  pids+=("$!:build/test-filtered.log")
else
  BUNDLE="$ROOT/$BP/debug/FloStateNativePackageTests.xctest"
  classes=$(swift test --skip-build --build-path $BP list 2>/dev/null | cut -d/ -f1 | sort -u)
  for mod in FloStateNativeTests FloCoreTests FloKitTests; do
    sel=$(print -r -- "$classes" | grep "^$mod\." | paste -sd, -)
    [[ -n $sel ]] || continue
    nice -n 10 xcrun xctest -XCTest "$sel" "$BUNDLE" > "build/test-$mod.log" 2>&1 &
    pids+=("$!:build/test-$mod.log")
  done
fi
watch "${pids[@]}"
code=0
for pl in "${pids[@]}"; do wait ${pl%%:*} || code=1; done
for f in build/test-*.log(N); do cat "$f" >> "$LOG"; done

# 3. summary (the last "Executed" line of each module log is its total)
total=0; failed=0
for pl in "${pids[@]}"; do
  line=$(grep -E "Executed [0-9]+ tests?, with" "${pl#*:}" | tail -1)
  [[ -n $line ]] || { total=-1; break; }
  n=$(print -r -- "$line" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
  f=$(print -r -- "$line" | sed -E 's/.* ([0-9]+) failures?.*/\1/')
  total=$(( total + n )); failed=$(( failed + f ))
done
secs=$(( $(date +%s) - START ))
fails=$(grep -E "error: -\[" "$LOG" | sed -E "s/.*error: -\[([^]]*)\].*/\1/" | sort -u | head -3 | tr '\n' ';')
fatal=$(grep -m1 -E "Fatal error|signal code|error: [a-z]" "$LOG" | grep -v "error: -\[" | cut -c1-200)
if [[ $code == 0 && $total -gt 0 && $failed == 0 ]]; then
  echo "TESTS PASS: $total tests in ${secs}s"
elif [[ -n $fails ]]; then
  echo "TESTS FAIL: $failed failures — $fails (log: $LOG)"
elif [[ -n $fatal || $total == -1 ]]; then
  echo "TESTS CRASH: ${fatal:-a test process died} (in $(stuck_in "$LOG")) (log: $LOG)"
else
  echo "TESTS FAIL: exit $code (log: $LOG)"
fi
exit $code
