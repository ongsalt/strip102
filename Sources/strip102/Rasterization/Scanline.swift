import Foundation

/// The working format: premultiplied RGBA, one float per channel, on a 0...255 scale.
/// Premultiplied because source-over is then a multiply and a fused multiply-add, with no
/// division anywhere. Everything composites in this type whatever `Pixel` is.
public typealias PixelF = SIMD4<Float>

/// Clamps and rounds a working value into bytes. Used for image output regardless of what
/// `Pixel` is.
///
/// The rounding goes through the magic-number bias: adding 2^23 pushes the value against the
/// mantissa's low end, leaving the round-to-nearest integer in the low bits for the truncating
/// narrow to pick up. The obvious `SIMD4<Int32>(clamped)` traps on out-of-range input, so Swift
/// emits a call per lane instead of one vectorized convert.
@inline(__always)
func packBytes(_ value: PixelF) -> SIMD4<UInt8> {
  let clamped =
    value
    .replacing(with: PixelF.zero, where: value .< PixelF.zero)
    .replacing(with: PixelF(repeating: 255), where: value .> PixelF(repeating: 255))

  let biased = clamped + PixelF(repeating: 0x1p23)
  return SIMD4<UInt8>(truncatingIfNeeded: unsafeBitCast(biased, to: SIMD4<UInt32>.self))
}

#if PixelF32

  /// Premultiplied RGBA, float per channel, 0...255. Build with `--traits PixelF32`.
  ///
  /// Blending never converts, and values stay unclamped through compositing — but the buffer is
  /// four times the bytes, which dominates once the canvas stops fitting in cache.
  public typealias Pixel = PixelF

  @inline(__always)
  func unpack(_ pixel: Pixel) -> PixelF { pixel }

  @inline(__always)
  func pack(_ value: PixelF) -> Pixel { value }

#else

  /// Premultiplied RGBA8. Storage only — nothing composites in this type.
  ///
  /// The pixel buffer is the one allocation that scales with the canvas, so its width decides
  /// whether large renders are DRAM-bound: at 3600² this is 52MB against a float buffer's
  /// 207MB. The cost is 8 bits of precision, which heavy overdraw can band.
  public typealias Pixel = SIMD4<UInt8>

  @inline(__always)
  func unpack(_ pixel: Pixel) -> PixelF {
    // widening vectorizes in both steps; it is the float->int direction that needs the bias
    PixelF(pixel)
  }

  @inline(__always)
  func pack(_ value: PixelF) -> Pixel { packBytes(value) }

#endif

extension Color {
  /// this color premultiplied, in the working scale. Deliberately unclamped: out-of-range
  /// values only get brought into range when they are packed.
  var pixel: PixelF {
    let scaled = alpha * 255
    return PixelF(red * scaled, green * scaled, blue * scaled, scaled)
  }

  /// this color in the canvas' storage format
  var storage: Pixel { pack(pixel) }
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
func blend(_ source: PixelF, _ destination: inout Pixel, _ opacity: Float) {
  // scaling a premultiplied color by coverage scales its alpha too, which is exactly right
  let contribution = source * opacity
  let inverse = 1 - contribution.w * (1 / 255)
  destination = pack(contribution + unpack(destination) * inverse)
}

/// triangle wave: 0 -> 1 over the first winding, 1 -> 0 over the second, and so on
@inline(__always)
func evenOddOpacity(_ winding: Float) -> Float {
  let magnitude = min(abs(winding), Float(1 << 24))
  let fraction = magnitude.truncatingRemainder(dividingBy: 1)
  return Int(magnitude) % 2 == 0 ? fraction : 1 - fraction
}
