import Foundation

/// RGBA8, straight (non-premultiplied) alpha
public typealias Pixel = [4 of UInt8]

/// RGBA8 straight-alpha color, quantized straight from `Color` with no linear-light conversion.
public struct Color8: Sendable, Equatable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8
  public var alpha: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init(_ color: Color) {
    self.red = UInt8((color.red.clamped(from: 0, to: 1) * 255).rounded())
    self.green = UInt8((color.green.clamped(from: 0, to: 1) * 255).rounded())
    self.blue = UInt8((color.blue.clamped(from: 0, to: 1) * 255).rounded())
    self.alpha = UInt8((color.alpha.clamped(from: 0, to: 1) * 255).rounded())
  }
}

/// Selects which rasterizer `fill` dispatches to.
public enum FillAlgorithm: String, CaseIterable, Sendable {
  /// `fillScanline`: analytic (trapezoid) coverage, one active edge list per scanline.
  case scanline
  /// `fillSparseStrip`: tile-binned lines gathered into sparse strips.
  case sparseStrip = "sparse-strip"

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

  // quantize once per fill, not once per pixel
  let source = Color8(color)

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
      fill.update(repeating: 0)
      coverage.update(repeating: 0)

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

          let dy = cell.end.y - cell.start.y
          let xMid = (cell.start.x + cell.end.x) / 2 - Float(x)

          // x is clamped to 0..<w and the tables are w long
          coverage[unchecked: x] += dy
          // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
          fill[unchecked: x] += dy * (1 - xMid)
        }
      }
    }

    // drop the segments that end on this row
    if let ending = linesByEndY[y] {
      let done = Set(ending)
      activeSegments.removeAll { done.contains($0) }
    }

    guard !shouldSkip, rowStart <= rowEnd else { continue }

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

/// Source-over blended directly in encoded (non-linear) byte space using integer math: cheaper
/// than linear-light float blending, at the cost of darkened edges where a light shape overlaps
/// a dark background.
@inline(__always)
func blend(_ source: Color8, _ destination: inout Pixel, _ opacity: Float) {
  let sourceAlpha = UInt32(source.alpha) * UInt32(opacity * 255.0) / 255

  if sourceAlpha == 255 {
    destination[0] = source.red
    destination[1] = source.green
    destination[2] = source.blue
    destination[3] = source.alpha
    return
  }

  let destinationAlpha = UInt32(destination[3])
  let outAlpha = sourceAlpha + destinationAlpha * (255 - sourceAlpha) / 255

  if outAlpha == 0 {
    destination = [0, 0, 0, 0]
    return
  }

  @inline(__always)
  func compositeChannel(_ s: UInt8, _ d: UInt8) -> UInt8 {
    let out = (UInt32(s) * sourceAlpha + UInt32(d) * destinationAlpha * (255 - sourceAlpha) / 255) / outAlpha
    return UInt8(truncatingIfNeeded: out)
  }

  destination[0] = compositeChannel(source.red, destination[0])
  destination[1] = compositeChannel(source.green, destination[1])
  destination[2] = compositeChannel(source.blue, destination[2])
  destination[3] = UInt8(outAlpha)
}

/// triangle wave: 0 -> 1 over the first winding, 1 -> 0 over the second, and so on
@inline(__always)
private func evenOddOpacity(_ winding: Float) -> Float {
  let magnitude = min(abs(winding), Float(1 << 24))
  let fraction = magnitude.truncatingRemainder(dividingBy: 1)
  return Int(magnitude) % 2 == 0 ? fraction : 1 - fraction
}
