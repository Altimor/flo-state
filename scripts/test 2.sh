#!/bin/zsh
# Run the test suite unattended and end with ONE summary line.
#
#   scripts/test.sh [--filter X]      (run it as a background job; you get notified when it ends)
#
# - throttled build/test (slowbuild), full log in build/test.log
# - watchdog: once tests are running, no output for $STALL seconds (default 15) = stalled: the run is
#   killed and the stuck test named. While building (before any test starts) the limit is $BUILD_STALL
#   (default 300 s: compiling can be silent). Slow tests must print "progress: …" lines every few seconds.
# - last line is always one of:
#     TESTS PASS: 402 tests
#     TESTS FAIL: 3 failures — <first failing tests>
#     TESTS CRASH: <fatal error line> (in <test>)
#     TESTS STALLED in <test> after <n>s without output
setopt no_nomatch
cd "$(dirname "$0")/.."
LOG=build/test.log
mkdir -p build
: > "$LOG"
STALL=${STALL:-15}
BUILD_STALL=${BUILD_STALL:-300}

slowbuild swift test --build-path .build-test "$@" >> "$LOG" 2>&1 &
PID=$!

last=0; quiet=0
while kill -0 $PID 2>/dev/null; do
  sleep 1
  size=$(stat -f %z "$LOG")
  if [[ $size == $last ]]; then quiet=$((quiet + 1)); else quiet=0; last=$size; fi
  limit=$BUILD_STALL; grep -q "Test Case '" "$LOG" && limit=$STALL
  if (( quiet >= limit )); then
    stuck=$(grep "Test Case '.*' started" "$LOG" | tail -1 | sed -E "s/.*Test Case '-\[(.*)\]' started.*/\1/")
    pkill -P $PID 2>/dev/null; kill $PID 2>/dev/null
    pkill -f "FloStateNativePackageTests.xctest" 2>/dev/null
    echo "TESTS STALLED in ${stuck:-build} after ${quiet}s without output (log: $LOG)"
    exit 3
  fi
done
wait $PID; code=$?

total=$(grep -E "Executed [0-9]+ tests?, with" "$LOG" | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?, with ([0-9]+) failures?.*/\1 \2/')
fails=$(grep -E "error: -\[" "$LOG" | sed -E "s/.*error: -\[([^]]*)\].*/\1/" | sort -u | head -3 | tr '\n' ';')
fatal=$(grep -m1 -E "Fatal error|signal code|error: compile|error: [a-z]" "$LOG" | grep -v "error: -\[" | cut -c1-200)
if [[ $code == 0 && -n $total && ${total#* } == 0 ]]; then
  echo "TESTS PASS: ${total% *} tests"
elif [[ -n $fails ]]; then
  echo "TESTS FAIL: ${total#* } failures — $fails (log: $LOG)"
elif [[ -n $fatal ]]; then
  stuck=$(grep "Test Case '.*' started" "$LOG" | tail -1 | sed -E "s/.*Test Case '-\[(.*)\]' started.*/\1/")
  echo "TESTS CRASH: $fatal (in ${stuck:-build}) (log: $LOG)"
else
  echo "TESTS FAIL: exit $code (log: $LOG)"
fi
exit $code
