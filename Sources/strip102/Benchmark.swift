import Cnanosvg
import Foundation

/// Runs the rasterize step `iterations` times against a single parse, with no file I/O.
/// The draw list and the canvas are built once and reused across frames like a real app
/// would — recreating either would give every path a fresh identity and defeat the
/// renderer's strip cache.
func benchSvg(
  _ filename: String,
  scale: Float = 1.0,
  algorithm: FillAlgorithm = .default,
  iterations: Int = 1000,
  /// marks every path dirty each frame, so caches never hit. Models animating geometry, where
  /// the rasterization the cache normally hides has to be paid every frame
  invalidateEveryFrame: Bool = false
) {
  let parsed = parseSvg(filename)
  defer { nsvgDelete(parsed) }

  let drawList = svgDrawList(parsed)

  let width = Int((parsed.pointee.width * scale).rounded(.up))
  let height = Int((parsed.pointee.height * scale).rounded(.up))
  var canvas = Canvas(width: width, height: height, fillAlgorithm: algorithm)
  canvas.scale(x: scale, y: scale)

  let clock = ContinuousClock()
  var durations: [Duration] = []
  durations.reserveCapacity(iterations)

  for _ in 0..<iterations {
    let start = clock.now
    canvas.clear()
    for (path, color) in drawList {
      if invalidateEveryFrame { path.dirty = true }
      canvas.draw(path, color: color)
    }
    canvas.flush()
    durations.append(clock.now - start)
  }

  let total = durations.reduce(Duration.zero, +)
  let average = total / iterations
  let maximum = durations.max()!
  let slowestIteration = durations.firstIndex(of: maximum)!

  func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }

  func milliseconds(_ duration: Duration) -> String {
    String(format: "%.3f", seconds(duration) * 1000)
  }

  // percentiles, because a single max says nothing about whether the tail is one cold first
  // frame or jitter spread through the run
  let sorted = durations.sorted()
  func percentile(_ q: Double) -> Duration {
    sorted[min(Int(Double(sorted.count - 1) * q), sorted.count - 1)]
  }

  print(
    """
    bench \(filename) x\(iterations): total=\(String(format: "%.6f", seconds(total)))s \
    avg=\(milliseconds(average))ms
      min=\(milliseconds(sorted[0]))ms p50=\(milliseconds(percentile(0.5)))ms \
    p90=\(milliseconds(percentile(0.9)))ms p99=\(milliseconds(percentile(0.99)))ms \
    max=\(milliseconds(maximum))ms
      slowest was iteration \(slowestIteration); \
    first five: \(durations.prefix(5).map(milliseconds).joined(separator: ", "))ms
    """
  )
}
