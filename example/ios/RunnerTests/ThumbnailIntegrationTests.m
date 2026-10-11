// Enable only when Runner launches the Dart integration test entrypoint.
// Ordinary native-only Xcode tests launch the example app and must not wait
// for integration results that its main.dart never sends.
#if defined(THUMBNAIL_INTEGRATION_TEST) && THUMBNAIL_INTEGRATION_TEST
@import XCTest;
@import integration_test;

INTEGRATION_TEST_IOS_RUNNER(ThumbnailIntegrationTests)
#endif
