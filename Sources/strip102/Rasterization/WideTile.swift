import Dispatch

/// nested array, flatten, with offset table
struct WideTileCommands {
  var commands: [WideTileDrawOp]
  var offsets: [Int]

  var tileCount: Int { offsets.count - 1 }
}

func generateWideTileCommands(
  width: Int,
  height: Int,
  strips: [[Strip]],
  ops: Span<DrawOp>,
  tileSize: Int
) -> WideTileCommands {
  let wideTileXCount = Int((Float(width) / Float(WIDE_TILE_WIDTH)).rounded(.up))
  let wideTileYCount = Int((Float(height) / Float(TILE_SIZE)).rounded(.up))
  let tileCount = wideTileXCount * wideTileYCount

  let threadCount = max(1, min(getRealCoreCount(), wideTileYCount))
  let rowChunk = (wideTileYCount + threadCount - 1) / threadCount

  nonisolated(unsafe) let strips = strips

  // Pass 1: count commands per wide tile (same splitting logic as pass 3, tallying only), so
  // the flat array's per-tile slices can be sized exactly via a prefix sum below.
  var counts = [Int](repeating: 0, count: tileCount)
  counts.withUnsafeMutableBufferPointer { countsBuffer in
    nonisolated(unsafe) let countsBuffer = countsBuffer
    DispatchQueue.concurrentPerform(iterations: threadCount) { threadIndex in
      let yStart = threadIndex * rowChunk
      let yEnd = min(yStart + rowChunk, wideTileYCount)
      guard yStart < yEnd else { return }
      walkStrips(
        ops: ops, strips: strips, tileSize: tileSize, wideTileXCount: wideTileXCount,
        tileCount: tileCount, yStart: yStart, yEnd: yEnd
      ) { index, _ in
        countsBuffer[index] += 1
      }
    }
  }

  // Pass 2: prefix sum -> offsets. tile i's slice is offsets[i]..<offsets[i + 1].
  var offsets = [Int](repeating: 0, count: tileCount + 1)
  var running = 0
  for i in 0..<tileCount {
    offsets[i] = running
    running += counts[i]
  }
  offsets[tileCount] = running
  let totalCommands = running

  // Pass 3: same walk again, now actually emitting into the flat array. Each tile gets a
  // write cursor starting at its offset; since tiles are still partitioned by row band (one
  // thread per band, same as pass 1), no two threads ever touch the same cursor or the same
  // flat-array position, so plain (non-atomic) increments are safe.
  var writeCursor = Array(offsets.prefix(tileCount))

  let commands: [WideTileDrawOp] = Array(unsafeUninitializedCapacity: totalCommands) {
    out, initializedCount in
    initializedCount = totalCommands
    nonisolated(unsafe) let out = out

    writeCursor.withUnsafeMutableBufferPointer { cursorBuffer in
      nonisolated(unsafe) let cursorBuffer = cursorBuffer
      DispatchQueue.concurrentPerform(iterations: threadCount) { threadIndex in
        let yStart = threadIndex * rowChunk
        let yEnd = min(yStart + rowChunk, wideTileYCount)
        guard yStart < yEnd else { return }
        walkStrips(
          ops: ops, strips: strips, tileSize: tileSize, wideTileXCount: wideTileXCount,
          tileCount: tileCount, yStart: yStart, yEnd: yEnd
        ) { index, op in
          let position = cursorBuffer[index]
          out.initializeElement(at: position, to: op)
          cursorBuffer[index] = position + 1
        }
      }
    }
  }

  return WideTileCommands(commands: commands, offsets: offsets)
}

