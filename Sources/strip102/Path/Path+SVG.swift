import Cnanosvg
import Foundation

/// Rasterizes an already-parsed SVG, returning the canvas holding the RGBA8 pixels. The canvas
/// frees them when it goes out of scope.
func rasterizeSvg(
  _ image: UnsafeMutablePointer<NSVGimage>,
  scale: Float = 1.0,
  algorithm: FillAlgorithm = .default,
  verbose: Bool = true
) -> Canvas {
  var shape = image.pointee.shapes
  var index = 0

  let width = Int((image.pointee.width * scale).rounded(.up))
  let height = Int((image.pointee.height * scale).rounded(.up))

  var canvas = Canvas(width: width, height: height, fillAlgorithm: algorithm)
  canvas.scale(x: scale, y: scale)

  while shape != nil {
    // nanosvg packs color as 0xAABBGGRR, not the 0xRRGGBB our Color(hex:) expects
    let rawColor = shape!.pointee.fill.color
    let r = (rawColor >> 0) & 0xFF
    let g = (rawColor >> 8) & 0xFF
    let b = (rawColor >> 16) & 0xFF
    let color = Color(hex: (r << 16) | (g << 8) | b)
    if verbose {
      print("shape: \(index), \(color)")
    }

    var path = shape?.pointee.paths
    while path != nil {
      var mPath = Path()

      // oh my fucking god
      for i in stride(from: 0, to: path!.pointee.npts - 1, by: 3) {
        let p = (path!.pointee.pts + Int(i) * 2)

        // drawCubicBez(p[0],p[1], p[2],p[3], p[4],p[5], p[6],p[7]);
        let curve = CubicBezierCurve(
          start: Point(p[0], p[1]),
          control1: Point(p[2], p[3]),
          control2: Point(p[4], p[5]),
          end: Point(p[6], p[7])
        )
        mPath.segments.append(.cubic(curve))
        // why tf is it cubic bez
      }

      canvas.draw(mPath, color: color)

      path = path!.pointee.next
    }

    shape = shape!.pointee.next
    index += 1
  }

  canvas.flush()

  return canvas
}

/// Parses an SVG file. The caller owns the returned image and must `nsvgDelete` it.
func parseSvg(_ filename: String) -> UnsafeMutablePointer<NSVGimage> {
  guard let image = nsvgParseFromFile(filename, "px", 96) else {
    fatalError("Cannot parse \(filename)")
  }
  return image
}

func importSvg(
  _ filename: String, scale: Float = 1.0, algorithm: FillAlgorithm = .default,
  output: String? = nil
) {
  let clock = ContinuousClock()
  let start = clock.now

  let parsed = parseSvg(filename)
  defer { nsvgDelete(parsed) }

  var canvas = rasterizeSvg(parsed, scale: scale, algorithm: algorithm)

  let pamPath =
    output
    ?? URL(fileURLWithPath: filename).deletingPathExtension().appendingPathExtension("pam").path

  try! canvas.save(to: pamPath)

  print("importSvg(\(filename)) took \(clock.now - start)")
}

/// Runs the rasterize step `iterations` times against a single parse, with no file I/O, for
/// benchmarking.
func benchSvg(
  _ filename: String,
  scale: Float = 1.0,
  algorithm: FillAlgorithm = .default,
  iterations: Int = 1000
) {
  let parsed = parseSvg(filename)
  defer { nsvgDelete(parsed) }

  let clock = ContinuousClock()
  var durations: [Duration] = []
  durations.reserveCapacity(iterations)

  for _ in 0..<iterations {
    let start = clock.now
    let canvas = rasterizeSvg(parsed, scale: scale, algorithm: algorithm, verbose: false)
    durations.append(clock.now - start)
    _ = consume canvas
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

func convertToPng(ppmPath: String, pngPath: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["ffmpeg", "-nostdin", "-y", "-i", ppmPath, pngPath]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice

  do {
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      fatalError("ffmpeg exited with status \(process.terminationStatus)")
    }
  } catch {
    fatalError("Cannot run ffmpeg: \(error)")
  }
}

/// Writes a binary PAM (P7, RGB_ALPHA). Unlike PPM, PAM keeps the alpha channel, so the AA
/// living in partial coverage makes it into the file.
func writePam(pixels: borrowing Span<Pixel>, width: Int, height: Int, to filename: String) throws {
  precondition(pixels.count >= width * height, "pixel buffer smaller than the image")

  var data = Data(
    "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".utf8)
  data.reserveCapacity(data.count + width * height * 4)

  for i in 0..<(width * height) {
    let pixel = pixels[i]
    data.append(contentsOf: [pixel[0], pixel[1], pixel[2], pixel[3]])
  }

  try data.write(to: URL(fileURLWithPath: filename))
}
