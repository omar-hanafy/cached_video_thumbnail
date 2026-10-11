#!/usr/bin/env bash
set -eu

logcat_file="$RUNNER_TEMP/android-integration-logcat.txt"
adb -s "$ANDROID_SERIAL" logcat -v threadtime '*:S' AndroidRuntime:E libc:F flutter:V Flutter:V ActivityManager:I ActivityTaskManager:I > "$logcat_file" 2>&1 &
logcat_pid=$!

capture_diagnostics() {
  status=$?
  trap - EXIT
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  if [ "$status" -ne 0 ]; then
    echo '::group::Android integration startup diagnostics'
    tail -n 300 "$logcat_file" || true
    timeout 15s adb -s "$ANDROID_SERIAL" logcat -b crash -d || true
    timeout 15s adb -s "$ANDROID_SERIAL" shell dumpsys activity top || true
    timeout 15s adb -s "$ANDROID_SERIAL" shell pidof tech.tomars.cached_video_thumbnail_example || true
    echo '::endgroup::'
  fi
  exit "$status"
}

trap capture_diagnostics EXIT
timeout --signal=TERM --kill-after=30s 15m flutter test integration_test/thumbnail_test.dart --no-pub --verbose --reporter expanded -d "$ANDROID_SERIAL"
