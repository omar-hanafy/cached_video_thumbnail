import AVFoundation
import XCTest

@testable import cached_video_thumbnail

final class RunnerTests: XCTestCase {
  private func generator() -> AVAssetImageGenerator {
    AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: "/unused.mp4")))
  }

  func testCancellationBeforeAssetRegistrationRejectsMetadataLoading() {
    let cancellation = ExtractionCancellation()
    cancellation.cancel()
    let asset = AVURLAsset(url: URL(fileURLWithPath: "/unused.mp4"))
    XCTAssertThrowsError(try cancellation.registerAsset(asset)) { error in
      XCTAssertEqual((error as? PigeonError)?.code, "cancelled")
    }
  }

  func testCancellationAbortsRegisteredAssetLoading() throws {
    let cancellation = ExtractionCancellation()
    let asset = CancellationAsset(url: URL(fileURLWithPath: "/unused.mp4"))
    try cancellation.registerAsset(asset)
    cancellation.cancel()
    XCTAssertTrue(asset.didCancelLoading)
  }

  func testCancellationDuringMetadataLoadingRejectsLateGenerator() {
    let cancellation = ExtractionCancellation()
    // Metadata loading suspends before a generator exists. Cancellation must
    // survive that interval instead of disappearing from a generators map.
    cancellation.cancel()
    XCTAssertThrowsError(try cancellation.register(generator())) { error in
      XCTAssertEqual((error as? PigeonError)?.code, "cancelled")
    }
  }

  func testCancellationAfterGeneratorRegistrationPreventsEncoding() throws {
    let cancellation = ExtractionCancellation()
    try cancellation.register(generator())
    cancellation.cancel()
    XCTAssertThrowsError(try cancellation.check()) { error in
      XCTAssertEqual((error as? PigeonError)?.code, "cancelled")
    }
  }

  func testUncancelledRequestCanRegisterAndEncode() throws {
    let cancellation = ExtractionCancellation()
    try cancellation.check()
    try cancellation.register(generator())
    try cancellation.check()
  }
}

private final class CancellationAsset: AVURLAsset, @unchecked Sendable {
  var didCancelLoading = false

  override func cancelLoading() {
    didCancelLoading = true
    super.cancelLoading()
  }
}
