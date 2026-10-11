import AVFoundation
import Flutter
import Foundation
import ImageIO

/// Retains cancellation even while the request is still loading metadata.
final class ExtractionCancellation {
  private let lock = NSLock()
  private var cancelled = false
  private var asset: AVURLAsset?
  private var generator: AVAssetImageGenerator?

  func cancel() {
    lock.lock()
    cancelled = true
    let asset = asset
    let generator = generator
    lock.unlock()
    asset?.cancelLoading()
    generator?.cancelAllCGImageGeneration()
  }

  func registerAsset(_ asset: AVURLAsset) throws {
    lock.lock()
    defer { lock.unlock() }
    try checkLocked()
    self.asset = asset
  }

  func register(_ generator: AVAssetImageGenerator) throws {
    lock.lock()
    defer { lock.unlock() }
    try checkLocked()
    self.generator = generator
  }

  func check() throws {
    lock.lock()
    defer { lock.unlock() }
    try checkLocked()
  }

  private func checkLocked() throws {
    if cancelled {
      throw PigeonError(code: "cancelled", message: "generation cancelled", details: nil)
    }
  }
}

/// Stateless single-frame extractor built on AVAssetImageGenerator.
///
/// Performance rules (see the package design doc):
/// - Infinite time tolerances by default (nearest key frame, the cheapest
///   decode); zero tolerances only when `exact` is requested.
/// - `maximumSize` is set from a precomputed fit box so large sources are
///   downscaled during decode; frames are never upscaled.
/// - The frame is encoded straight to the destination file through
///   CGImageDestination; no UIImage, no intermediate NSData.
/// - One generator per request, retained until completion, so cancellation
///   can abort exactly one request's generation.
final class Extractor {
  private let lock = NSLock()
  private var cancellations: [String: ExtractionCancellation] = [:]

  func extract(
    request: ExtractRequest,
    completion: @escaping (Result<ExtractResult, Error>) -> Void
  ) {
    let cancellation = ExtractionCancellation()
    lock.lock()
    cancellations[request.requestId] = cancellation
    lock.unlock()
    Task.detached(priority: .utility) {
      let result: Result<ExtractResult, Error>
      do {
        result = .success(try await self.performExtract(request, cancellation: cancellation))
      } catch let error as PigeonError {
        result = .failure(error)
      } catch {
        do {
          // Asset loading can wrap cancellation in a network error. The
          // request's cancellation state is authoritative in that case.
          try cancellation.check()
          result = .failure(Self.classify(error))
        } catch {
          result = .failure(error)
        }
      }
      self.removeCancellation(request.requestId)
      DispatchQueue.main.async { completion(result) }
    }
  }

  func cancel(requestId: String) {
    lock.lock()
    let cancellation = cancellations[requestId]
    lock.unlock()
    cancellation?.cancel()
  }

  private func removeCancellation(_ requestId: String) {
    lock.lock()
    cancellations.removeValue(forKey: requestId)
    lock.unlock()
  }

  // MARK: - Pipeline

  private func performExtract(
    _ request: ExtractRequest, cancellation: ExtractionCancellation
  ) async throws -> ExtractResult {
    try cancellation.check()
    let asset = try resolveAsset(request)
    try cancellation.registerAsset(asset)
    let (track, durationMs) = try await loadVideoTrack(of: asset)
    try cancellation.check()

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    if request.exact {
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
    } else {
      generator.requestedTimeToleranceBefore = .positiveInfinity
      generator.requestedTimeToleranceAfter = .positiveInfinity
    }
    if let box = try await fitBox(for: track, request: request) {
      generator.maximumSize = box
    }

    var positionMs = max(request.positionMs, 0)
    if durationMs > 0 { positionMs = min(positionMs, durationMs) }
    let time = CMTime(value: CMTimeValue(positionMs), timescale: 1000)

    try cancellation.register(generator)
    let image = try await generateImage(generator, at: time)
    try cancellation.check()
    try encode(image, request: request)
    return ExtractResult(width: Int64(image.width), height: Int64(image.height))
  }

