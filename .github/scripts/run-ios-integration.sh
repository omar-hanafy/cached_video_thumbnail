#!/usr/bin/env bash
set -euo pipefail

result_bundle="$RUNNER_TEMP/thumbnail-ios.xcresult"

# The native runner receives the unchanged Dart suite through integration_test's
# allTestsFinished channel. Reset defines left by flutter test (which disables it).
flutter build ios --config-only --simulator --debug --no-codesign --no-pub \
  --target integration_test/thumbnail_test.dart \
  --dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=true

xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination "id=$IOS_DEVICE" \
  -only-testing:RunnerTests -parallel-testing-enabled NO \
  -resultBundlePath "$result_bundle" CODE_SIGNING_ALLOWED=NO \
  "GCC_PREPROCESSOR_DEFINITIONS=\$(inherited) THUMBNAIL_INTEGRATION_TEST=1"

xcrun xcresulttool get test-results summary --path "$result_bundle" \
  > "$RUNNER_TEMP/thumbnail-ios-summary.json"
xcrun xcresulttool get test-results tests --path "$result_bundle" \
  > "$RUNNER_TEMP/thumbnail-ios-tests.json"
python3 ../.github/scripts/verify-ios-test-results.py \
  "$RUNNER_TEMP/thumbnail-ios-summary.json" "$RUNNER_TEMP/thumbnail-ios-tests.json"