// shared splitting/geometry logic between the counting and filling passes, so they can't drift
@inline(__always)
private func walkStrips(
  ops: Span<DrawOp>,
  strips: [[Strip]],
  tileSize: Int,
  wideTileXCount: Int,
  tileCount: Int,
  yStart: Int,
  yEnd: Int,
  emit: (Int, WideTileDrawOp) -> Void
) {
  for i in ops.indices {
    // generate command in painter order
    let opStrips = strips[i]

    // in tile unit (x, y), end of the last strip emitted on this row
    var lastStripEnd: (x: Int, y: Int)?
    for strip in opStrips {
      let wideTileY = Int(strip.y)
      guard wideTileY >= yStart && wideTileY < yEnd else { continue }

      // strip is ordered by x anyway, so by the time we generate .solid it gonna be well form

      // in tile unit (w)
      let coverageWidth = strip.coverageBuffer.count / (tileSize * tileSize)
      // in tile size

      // strip may got split
      // in wideTile index
      let wideTileXStart = Int(strip.x) * TILE_SIZE / WIDE_TILE_WIDTH
      // wideTileX where this end; same scale as wideTileXStart (wideTile-column units), computed
      // from the strip's last covered tile index rather than mixing tile-index and column scales
      let wideTileXEnd = (Int(strip.x) + coverageWidth - 1) * TILE_SIZE / WIDE_TILE_WIDTH

      // 1 widetile is 64 4x4 tile, tile unit, relative to wideTile start
      let WIDTH = WIDE_TILE_WIDTH / TILE_SIZE
      let x: UInt16 = UInt16(Int(strip.x) - wideTileXStart * (WIDTH))

      if strip.shouldFillLeft, let lastStripEnd, wideTileY == lastStripEnd.y {
        // fill the gap between the end of the previous strip and the start of
        // this one with the winding number carried over (background), splitting
        // at wide tile boundaries since a draw command only lives in one wide tile
        var fillX = lastStripEnd.x
        let fillEnd = Int(strip.x)
        while fillX < fillEnd {
          let fillWideTileX = fillX / WIDTH
          let localX = fillX % WIDTH
          let filledWidth = min(fillEnd - fillX, WIDTH - localX)
          let fillWideTileIndex = fillWideTileX + wideTileY * wideTileXCount
          if fillWideTileIndex < tileCount {
            emit(
              fillWideTileIndex,
              WideTileDrawOp.solid(
                x: UInt16(localX),
                w: UInt16(filledWidth),
                ops[i].color
              )
            )
          }
          fillX += filledWidth
        }
      }

      // in tile unit
      var areaLeft = coverageWidth
      var currentX = x  // relative to widetile
      var currentOffset = 0
      for wideTileX in wideTileXStart...wideTileXEnd {
        let wideTileIndex = wideTileX + wideTileY * wideTileXCount
        // in tile unit (w); only the first chunk starts mid-widetile (at currentX), so only it
        // has less than the full 64 tiles of room left before this widetile's right edge
        let consumed = min(areaLeft, WIDTH - Int(currentX))

        if wideTileIndex >= tileCount {
          break
        }

        emit(
          wideTileIndex,
          WideTileDrawOp.aa(
            x: currentX,
            w: UInt16(consumed),  // it tile unit, should not overflow
            ops[i].color,
            coverageBuffer: strip.coverageBuffer,
            offset: UInt16(currentOffset)
          )
        )
        // x will always be 0 in later iteration

        currentOffset += consumed
        areaLeft -= consumed
        currentX = 0
      }

      lastStripEnd = (x: Int(strip.x) + coverageWidth, y: wideTileY)
    }
  }
}

/// Below this many ops, staging the tile costs more than it saves: the load and the flush are
/// two extra passes over the same columns the blend would have touched once.
/// Staging only pays off when a column is blended by several ops: staged, a column costs three
/// passes over memory (load, blend, flush) against the direct path's one. So the gate is the
/// tile's average overdraw — total op column-extent over the number of distinct columns touched
/// — rather than a raw op count, which says nothing about whether the ops overlap.
private let stagingMinimumOverdraw = 100000

/// One bit per pixel column of a wide tile.
private typealias ColumnMask = [4 of UInt64]

@inline(__always)
private func setColumns(_ mask: inout ColumnMask, from start: Int, through end: Int) {
  var word = start / 64
  let lastWord = end / 64
  while word <= lastWord {
    let low = max(start - word * 64, 0)
    let high = min(end - word * 64, 63)
    let count = high - low + 1
    // a 64-wide shift is undefined, so the full-word case is spelled out
    mask[word] |= count == 64 ? ~0 : ((UInt64(1) << count) - 1) << low
    word += 1
  }
}