  private func resolveAsset(_ request: ExtractRequest) throws -> AVURLAsset {
    switch request.sourceType {
    case .asset:
      let key: String
      if let package = request.assetPackage {
        key = FlutterDartProject.lookupKey(forAsset: request.source, fromPackage: package)
      } else {
        key = FlutterDartProject.lookupKey(forAsset: request.source)
      }
      guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
        throw PigeonError(
          code: "assetNotFound", message: "asset not found: \(request.source)", details: nil)
      }
      return AVURLAsset(url: URL(fileURLWithPath: path))
    case .file:
      guard FileManager.default.fileExists(atPath: request.source) else {
        throw PigeonError(
          code: "fileNotFound", message: "file does not exist: \(request.source)", details: nil)
      }
      return AVURLAsset(url: URL(fileURLWithPath: request.source))
    case .network:
      guard let url = URL(string: request.source),
        url.scheme == "http" || url.scheme == "https"
      else {
        throw PigeonError(
          code: "invalidSource", message: "invalid url: \(request.source)", details: nil)
      }
      var options: [String: Any] = [:]
      if let headers = request.headers, !headers.isEmpty {
        // De-facto AVURLAsset option; the only way to attach headers without
        // a resource-loader delegate.
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
      }
      return AVURLAsset(url: url, options: options)
    }
  }

  private func loadVideoTrack(of asset: AVURLAsset) async throws -> (AVAssetTrack, Int64) {
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration)
    guard let track = tracks.first else {
      throw PigeonError(
        code: "unsupportedMedia", message: "media has no video track", details: nil)
    }
    let durationMs =
      duration.isNumeric ? Int64((duration.seconds * 1000).rounded()) : Int64(0)
    return (track, durationMs)
  }

  /// Largest size that fits inside (maxWidth, maxHeight) preserving aspect,
  /// or nil when unconstrained or the source is already small enough.
  private func fitBox(for track: AVAssetTrack, request: ExtractRequest) async throws -> CGSize? {
    if request.maxWidth <= 0 && request.maxHeight <= 0 { return nil }
    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let display = naturalSize.applying(transform)
    let width = abs(display.width)
    let height = abs(display.height)
    guard width > 0, height > 0 else { return nil }

    let scaleW = request.maxWidth > 0 ? CGFloat(request.maxWidth) / width : .greatestFiniteMagnitude
    let scaleH =
      request.maxHeight > 0 ? CGFloat(request.maxHeight) / height : .greatestFiniteMagnitude
    let scale = min(scaleW, scaleH)
    if scale >= 1 { return nil }
    return CGSize(
      width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
  }

  private func generateImage(
    _ generator: AVAssetImageGenerator, at time: CMTime
  ) async throws -> CGImage {
    if #available(iOS 16.0, *) {
      return try await generator.image(at: time).image
    }
    return try await withCheckedThrowingContinuation { continuation in
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
        _, image, _, resultCode, error in
        switch resultCode {
        case .succeeded where image != nil:
          continuation.resume(returning: image!)
        case .cancelled:
          continuation.resume(
            throwing: PigeonError(
              code: "cancelled", message: "generation cancelled", details: nil))
        default:
          continuation.resume(
            throwing: error
              ?? PigeonError(
                code: "extractionFailed", message: "no image produced", details: nil))
        }
      }
    }
  }

  private func encode(_ image: CGImage, request: ExtractRequest) throws {
    let uti: CFString =
      request.format == "png" ? "public.png" as CFString : "public.jpeg" as CFString
    let url = URL(fileURLWithPath: request.destPath) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, uti, 1, nil) else {
      throw PigeonError(
        code: "io", message: "cannot create \(request.destPath)", details: nil)
    }
    var properties: [CFString: Any] = [:]
    if request.format != "png" {
      let quality = Double(min(max(request.quality, 1), 100)) / 100.0
      properties[kCGImageDestinationLossyCompressionQuality] = quality
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw PigeonError(
        code: "encodingFailed", message: "CGImageDestinationFinalize failed", details: nil)
    }
  }

  // MARK: - Error classification

  private static func classify(_ error: Error) -> PigeonError {
    let nsError = error as NSError
    if isNetworkError(nsError) {
      return PigeonError(
        code: "network", message: nsError.localizedDescription, details: nil)
    }
    if nsError.domain == AVFoundationErrorDomain {
      if nsError.code == AVError.Code.operationCancelled.rawValue {
        return PigeonError(
          code: "cancelled", message: "generation cancelled", details: nil)
      }
      return PigeonError(
        code: "unsupportedMedia", message: nsError.localizedDescription, details: nil)
    }
    if error is CancellationError {
      return PigeonError(code: "cancelled", message: "generation cancelled", details: nil)
    }
    return PigeonError(
      code: "extractionFailed", message: nsError.localizedDescription, details: nil)
  }

  private static func isNetworkError(_ error: NSError) -> Bool {
    var current: NSError? = error
    var depth = 0
    while let e = current, depth < 4 {
      if e.domain == NSURLErrorDomain { return true }
      current = e.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    return false
  }
}
