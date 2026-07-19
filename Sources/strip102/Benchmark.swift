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
  iterations: Int = 1000
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
      canvas.draw(path, color: color)
    }
    canvas.flush()
    durations.append(clock.now - start)
  }

  let total = durations.reduce(Duration.zero, +)
  let average = total / iterations
  let minimum = durations.min()!
  let maximum = durations.max()!

  func seconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }

  let totalStr = String(format: "%.8f", seconds(total))
  let avgStr = String(format: "%.6f", seconds(average) * 1000)
  let minStr = String(format: "%.6f", seconds(minimum) * 1000)
  let maxStr = String(format: "%.6f", seconds(maximum) * 1000)

  print(
    "bench \(filename) x\(iterations): total=\(totalStr)s, avg=\(avgStr)ms, min=\(minStr)ms, max=\(maxStr)ms"
  )
}