/// Blends a wide tile's op list through a per-thread planar staging buffer.
///
/// The buffer is four `Float` planes (alpha, red, green, blue), indexed by pixel column, each
/// entry a `SIMD4<Float>` holding that column's four rows — the same column-major shape the
/// coverage buffers already use, so one op column is one SIMD load and four fused multiply-adds
/// covering four pixels.
///
/// Colors are staged premultiplied so source-over needs no divide per op; the unpremultiply
/// happens once, at flush. The global pixel buffer is read once and written once, instead of
/// being re-walked (with its `width`-strided rows) by every op.
func drawWideTile(
  x: Int,
  y: Int,
  ops: Span<WideTileDrawOp>,
  pixels: UnsafeMutablePointer<Pixel>,  // row major tho
  width: Int,
  height: Int,
  scratch: UnsafeMutablePointer<SIMD4<Float>>
) {
  let tileStartX = x * WIDE_TILE_WIDTH
  let tileStartY = y * TILE_SIZE
  let rowCount = min(TILE_SIZE, height - tileStartY)
  let tileWidth = min(WIDE_TILE_WIDTH, width - tileStartX)
  guard rowCount > 0, tileWidth > 0, ops.count > 0 else { return }

  // exactly the columns some op writes, not the span between the leftmost and rightmost: two
  // ops at opposite ends of a tile must not drag every column between them through the
  // staging buffer. The extent total against the bit count gives the tile's average overdraw
  var touched = ColumnMask(repeating: 0)
  var extentTotal = 0
  for i in ops.indices {
    let (opX, opWidth) =
      switch ops[unchecked: i] {
      case .solid(let opX, let w, _): (Int(opX), Int(w))
      case .aa(let opX, let w, _, _, _): (Int(opX), Int(w))
      }
    let start = max(opX * TILE_SIZE, 0)
    let end = min((opX + opWidth) * TILE_SIZE, tileWidth) - 1
    if start <= end {
      extentTotal += end - start + 1
      setColumns(&touched, from: start, through: end)
    }
  }

  var touchedCount = 0
  for word in 0..<4 {
    touchedCount += touched[word].nonzeroBitCount
  }
  guard touchedCount > 0 else { return }

  guard extentTotal >= stagingMinimumOverdraw * touchedCount else {
    drawWideTileDirect(x: x, y: y, ops: ops, pixels: pixels, width: width, height: height)
    return
  }

  /// walks the touched columns in ascending order
  @inline(__always)
  func forEachTouchedColumn(_ body: (Int) -> Void) {
    for word in 0..<4 {
      var bits = touched[word]
      while bits != 0 {
        body(word * 64 + bits.trailingZeroBitCount)
        bits &= bits &- 1
      }
    }
  }

  let alpha = scratch
  let red = scratch + WIDE_TILE_WIDTH
  let green = scratch + WIDE_TILE_WIDTH * 2
  let blue = scratch + WIDE_TILE_WIDTH * 3

  let zero = SIMD4<Float>()
  let one = SIMD4<Float>(repeating: 1)

  // The tile's ops are every draw covering it, in painter order, so the only thing beneath
  // them is the destination. Since source-over is associative, they can be accumulated into a
  // transparent layer here and that layer composited onto the destination once at flush —
  // which is why this starts at zero rather than reading the destination back in. That saves
  // a whole pass over the tile, and an opaque result skips the destination entirely.
  forEachTouchedColumn { column in
    let a = zero
    let r = zero
    let g = zero
    let b = zero
    alpha[column] = a
    red[column] = r
    green[column] = g
    blue[column] = b
  }

  for i in ops.indices {
    switch ops[unchecked: i] {
    case .solid(let opX, let w, let color):
      let start = max(Int(opX) * TILE_SIZE, 0)
      let end = min((Int(opX) + Int(w)) * TILE_SIZE, tileWidth) - 1
      guard start <= end else { continue }

      // the planes hold the same premultiplied 0...1 values the canvas does
      let source = color.pixel
      let sourceAlpha = source.w
      let sourceRed = SIMD4<Float>(repeating: source.x)
      let sourceGreen = SIMD4<Float>(repeating: source.y)
      let sourceBlue = SIMD4<Float>(repeating: source.z)

      if sourceAlpha >= 1 {
        // fully opaque: the destination does not participate at all
        for column in start...end {
          alpha[column] = one
          red[column] = sourceRed
          green[column] = sourceGreen
          blue[column] = sourceBlue
        }
      } else {
        let inverse = SIMD4<Float>(repeating: 1 - sourceAlpha)
        let sourceA = SIMD4<Float>(repeating: sourceAlpha)
        for column in start...end {
          red[column] = sourceRed + red[column] * inverse
          green[column] = sourceGreen + green[column] * inverse
          blue[column] = sourceBlue + blue[column] * inverse
          alpha[column] = sourceA + alpha[column] * inverse
        }
      }

    case .aa(let opX, let w, let color, let coverage, let offset):
      let start = max(Int(opX) * TILE_SIZE, 0)
      let end = min((Int(opX) + Int(w)) * TILE_SIZE, tileWidth) - 1
      guard start <= end, let coverageBase = coverage.baseAddress else { continue }

      let source = color.pixel
      let sourceAlpha = source.w
      let sourceRed = source.x
      let sourceGreen = source.y
      let sourceBlue = source.z

      for column in start...end {
        // the coverage buffer is column major: this column's four rows are contiguous
        let columnStart = (Int(offset) * TILE_SIZE + column - start) * TILE_SIZE
        let raw = UnsafeRawPointer(coverageBase + columnStart)
          .loadUnaligned(as: SIMD4<Float>.self)

        // TODO: fill rule, this is nonzero
        let opacity =
          raw
          .replacing(with: -raw, where: raw .< zero)
          .replacing(with: one, where: raw .> one)

        let sourceA = opacity * sourceAlpha
        let inverse = one - sourceA
        red[column] = sourceRed * opacity + red[column] * inverse
        green[column] = sourceGreen * opacity + green[column] * inverse
        blue[column] = sourceBlue * opacity + blue[column] * inverse
        alpha[column] = sourceA + alpha[column] * inverse
      }
    }
  }

  // flush: composite the accumulated layer onto the destination and scatter it back out.
  //
  // The canvas stores the same premultiplied floats the planes do, so there is no conversion
  // here at all — just the transpose from four column-major planes back to interleaved pixels.
  forEachTouchedColumn { column in
    let a = alpha[column]
    var layerRed = red[column]
    var layerGreen = green[column]
    var layerBlue = blue[column]
    var outAlpha = a

    // where the layer came out opaque it hides the destination completely, so the read is
    // skipped — the common case for a tile under a solid fill
    if !all(a .>= one) {
      let inverse = one - a
      for row in 0..<rowCount {
        // layer over destination, both premultiplied
        let destination = pixels[(tileStartY + row) * width + tileStartX + column]
        layerRed[row] += destination.x * inverse[row]
        layerGreen[row] += destination.y * inverse[row]
        layerBlue[row] += destination.z * inverse[row]
        outAlpha[row] += destination.w * inverse[row]
      }
    }

    for row in 0..<rowCount {
      let index = (tileStartY + row) * width + tileStartX + column
      pixels[index] = Pixel(layerRed[row], layerGreen[row], layerBlue[row], outAlpha[row])
    }
  }
}

