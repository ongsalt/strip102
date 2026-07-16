import Cnanosvg
import Foundation

struct RenderedImage {
  var pixels: UnsafeMutableBufferPointer<Pixel>
  var width: Int
  var height: Int
}

/// Rasterizes an already-parsed SVG into an RGBA8 pixel buffer. The caller owns `pixels` and must
/// `deallocate()` it.
func rasterizeSvg(_ image: UnsafeMutablePointer<NSVGimage>, scale: Float = 1.0, verbose: Bool = true)
  -> RenderedImage
{
  var shape = image.pointee.shapes
  var index = 0

  let width = Int((image.pointee.width * scale).rounded(.up))
  let height = Int((image.pointee.height * scale).rounded(.up))
  let pixels = UnsafeMutableBufferPointer<Pixel>
    .allocate(capacity: width * height)

  var span = pixels.mutableSpan
  let transform = Affine.identity.scaled(x: scale, y: scale)

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

      fillScanline(
        path: mPath, color: color, transform: transform, pixels: &span, width: width, height: height)

      path = path!.pointee.next
    }

    shape = shape!.pointee.next
    index += 1
  }

  return RenderedImage(pixels: pixels, width: width, height: height)
}

/// Parses an SVG file. The caller owns the returned image and must `nsvgDelete` it.
func parseSvg(_ filename: String) -> UnsafeMutablePointer<NSVGimage> {
  guard let image = nsvgParseFromFile(filename, "px", 96) else {
    fatalError("Cannot parse \(filename)")
  }
  return image
}

func importSvg(_ filename: String, scale: Float = 1.0) {
  let clock = ContinuousClock()
  let start = clock.now

  let parsed = parseSvg(filename)
  defer { nsvgDelete(parsed) }

  let image = rasterizeSvg(parsed, scale: scale)

  let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
  let ppmPath = "\(stem).ppm"

  try! writePpm(pixels: image.pixels.span, width: image.width, height: image.height, to: ppmPath)

  image.pixels.deallocate()

  print("importSvg(\(filename)) took \(clock.now - start)")

  convertToPng(ppmPath: ppmPath, pngPath: "\(stem).png")
}

/// Runs the rasterize step `iterations` times against a single parse, with no file I/O, for
/// benchmarking.
func benchSvg(_ filename: String, scale: Float = 1.0, iterations: Int = 1000) {
  let parsed = parseSvg(filename)
  defer { nsvgDelete(parsed) }

  let clock = ContinuousClock()
  var durations: [Duration] = []
  durations.reserveCapacity(iterations)

  for _ in 0..<iterations {
    let start = clock.now
    let image = rasterizeSvg(parsed, scale: scale, verbose: false)
    durations.append(clock.now - start)
    image.pixels.deallocate()
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

/// Writes a binary PPM (P6), dropping alpha since PPM has no alpha channel.
func writePpm(pixels: borrowing Span<Pixel>, width: Int, height: Int, to filename: String) throws {
  precondition(pixels.count >= width * height, "pixel buffer smaller than the image")

  var data = Data("P6\n\(width) \(height)\n255\n".utf8)
  data.reserveCapacity(data.count + width * height * 3)

  for i in 0..<(width * height) {
    let pixel = pixels[i]
    data.append(contentsOf: [pixel[0], pixel[1], pixel[2]])
  }

  try data.write(to: URL(fileURLWithPath: filename))
}
