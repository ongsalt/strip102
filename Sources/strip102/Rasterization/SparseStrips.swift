import Dispatch

import Foundation

import Synchronization

let TILE_SIZE: Int = 4
let WIDE_TILE_WIDTH: Int = 256
class SparseStripRenderer: @unchecked Sendable {
  let coreCount = getRealCoreCount()

  /// one arena per worker thread: allocation is single-threaded by construction, and all
  /// frees happen on the render thread while workers are idle, so no locking anywhere
  let coverageArenas: [CoverageArena]

  init() {
    coverageArenas = (0..<coreCount).map { _ in
      CoverageArena(tileCount: 1024 * 128)
    }
  }

  struct StripCacheKey: Hashable {
    let pathId: Path.ID
    let affine: Affine
  }

  /// strips generated straight into one worker's arena; the regions go back to it on eviction.
  /// Only ever released on the render thread (cache purge or end of frame), never by a worker
  final class CachedStrips: @unchecked Sendable {
    let strips: [Strip]
    private let arena: CoverageArena

    init(strips: [Strip], arena: CoverageArena) {
      self.strips = strips
      self.arena = arena
    }

    deinit {
      for strip in strips {
        arena.free(strip.coverageBuffer)
      }
    }
  }

  // TODO: entries for dead paths leak until their address is reused; sweep periodically
  // render-thread only; workers never touch it
  var stripsCache: [StripCacheKey: CachedStrips] = [:]

