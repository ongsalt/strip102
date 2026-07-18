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
  let wideTileXCount = Int((Float(width) / 256).rounded(.up))
  let wideTileYCount = Int((Float(height) / 4).rounded(.up))
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
      let wideTileXStart = Int(strip.x * 4 / 256)
      // wideTileX where this end; same scale as wideTileXStart (wideTile-column units), computed
      // from the strip's last covered tile index rather than mixing tile-index and column scales
      let wideTileXEnd = (Int(strip.x) + coverageWidth - 1) * 4 / 256

      // 1 widetile is 64 4x4 tile, tile unit, relative to wideTile start
      let x: UInt16 = UInt16(Int(strip.x) - wideTileXStart * 64)

      if strip.shouldFillLeft, let lastStripEnd, wideTileY == lastStripEnd.y {
        // fill the gap between the end of the previous strip and the start of
        // this one with the winding number carried over (background), splitting
        // at wide tile boundaries since a draw command only lives in one wide tile
        var fillX = lastStripEnd.x
        let fillEnd = Int(strip.x)
        while fillX < fillEnd {
          let fillWideTileX = fillX / 64
          let localX = fillX % 64
          let filledWidth = min(fillEnd - fillX, 64 - localX)
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
        let consumed = min(areaLeft, 64 - Int(currentX))

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
