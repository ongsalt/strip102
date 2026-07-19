import Cnanosvg
import Foundation

/// Converts the parsed SVG's shapes into (path, color) pairs in paint order. Build this once
/// and redraw the same paths so they keep their identity for the renderer's strip cache.
func svgDrawList(
  _ image: UnsafeMutablePointer<NSVGimage>, verbose: Bool = false
) -> [(path: Path, color: Color)] {
  var list: [(path: Path, color: Color)] = []
  var shape = image.pointee.shapes
  var index = 0

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
      // built as a plain array first: appending through Path.segments would re-run the
      // copy-on-write accessor (and copy the array) on every single segment
      var segments: [PathSegment] = []

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
        segments.append(.cubic(curve))
        // why tf is it cubic bez
      }

      list.append((Path(segments: segments), color))
      path = path!.pointee.next
    }

    shape = shape!.pointee.next
    index += 1
  }

  return list
}

/// Rasterizes an already-parsed SVG, returning the canvas holding the RGBA8 pixels. The canvas
/// frees them when it goes out of scope.
func rasterizeSvg(
  _ image: UnsafeMutablePointer<NSVGimage>,
  scale: Float = 1.0,
  algorithm: FillAlgorithm = .default,
  verbose: Bool = true
) -> Canvas {
  let width = Int((image.pointee.width * scale).rounded(.up))
  let height = Int((image.pointee.height * scale).rounded(.up))

  var canvas = Canvas(width: width, height: height, fillAlgorithm: algorithm)
  canvas.scale(x: scale, y: scale)

  for (path, color) in svgDrawList(image, verbose: verbose) {
    canvas.draw(path, color: color)
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

  let pngPath =
    output
    ?? URL(fileURLWithPath: filename).deletingPathExtension().appendingPathExtension("png").path

  try! canvas.save(to: pngPath)

  print("importSvg(\(filename)) took \(clock.now - start)")
}