  func drawSparseSprips(
    ops: borrowing [DrawOp],
    pixels: inout MutableSpan<Pixel>,
    width: Int,
    height: Int
  ) {
    // bin screen into 256x4 `wide` tiles
    let ops = ops.span

    // serial prepass: purge dirty paths and resolve cache hits. All cache mutation and all
    // arena frees happen here on the render thread — the parallel phase only allocates
    var entries: [CachedStrips?] = []
    entries.reserveCapacity(ops.count)
    var misses: [Int] = []
    for i in 0..<ops.count {
      let path = ops[unchecked: i].path
      if path.dirty {
        // old shape under this id is gone; this also purges entries a freed path
        // left behind when its storage address gets reused
        let id = path.id
        stripsCache = stripsCache.filter { $0.key.pathId != id }
        path.dirty = false
      }

      let cached = stripsCache[
        StripCacheKey(pathId: path.id, affine: ops[unchecked: i].transform)]
      if cached == nil { misses.append(i) }
      entries.append(cached)
    }

    // parallel: rasterize the misses, each worker allocating from its own arena
    // index = miss index
    // Array(unsafeUninitializedCapacity: Int, initializingWith: (_ buffer: inout UnsafeMutableBufferPointer<Element>, _ initializedCount: inout Int) throws(Error) -> Void)
    let built: [CachedStrips] = Array(unsafeUninitializedCapacity: misses.count) {
      [coverageArenas, misses] out, wrote in
      let next = Atomic(0)
      wrote = misses.count
      nonisolated(unsafe) let buffer = out
      DispatchQueue.concurrentPerform(iterations: coreCount) { threadIndex in
        // per thread
        let scratchBuffer: UnsafeMutableBufferPointer<Float> = .allocate(
          capacity: TILE_SIZE * TILE_SIZE * 1024)
        defer { scratchBuffer.deallocate() }
        let arena = coverageArenas[threadIndex]

        // pull tasks
        while true {
          let task = next.add(1, ordering: .relaxed).oldValue
          guard task < misses.count else { break }
          let i = misses[task]

          let lines = ops[unchecked: i].path.breakIntoLines(
            transform: ops[unchecked: i].transform, tolerance: 0.25)
          let tiles = generateTiles(lines: lines)
          let strips = generateStrips(
            tiles: tiles.span,
            arena: arena,
            scratchBuffer: scratchBuffer
          )

          buffer.initializeElement(at: task, to: CachedStrips(strips: strips, arena: arena))
        }
      }
    }

    // serial publish. A key hit twice in one frame just replaces; the orphaned entry stays
    // alive through `entries` until the frame ends, then returns its regions
    for (task, i) in misses.enumerated() {
      let path = ops[unchecked: i].path
      stripsCache[StripCacheKey(pathId: path.id, affine: ops[unchecked: i].transform)] =
        built[task]
      entries[i] = built[task]
    }

    // a purge next frame must not free regions this frame still points into
    defer { withExtendedLifetime(entries) {} }
    let strips = entries.map { $0!.strips }

    // generate per WideTile (screen space) draw commands ??
    let wideTileXCount = Int((Float(width) / 256).rounded(.up))

    // wide tile is in row major for conveniece
    let wideTileCommands = generateWideTileCommands(
      width: width, height: height, strips: strips, ops: ops, tileSize: TILE_SIZE)

    let next = Atomic(0)
    let allCommands = wideTileCommands.commands.span
    let offsets = wideTileCommands.offsets
    pixels.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let buffer = buffer

      // Might generate a colmun major scratch buffer (rx4,gx4,bx4,ax4) per thread

      DispatchQueue.concurrentPerform(iterations: coreCount) { _ in
        // pull tasks
        // each thread should keep a 256x4 column major blend scratch?
        while true {
          let i = next.add(1, ordering: .relaxed).oldValue
          guard i < wideTileCommands.tileCount else { break }

          let x = i % wideTileXCount
          let y = i / wideTileXCount

          drawWideTile(
            x: x, y: y, ops: allCommands.extracting(offsets[i]..<offsets[i + 1]),
            pixels: buffer.baseAddress!,
            width: width, height: height
          )
        }
      }
    }
  }
}
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

      if color.alpha == 1.0 {
        let pixel: Pixel = [
          UInt8(color.red * 255), UInt8(color.green * 255), UInt8(color.blue * 255), 255,
        ]
        for row in 0..<rowCount {
          let rowStart = (tileStartY + row) * width
          UnsafeMutableBufferPointer(start: pixels + rowStart + startX, count: endX - startX)
            .update(repeating: pixel)
        }
      } else {
        let source = Color8(color)
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

      let source = Color8(color)
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
struct Tile {
  let x: UInt16
  let y: UInt16
  let line: Line
  let hasWinding: Bool

  func sameTile(as other: Tile) -> Bool {
    other.x == x && other.y == y
  }
}
func generateTiles(lines: consuming [Line]) -> [Tile] {
  var tiles: [Tile] = []

  for line in lines {
    // print(line)
    let yStart = Int(line.start.y) / TILE_SIZE
    let yEnd = Int(line.end.y) / TILE_SIZE

    // first bin line by y
    // for each segment: bin by x
    let dy = line.end.y - line.start.y
    let dir = if dy > 0 { 1 } else { -1 }
    // print("new dy=\(dy) yStart=\(yStart) yEnd=\(yEnd)")
    for y in stride(from: yStart, through: yEnd, by: dir) {
      // let yBinnedLine = Line(line.sample(t1), line.sample(t2))
      let yBinnedLine = line.crop(y: Float(TILE_SIZE * y)...(Float(TILE_SIZE * (y + 1))))

      // ignore horizontal line
      // if yBinnedLine.start.y == yBinnedLine.end.y { continue }

      // print(line, yBinnedLine)
      // print(" - \(yBinnedLine)")

      let xStart = Int(yBinnedLine.start.x) / TILE_SIZE
      let xEnd = Int(yBinnedLine.end.x) / TILE_SIZE
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      let dir = if dx > 0 { 1 } else { -1 }
      for x in stride(from: xStart, through: xEnd, by: dir) {
        let xBinnedLine = yBinnedLine.crop(x: Float(TILE_SIZE * x)...(Float(TILE_SIZE * (x + 1))))
        if xBinnedLine.isPoint { continue }

        let tile = Tile(
          x: UInt16(x),
          y: UInt16(y),
          line: xBinnedLine,
          hasWinding: abs(min(xBinnedLine.start.y, xBinnedLine.end.y) - Float(y * TILE_SIZE))
            < 0.00001
        )
        tiles.append(tile)
        // print(" > \(tile)")
      }
    }
  }

  tiles.sort { a, b in
    if a.y == b.y {
      return a.x < b.x
    }
    return a.y < b.y
  }

  return tiles
}
struct Strip {
  var x: UInt16
  var y: UInt16

  // tileSize offset into coverage buffer
  var coverageBuffer: UnsafeBufferPointer<Float>
  var shouldFillLeft: Bool
  // var _coverageIndex: UInt32

  // var coverageIndex: UInt32 {
  //   _coverageIndex & ~(0x1 << 31)
  // }

  // var shouldFillLeft: Bool {
  //   get {
  //     (_coverageIndex >> 31) == 0x1
  //   }
  //   set {
  //     _coverageIndex = ((newValue ? 0x1 : 0x0) << 31) | coverageIndex
  //   }
  // }
}
/// Long-lived coverage storage behaving like a real allocator: regions are carved from
/// slabs via a first-fit free list and handed back with `free`. When nothing fits, a new
/// (bigger) slab is chained instead of reallocating, so handed-out regions never move.
/// Deliberately not thread-safe — each worker owns one arena for allocation, and frees
/// only happen on the render thread while the workers are idle.
final class CoverageArena: @unchecked Sendable {
  private var slabs: [UnsafeMutableBufferPointer<Float>] = []
  /// tile capacity of the next slab; doubles on every grow to amortize
  private var nextSlabTileCount: Int
  /// disjoint free regions, sorted by address, adjacent ones coalesced
  private var freeRegions: [UnsafeMutableBufferPointer<Float>] = []

  init(tileCount: Int = 1024 * 32) {
    nextSlabTileCount = tileCount
    grow(minimumCount: 0)
  }

  deinit {
    for slab in slabs {
      slab.deallocate()
    }
  }

  private func grow(minimumCount: Int) {
    while nextSlabTileCount * TILE_SIZE * TILE_SIZE < minimumCount {
      nextSlabTileCount *= 2
    }

    let slab = UnsafeMutableBufferPointer<Float>.allocate(
      capacity: nextSlabTileCount * TILE_SIZE * TILE_SIZE)
    nextSlabTileCount *= 2
    slabs.append(slab)
    free(UnsafeBufferPointer(slab))
  }

  // each coverage is column major for simd4
  func allocate(_ width: Int) -> UnsafeMutableBufferPointer<Float> {
    let count = width * TILE_SIZE * TILE_SIZE

    // first fit
    for (i, region) in freeRegions.enumerated() where region.count >= count {
      if region.count == count {
        freeRegions.remove(at: i)
      } else {
        freeRegions[i] = UnsafeMutableBufferPointer(
          start: region.baseAddress! + count, count: region.count - count)
      }

      let newBuffer = UnsafeMutableBufferPointer(start: region.baseAddress!, count: count)
      // zero on handout — computeCoverage relies on this since it does `buffer[x] += ...`
      newBuffer.update(repeating: 0.0)
      return newBuffer
    }

    // nothing fits: chain another slab and retry
    grow(minimumCount: count)
    return allocate(width)
  }

  func free(_ region: UnsafeBufferPointer<Float>) {
    guard region.count > 0, let base = region.baseAddress else { return }
    var start = UnsafeMutablePointer(mutating: base)
    var count = region.count

    let i = freeRegions.firstIndex { $0.baseAddress! > start } ?? freeRegions.count
    var insertAt = i
    // coalesce with the predecessor and successor when adjacent
    if i > 0, freeRegions[i - 1].baseAddress! + freeRegions[i - 1].count == start {
      start = freeRegions[i - 1].baseAddress!
      count += freeRegions[i - 1].count
      freeRegions.remove(at: i - 1)
      insertAt = i - 1
    }
    if insertAt < freeRegions.count, start + count == freeRegions[insertAt].baseAddress! {
      count += freeRegions[insertAt].count
      freeRegions.remove(at: insertAt)
    }
    freeRegions.insert(UnsafeMutableBufferPointer(start: start, count: count), at: insertAt)
  }
}
struct Coverage: @unchecked Sendable {
  let index: Int
  let buffer: UnsafeMutableBufferPointer<Float>
}
func generateStrips(
  tiles: borrowing Span<Tile>,
  arena: CoverageArena,
  scratchBuffer: UnsafeMutableBufferPointer<Float>
) -> [Strip] {
  var strips: [Strip] = []
  var winding = 0
  var lastY = 0

  var i = 0
  while i < tiles.count {
    if lastY != tiles[unchecked: i].y {
      winding = 0
      // print("reset winding \(winding) \(tiles[i])")
    }
    lastY = Int(tiles[unchecked: i].y)

    let start = i
    let w = winding
    let x = tiles[unchecked: i].x
    let y = tiles[unchecked: i].y

    // print("Start tile at \(start) \(tiles[start])")
    while i < tiles.count - 1 {
      if tiles[unchecked: i].hasWinding {
        winding += tiles[unchecked: i].line.direction > 0 ? 1 : -1
        // print("winding=\(winding)")
      }

      // TODO: bounds check here
      let next = tiles[unchecked: i + 1]
      if next.y == tiles[unchecked: i].y && next.x - tiles[unchecked: i].x <= 1 {
        i += 1
      } else {
        break
      }
    }

    // zeroing only needed
    let stripWidth = Int(tiles[unchecked: i].x - tiles[unchecked: start].x + 1)
    // if stripWidth == 1 {
    //   print("> break tile at \(i)  \(tiles[i])")
    // }

    scratchBuffer.extracting(0..<stripWidth * TILE_SIZE * TILE_SIZE)
      .update(repeating: 0.0)
    // scratchBuffer.initialize(repeating: 0.0)

    // allocate buffer, known size
    let coverage = arena.allocate(stripWidth)
    // print(
    //   "Compute coverage: background=\(w) stripWidth=\(stripWidth), tiles[\(start)...\(i)], x: \(tiles[start].x)...\(tiles[i].x) y: \(tiles[start].y)...\(tiles[i].y)"
    // )

    let range = tiles.extracting(start...i)
    computeCoverage(
      tiles: range,
      tileSize: TILE_SIZE,
      buffer: coverage,
      scratchBuffer: scratchBuffer,
      background: w,
      stripWidth: stripWidth
    )

    // coverageBuffer.print(index: coverage.index)

    // TODO: fill rule
    strips.append(
      Strip(x: x, y: y, coverageBuffer: UnsafeBufferPointer(coverage), shouldFillLeft: w != 0))
    i += 1
  }

  return strips
}
func computeCoverage(
  tiles: borrowing Span<Tile>,
  // inclusive
  tileSize: Int,
  buffer: UnsafeMutableBufferPointer<Float>,  // fill
  scratchBuffer: UnsafeMutableBufferPointer<Float>,  // coverage
  background: Int,
  stripWidth: Int
) {
  // in pixel
  let stripStartY = Float(tiles[unchecked: 0].y) * Float(TILE_SIZE)

  for i in tiles.indices {
    let line = tiles[unchecked: i].line

    for ly in 0..<TILE_SIZE {
      let yBinnedLine = line.crop(y: stripStartY + Float(ly)...stripStartY + Float(ly + 1))
      // print(yBinnedLine, ly + Int(stripStartY) * TILE_SIZE)

      for lx in 0..<TILE_SIZE {
        let tileStartX = Float(tiles[unchecked: i].x) * Float(TILE_SIZE)
        let line = yBinnedLine.crop(x: tileStartX + Float(lx)...tileStartX + Float(lx + 1))
        // if its out of this pixel, continue
        if line.xBounds.0 != lx + Int(tiles[unchecked: i].x) * TILE_SIZE { continue }
        if line.isPoint { continue }
        // print("> [\(Int(tileStartX) + lx), \(Int(stripStartY) + ly)] \(line)")

        // crop line into; math in f32, f16 only at the store
        let dy = line.end.y - line.start.y
        let xMid = (line.start.x + line.end.x) / 2 - (tileStartX + Float(lx))

        let offset =
          Int(tiles[unchecked: i].x - tiles[unchecked: 0].x) * tileSize * tileSize + lx * tileSize
          + ly
        // coverage
        // print(" - \(offset), \(buffer.count)")
        scratchBuffer[offset] += dy
        // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
        // fill
        buffer[offset] += dy * (1 - xMid)

        // print(" > coverage:\(scratchBuffer[offset]) fill:\(buffer[offset])")

      }
    }
  }

  let fill: UnsafeMutablePointer<SIMD4<Float>> = UnsafeMutablePointer<SIMD4<Float>>(
    OpaquePointer(buffer.baseAddress))!
  let coverage = UnsafeMutablePointer<SIMD4<Float>>(OpaquePointer(scratchBuffer.baseAddress))!
  var acc: SIMD4<Float> = SIMD4(repeating: Float(background))

  for x in 0..<stripWidth * TILE_SIZE {
    let f = fill[Int(x)] + acc
    fill[Int(x)] = f
    acc += coverage[Int(x)]

    // if buffer.count / (tileSize * tileSize) == 5 {
    //   fill[Int(x)] = .one / 4
    // }
  }

  // fill[0] = .one / 12 * Float(buffer.count / (tileSize * tileSize))
  // if buffer.count / (tileSize * tileSize) == 5 {
  //   fill[0] = .one / 3
  //   // for
  // }
}
enum WideTileDrawOp: @unchecked Sendable {
  case solid(x: UInt16, w: UInt16, Color)
  case aa(x: UInt16, w: UInt16, Color, coverageBuffer: UnsafeBufferPointer<Float>, offset: UInt16)
}
extension Line {
  var isPoint: Bool {
    start == end
  }
  func crop(y range: ClosedRange<Float>) -> Line {
    let dy = self.end.y - self.start.y
    if dy == 0 {
      return self
    }

    let t1 = ((range.lowerBound - self.start.y) / dy).clamped(from: 0.0, to: 1.0)
    let t2 = ((range.upperBound - self.start.y) / dy).clamped(from: 0.0, to: 1.0)

    return if start.y > end.y {
      Line(sample(t2), sample(t1))
    } else {
      Line(sample(t1), sample(t2))
    }
  }

  func crop(x range: ClosedRange<Float>) -> Line {
    let dx = self.end.x - self.start.x
    if dx == 0 {
      return self
    }

    let t1 = ((range.lowerBound - self.start.x) / dx).clamped(from: 0.0, to: 1.0)
    let t2 = ((range.upperBound - self.start.x) / dx).clamped(from: 0.0, to: 1.0)

    return if start.x > end.x {
      Line(sample(t2), sample(t1))
    } else {
      Line(sample(t1), sample(t2))
    }
  }

}