/// Blends straight into the pixel buffer, no staging. Used for tiles with too few ops to
/// amortize the load and flush.
private func drawWideTileDirect(
  x: Int,
  y: Int,
  ops: Span<WideTileDrawOp>,
  pixels: UnsafeMutablePointer<Pixel>,  // row major tho
  width: Int,
  height: Int
) {
  let tileStartX = x * WIDE_TILE_WIDTH
  let tileStartY = y * TILE_SIZE
  let rowCount = min(TILE_SIZE, height - tileStartY)
  guard rowCount > 0, ops.count > 0 else { return }
  // print("Drawing wide tile at (\(tileStartX) \(tileStartY))")

  for i in ops.indices {
    switch ops[unchecked: i] {
    case .solid(let x, let w, let color):
      let startX = tileStartX + Int(x) * TILE_SIZE
      let endX = min(startX + Int(w) * TILE_SIZE, width)
      guard startX < endX else { continue }

      let source = color.pixel
      if color.alpha == 1.0 {
        for row in 0..<rowCount {
          let rowStart = (tileStartY + row) * width
          UnsafeMutableBufferPointer(start: pixels + rowStart + startX, count: endX - startX)
            .update(repeating: source)
        }
      } else {
        for row in 0..<rowCount {
          let rowStart = (tileStartY + row) * width
          for px in startX..<endX {
            blend(source, &pixels[rowStart + px], 1.0)
          }
        }
      }

    case .aa(let x, let w, let color, let coverage, let offset):
      let startX = tileStartX + Int(x) * TILE_SIZE  // actual pixel
      let endX = min(startX + Int(w) * TILE_SIZE, width)
      // print(" - Executing aa at x=\(startX)...\(endX)")
      guard startX < endX else { continue }

      let source = color.pixel
      for column in 0..<(endX - startX) {
        // column major, 4 rows per pixel column
        let columnStart = (Int(offset) * TILE_SIZE + column) * TILE_SIZE
        // print(coverage, columnStart)
        for row in 0..<rowCount {
          // TODO: fill rule, this is nonzero
          let opacity = min(abs(coverage[columnStart + row]), 1.0)
          blend(source, &pixels[(tileStartY + row) * width + startX + column], opacity)
        }
      }
    }
  }
}
