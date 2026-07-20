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

  /// per-worker scratch, allocated once and reused every frame; kept out of the arenas so
  /// it is never zeroed on handout — generateStrips zeroes the slice it needs per strip
  let scratchBuffers: [UnsafeMutableBufferPointer<Float>]

  init() {
    coverageArenas = (0..<coreCount).map { _ in
      CoverageArena(tileCount: 1024 * 128)
    }
    scratchBuffers = (0..<coreCount).map { _ in
      .allocate(capacity: TILE_SIZE * TILE_SIZE * 1024)
    }
  }

  deinit {
    for buffer in scratchBuffers {
      buffer.deallocate()
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

  func push(
    ops: Span<DrawOp>,
    // the renderer should also own pixels storage tho
    pixels: inout MutableSpan<Pixel>,
    width: Int,
    height: Int
  ) {

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

      // when tf will path.dirty need this check again
      let cached = stripsCache[
        StripCacheKey(pathId: path.id, affine: ops[unchecked: i].transform)]
      if cached == nil { misses.append(i) }
      entries.append(cached)
    }

    // parallel: rasterize the misses, each worker allocating from its own arena
    // index = miss index
    let built = misses.parallelMap(threads: coreCount) { [self] i, thread in
      let arena = coverageArenas[thread]
      let scratchBuffer = scratchBuffers[thread]

      let lines = ops[unchecked: i].path.breakIntoLines(
        transform: ops[unchecked: i].transform, tolerance: 0.25)
      let tileSet = generateTiles(lines: lines, width: width, height: height)
      let strips = generateStrips(
        tiles: tileSet.tiles.span,
        rowBackgrounds: tileSet.rowBackgrounds,
        arena: arena,
        scratchBuffer: scratchBuffer
      )

      return CachedStrips(strips: strips, arena: arena)
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
    // swift ends an object's lifetime at its last use, not end of the scope
    defer { withExtendedLifetime(entries) {} }
    let strips = entries.map { $0!.strips }

    // generate per WideTile (screen space) draw commands ??
    let wideTileXCount = Int((Float(width) / 256).rounded(.up))

    // wide tile is in row major for conveniece
    let wideTileCommands = generateWideTileCommands(
      width: width, height: height, strips: strips, ops: ops, tileSize: TILE_SIZE)

    let tileCount = wideTileCommands.tileCount
    let allCommands = wideTileCommands.commands.span
    let offsets = wideTileCommands.offsets
    pixels.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let buffer = buffer

      // Natural order on purpose. Tile cost varies a lot (dense middle, empty margins), but
      // parallelFor hands out one task at a time off a shared counter, so it already balances
      // dynamically — permuting the order only gives up pixel-buffer locality. Measured: a
      // coprime-stride permutation was slower at every canvas size.
      parallelFor(count: tileCount, threads: coreCount) { i, _ in
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

struct Tile {
  let x: UInt16
  let y: UInt16
  let line: Line
  let hasWinding: Bool

  func sameTile(as other: Tile) -> Bool {
    other.x == x && other.y == y
  }
}

struct TileSet {
  var tiles: [Tile]
  /// winding each visible tile row starts with, accumulated from the row-top crossings
  /// that happen left of the viewport, keyed by y (tile unit)
  var rowBackgrounds: [Int]
}

/// floor division, so negative coordinates bin into negative tiles instead of
/// truncating into tile 0
@inline(__always)
private func tileIndex(_ v: Float) -> Int {
  Int((v / Float(TILE_SIZE)).rounded(.down))
}

func generateTiles(lines: consuming [Line], width: Int, height: Int) -> TileSet {
  var tiles: [Tile] = []
  let xTileCount = (width + TILE_SIZE - 1) / TILE_SIZE
  let yTileCount = (height + TILE_SIZE - 1) / TILE_SIZE
  var rowBackgrounds = [Int](repeating: 0, count: yTileCount)

  for line in lines {
    // print(line)
    let yStart = tileIndex(line.start.y)
    let yEnd = tileIndex(line.end.y)

    // first bin line by y
    // for each segment: bin by x
    let dy = line.end.y - line.start.y
    let dir = if dy > 0 { 1 } else { -1 }
    // print("new dy=\(dy) yStart=\(yStart) yEnd=\(yEnd)")
    for y in stride(from: yStart, through: yEnd, by: dir) {
      // row outside of viewport: skip
      guard y >= 0 && y < yTileCount else { continue }

      let yBinnedLine = line.crop(y: Float(TILE_SIZE * y)...(Float(TILE_SIZE * (y + 1))))

      // print(line, yBinnedLine)
      // print(" - \(yBinnedLine)")

      let xStart = tileIndex(yBinnedLine.start.x)
      let xEnd = tileIndex(yBinnedLine.end.x)
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      let dir = if dx > 0 { 1 } else { -1 }
      for x in stride(from: xStart, through: xEnd, by: dir) {
        let xBinnedLine = yBinnedLine.crop(x: Float(TILE_SIZE * x)...(Float(TILE_SIZE * (x + 1))))
        if xBinnedLine.isPoint { continue }

        let hasWinding =
          abs(min(xBinnedLine.start.y, xBinnedLine.end.y) - Float(y * TILE_SIZE)) < 0.00001

        if x < 0 {
          // offscreen left still decides the winding the visible part of the row starts with
          if hasWinding {
            rowBackgrounds[y] += xBinnedLine.direction > 0 ? 1 : -1
          }
          continue
        }
        // offscreen right: skip
        if x >= xTileCount { continue }

        let tile = Tile(
          x: UInt16(x),
          y: UInt16(y),
          line: xBinnedLine,
          hasWinding: hasWinding
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

  return TileSet(tiles: tiles, rowBackgrounds: rowBackgrounds)
}
struct Strip {
  var x: UInt16
  var y: UInt16
  var coverageBuffer: UnsafeBufferPointer<Float>
  var shouldFillLeft: Bool
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
  rowBackgrounds: [Int],
  arena: CoverageArena,
  scratchBuffer: UnsafeMutableBufferPointer<Float>
) -> [Strip] {
  var strips: [Strip] = []
  var winding = 0
  // sentinel, so the first tile's row picks up its background even when it is row 0
  var lastY = -1

  var i = 0
  while i < tiles.count {
    if lastY != tiles[unchecked: i].y {
      winding = rowBackgrounds[Int(tiles[unchecked: i].y)]
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
