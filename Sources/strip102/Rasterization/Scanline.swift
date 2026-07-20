import Foundation

/// RGBA, premultiplied alpha, one float per channel in the 0...1 range. Premultiplied because
/// source-over then costs a multiply and a fused multiply-add per pixel with no division at
/// all; the unpremultiply happens once, when the image is written out.
public typealias Pixel = SIMD4<Float>

extension Color {
  /// this color in the canvas' storage format. Deliberately unclamped: out-of-gamut and
  /// out-of-range values stay intact all the way through compositing, and are only brought
  /// into range when the image is written out.
  var pixel: Pixel {
    Pixel(red * alpha, green * alpha, blue * alpha, alpha)
  }
}


/// Selects which rasterizer `fill` dispatches to.
public enum FillAlgorithm: String, CaseIterable, Sendable {
  /// `fillScanline`: analytic (trapezoid) coverage, one active edge list per scanline.
  case scanline
  /// `fillSparseStrip`: tile-binned lines gathered into sparse strips.
  case sparseStrip = "sparse-strip"
  /// `BandedScanlineRenderer`: scanline over cached 16-row bands, rendered in parallel with
  /// a SIMD16 (one lane per row) winding accumulator.
  case bandedScanline = "banded-scanline"

  public static let `default`: FillAlgorithm = .scanline
}

// To be fair, this one can also `breakIntoLines` in parallel
/// Scanline fill with analytic (trapezoid) coverage.
///
/// `pixels` is tightly packed RGBA8, one `Pixel` per pixel, `width * height` long. A byte buffer
/// can be viewed as one with `rawBuffer.bindMemory(to: Pixel.self)`: `Pixel` is 4 bytes, stride 4.
public func fillScanline(
  path: borrowing Path,
  color: borrowing Color,
  transform: Affine = .identity,
  pixels: inout MutableSpan<Pixel>,
  width: Int,
  height: Int
) {
  precondition(pixels.count >= width * height, "pixel buffer smaller than the image")
  guard width > 0, height > 0 else { return }

  let lines = path.breakIntoLines(transform: transform)
  guard !lines.isEmpty else { return }

  let fillRule = path.fillRule

  var linesByStartY: [Int: [Int]] = [:]
  var linesByEndY: [Int: [Int]] = [:]

  var minY = Int.max
  var maxY = Int.min

  for (index, line) in lines.enumerated() {
    let (y1, y2) = line.yBounds
    minY = min(y1, minY)
    maxY = max(y2, maxY)
    linesByStartY[y1, default: []].append(index)
    linesByEndY[y2, default: []].append(index)
  }

  // a path may sit partly outside the image; the tables and the row slice are only valid inside it
  minY = max(minY, 0)
  maxY = min(maxY, height - 1)
  guard minY <= maxY else { return }

  let w = width

  // sorted (by x) indices into `lines`
  var activeSegments: [Int] = []

  // fill of the current pixel
  var fillTable = [Float](repeating: 0, count: w)
  // fill of everything after the current pixel
  var coverageTable = [Float](repeating: 0, count: w)

  // premultiply once per fill, not once per pixel
  let source = color.pixel

  // x-range still holding nonzero values from the last row that wrote to the tables (empty
  // when dirtyStart > dirtyEnd). Only that range needs clearing before the next row's
  // accumulation, instead of the whole `w`-wide table — a shape narrow relative to the
  // canvas would otherwise pay for zeroing columns it never touches, every row.
  var dirtyStart = 0
  var dirtyEnd = -1

  for y in minY...maxY {
    // update active segment list, sorted by x
    if let starting = linesByStartY[y] {
      activeSegments.append(contentsOf: starting)
      // its nearly sorted btw
      activeSegments.sort { lines[$0].minX < lines[$1].minX }
    }

    var rowStart = w
    var rowEnd = 0
    let shouldSkip = activeSegments.isEmpty

    if !shouldSkip {
      var fill = fillTable.mutableSpan
      var coverage = coverageTable.mutableSpan
      if dirtyStart <= dirtyEnd {
        for x in dirtyStart...dirtyEnd {
          fill[unchecked: x] = 0
          coverage[unchecked: x] = 0
        }
      }

      for lineIndex in activeSegments {
        // clip it to the y-strip
        guard let strip = lines[lineIndex].clipY(from: Float(y), to: Float(y + 1)) else {
          continue
        }

        let (xStart, xEnd) = strip.xBounds
        let clampedStart = max(xStart, 0)
        let clampedEnd = min(xEnd, w - 1)
        guard clampedStart <= clampedEnd else { continue }

        rowStart = min(rowStart, clampedStart)
        rowEnd = max(rowEnd, clampedEnd)

        for x in clampedStart...clampedEnd {
          guard let cell = strip.clipX(from: Float(x), to: Float(x + 1)) else {
            continue
          }

          // print("[\(x) \(y)] \(cell)")
          let dy = cell.end.y - cell.start.y
          let xMid = (cell.start.x + cell.end.x) / 2 - Float(x)

          // x is clamped to 0..<w and the tables are w long
          coverage[unchecked: x] += dy
          // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
          fill[unchecked: x] += dy * (1 - xMid)

          // print(" > coverage:\(coverage[x]) fill:\(fill[x])")
        }
      }
    }

    // drop the segments that end on this row
    if let ending = linesByEndY[y] {
      let done = Set(ending)
      activeSegments.removeAll { done.contains($0) }
    }

    guard !shouldSkip, rowStart <= rowEnd else { continue }

    // this row's writes are the only nonzero region now, since the old dirty range (if any)
    // was cleared above before accumulating into this one
    dirtyStart = rowStart
    dirtyEnd = rowEnd

    // resolve pass
    let fill = fillTable.span
    let coverage = coverageTable.span
    var acc: Float = 0

    for x in rowStart...rowEnd {
      // rowStart/rowEnd came from clamped line bounds, so they are inside the tables
      let winding = acc + fill[unchecked: x]
      acc += coverage[unchecked: x]

      let opacity =
        switch fillRule {
        case .nonZero:
          min(abs(winding), 1)
        case .evenOdd:
          evenOddOpacity(winding)
        }

      if opacity < .ulpOfOne {
        continue
      }

      // y < height, x < w, and `pixels` holds at least width * height of them
      blend(source, &pixels[unchecked: w * y + x], opacity)
    }
  }
}

/// Source-over in encoded (non-linear) space, premultiplied: scale the source by coverage, then
/// one fused multiply-add against the destination. No division, and all four channels at once.
///
/// `source` must already be premultiplied — use `Color.pixel`. Blending in encoded rather than
/// linear-light space darkens edges where a light shape overlaps a dark background, which is the
/// same tradeoff the byte-integer version made.
@inline(__always)
func blend(_ source: Pixel, _ destination: inout Pixel, _ opacity: Float) {
  // scaling a premultiplied color by coverage scales its alpha too, which is exactly right
  let contribution = source * opacity
  destination = contribution + destination * (1 - contribution.w)
}

/// triangle wave: 0 -> 1 over the first winding, 1 -> 0 over the second, and so on
@inline(__always)
func evenOddOpacity(_ winding: Float) -> Float {
  let magnitude = min(abs(winding), Float(1 << 24))
  let fraction = magnitude.truncatingRemainder(dividingBy: 1)
  return Int(magnitude) % 2 == 0 ? fraction : 1 - fraction
}
