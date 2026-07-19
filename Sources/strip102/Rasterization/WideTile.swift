import Dispatch


enum WideTileDrawOp: @unchecked Sendable {
  case solid(x: UInt16, w: UInt16, Color)
  case aa(x: UInt16, w: UInt16, Color, coverageBuffer: UnsafeBufferPointer<Float>, offset: UInt16)
}

/// nested array, flatten, with offset table
struct WideTileCommands {
  var commands: [WideTileDrawOp]
  var offsets: [Int]

  var tileCount: Int { offsets.count - 1 }
}

func generateWideTileCommands(
  width: Int,
  height: Int,
  cachedStrips: Span<SparseStripRenderer.CachedStrips?>,
  ops: Span<DrawOp>,
  tileSize: Int
) -> WideTileCommands {
  let wideTileXCount = Int((Float(width) / Float(WIDE_TILE_WIDTH)).rounded(.up))
  let wideTileYCount = Int((Float(height) / Float(TILE_SIZE)).rounded(.up))
  let tileCount = wideTileXCount * wideTileYCount

  let threadCount = max(1, min(getRealCoreCount(), wideTileYCount))
  let rowChunk = (wideTileYCount + threadCount - 1) / threadCount

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
        ops: ops, strips: cachedStrips, tileSize: tileSize, wideTileXCount: wideTileXCount,
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
          ops: ops, strips: cachedStrips, tileSize: tileSize, wideTileXCount: wideTileXCount,
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
  strips: Span<SparseStripRenderer.CachedStrips?>,
  tileSize: Int,
  wideTileXCount: Int,
  tileCount: Int,
  yStart: Int,
  yEnd: Int,
  emit: (Int, WideTileDrawOp) -> Void
) {
  for i in ops.indices {
    // in tile unit (x, y), end of the last strip emitted on this row
    var lastStripEnd: (x: Int, y: Int)?
    for strip in strips[i]!.strips {
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

/// Blends a wide tile's op list straight into the pixel buffer.
///
/// The canvas stores premultiplied float, so a blend is one multiply and one fused multiply-add
/// with no conversion, and an opaque solid span is a plain memset. Staging the tile through a
/// planar scratch buffer was tried and measured slower on every threshold: once compositing
/// costs this little, there is nothing left for the extra passes to amortize.
func drawWideTile(
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
        let solidPixel = pack(source)
        for row in 0..<rowCount {
          let rowStart = (tileStartY + row) * width
          UnsafeMutableBufferPointer(start: pixels + rowStart + startX, count: endX - startX)
            .update(repeating: solidPixel)
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
