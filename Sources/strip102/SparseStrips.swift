import Dispatch
import Foundation
import Synchronization

func drawSparseSprips(
  ops: borrowing [DrawOp],
  pixels: inout MutableSpan<Pixel>,
  width: Int,
  height: Int
) {
  // bin screen into 256x4 `wide` tiles

  let ops = ops.span
  let tileSize = 4

  let coreCount = getRealCoreCount()
  let coverageBuffer = CoverageBuffer(tileSize: tileSize, tileCount: 1024 * 128)

  // index = path index
  let strips: [[Strip]] = Array(capacity: ops.count) { out in
    let next = Atomic(0)
    out.withUnsafeMutableBufferPointer { buffer, wrote in
      wrote = ops.count
      nonisolated(unsafe) let buffer = buffer

      DispatchQueue.concurrentPerform(iterations: coreCount) { index in
        // per thread
        let scratchBuffer: UnsafeMutableBufferPointer<Float16> = .allocate(
          capacity: tileSize * tileSize * 1024)

        // pull tasks
        while true {
          let i = next.add(1, ordering: .relaxed).oldValue
          guard i < ops.count else { break }

          let lines = ops[i].path.breakIntoLines(transform: ops[i].transform, tolerance: 0.25)
          let tiles = generateTiles(lines: lines)

          // also generate coverage
          let strips = generateStrips(
            tiles: tiles.span,
            coverageBuffer: coverageBuffer,
            scratchBuffer: scratchBuffer
          )

          buffer.initializeElement(at: index, to: strips)
        }
      }
    }
  }

  print(strips)

  // generate per WideTile (screen space) draw commands ??
  let wideTileXCount = Int((Float(width) / 256).rounded(.up))
  let wideTileYCount = Int((Float(height) / 4).rounded(.up))

  // wide tile is in row major for conveniece
  var wideTileCommands: [[WideTileDrawOp]] = Array(
    repeating: [], count: wideTileXCount * wideTileYCount)

  for i in ops.indices {
    // generate command in painter order
    // let wideTileIndex =
  }

}

func drawWideTile(
  x: Int,
  y: Int,
  ops: Span<WideTileDrawOp>,
  pixels: inout MutableSpan<Pixel>, // row major tho
  width: Int,
  height: Int
) {
  for i in ops.indices {
    switch ops[i] {
    case .solid(let x, let w, let color):
      // simd blend ???
      if color.alpha == 1.0 {
        // fill it
      }

    case .aa(let x, let w, let color, let index, let coverageOffset):
      do {}
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

// TODO: Borrowing iterator
func generateTiles(lines: consuming [Line]) -> [Tile] {
  var tiles: [Tile] = []
  let tileSize = 4  // 16; 4 by 4

  for line in lines {
    // print(line)
    let yStart = Int(line.start.y) / tileSize
    let yEnd = Int(line.end.y) / tileSize

    // first bin line by y
    // for each segment: bin by x
    let dy = line.end.y - line.start.y
    let dir = if dy > 0 { 1 } else { -1 }
    for y in stride(from: yStart, through: yEnd, by: dir) {
      // let yBinnedLine = Line(line.sample(t1), line.sample(t2))
      let yBinnedLine = line.crop(y: Float(tileSize * y)...(Float(tileSize * (y + 1))))
      // print(" - \(yBinnedLine)")

      let xStart = Int(yBinnedLine.start.x) / tileSize
      let xEnd = Int(yBinnedLine.end.x) / tileSize
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      let dir = if dx > 0 { 1 } else { -1 }
      for x in stride(from: xStart, through: xEnd, by: dir) {
        let xBinnedLine = yBinnedLine.crop(x: Float(tileSize * x)...(Float(tileSize * (x + 1))))
        let tile = Tile(
          x: UInt16(x),
          y: UInt16(y),
          line: xBinnedLine,
          hasWinding: xBinnedLine.start.y == Float(y * tileSize)
        )
        tiles.append(tile)
        // print(" > \(tile)")
        if xBinnedLine.end == yBinnedLine.end {
          break
        }
      }

      if yBinnedLine.end == line.end {
        break
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
  var coverageIndex: UInt16
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

struct Region {
  // inclusive, not half open
  let tileIndexStart: Int
  let tileIndexEnd: Int
  let winding: Int
}

// TODO: bump allocator, per thread?
class CoverageBuffer: @unchecked Sendable {
  let buffer: UnsafeMutableBufferPointer<Float16>
  let tileSize: Int
  let current: Atomic<Int> = Atomic(0)

  // not thread safe
  var coverages: [Coverage] = []

  init(tileSize: Int, tileCount: Int = 1024 * 32) {
    self.tileSize = tileSize
    buffer = .allocate(capacity: tileCount * tileSize * tileSize)
    buffer.initialize(repeating: 0.0)
  }

  // each coverage is column major for simd4
  func allocate(_ width: Int) -> Coverage {
    let count = width * tileSize * tileSize
    let values = current.add(count, ordering: .relaxed)

    let newBuffer = UnsafeMutableBufferPointer(
      start: buffer.baseAddress! + values.oldValue, count: count
    )
    let c = Coverage(index: coverages.count, buffer: newBuffer)
    coverages.append(c)
    return c
  }

  deinit {
    buffer.deallocate()
  }
}

struct Coverage {
  let index: Int
  let buffer: UnsafeMutableBufferPointer<Float16>
}

func generateStrips(
  tiles: Span<Tile>,
  coverageBuffer: CoverageBuffer,
  scratchBuffer: UnsafeMutableBufferPointer<Float16>
) -> [Strip] {
  var strips: [Strip] = []
  var regions: [Region] = []
  var winding = 0

  var i = 0
  while i < tiles.count {
    let start = i
    let w = winding
    let x = tiles[i].x
    let y = tiles[i].y

    while i < tiles.count - 1 {
      let next = tiles[i + 1]
      if next.y == tiles[i].y && next.x - tiles[i].x <= 1 {
        if next.hasWinding {
          winding += next.line.direction > 0 ? 1 : 0
        }
        i += 1
      } else {
        winding = 0
        break
      }
    }

    // zeroing only needed
    let stripWidth = Int(tiles[i].x - tiles[start].x + 1)
    scratchBuffer.extracting(0..<stripWidth * coverageBuffer.tileSize * coverageBuffer.tileSize)
      .update(repeating: 0.0)
    // scratchBuffer.initialize(repeating: 0.0)

    // allocate buffer, known size
    let coverage = coverageBuffer.allocate(i - start + 1)
    computeCoverage(
      tiles: tiles.extracting(start...i),
      tileSize: coverageBuffer.tileSize,
      buffer: coverage.buffer,
      scratchBuffer: scratchBuffer
    )

    // TODO: fill rule
    strips.append(Strip(x: x, y: y, coverageIndex: UInt16(coverage.index), shouldFillLeft: w != 0))
    regions.append(Region(tileIndexStart: start, tileIndexEnd: i, winding: w))
    i += 1
  }

  return strips
}

// column major
func computeCoverage(
  tiles: Span<Tile>,
  // inclusive
  tileSize: Int,
  buffer: UnsafeMutableBufferPointer<Float16>,  // fill
  scratchBuffer: UnsafeMutableBufferPointer<Float16>  // coverage
) {
  let stripStartY = Float(tiles[0].y) * 4

  for i in tiles.indices {
    let line = tiles[unchecked: i].line

    for ly in 0..<4 {
      let yBinnedLine = line.crop(y: stripStartY + Float(ly)...stripStartY + Float(ly + 1))

      for lx in 0..<4 {
        let tileStartX = Float(tiles[i].x) * 4
        let line = yBinnedLine.crop(x: tileStartX + Float(lx)...tileStartX + Float(lx + 1))

        // crop line into
        let dy = Float16(line.end.y - line.start.y)
        let xMid = Float16(line.start.x + line.end.x) / 2 - Float16(tileStartX)

        //
        // coverage
        let offset = Int(tiles[i].x - tiles[0].x) * tileSize * tileSize + lx * tileSize + ly
        // print(" - \(offset), \(buffer.count)")
        scratchBuffer[offset] += dy
        // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
        // fill
        buffer[offset] += dy * (1 - xMid)
      }
    }
  }

  let fill = UnsafeMutablePointer<SIMD4<Float16>>(OpaquePointer(buffer.baseAddress))!
  let coverage = UnsafeMutablePointer<SIMD4<Float16>>(OpaquePointer(scratchBuffer.baseAddress))!
  var acc: SIMD4<Float16> = .zero

  for x in tiles[0].x * 4..<tiles[tiles.count - 1].x * 4 {
    fill[Int(x)] += acc
    acc += coverage[Int(x)]
  }

}

enum WideTileDrawOp {
  case solid(x: UInt16, w: UInt16, Color)
  case aa(x: UInt16, w: UInt16, Color, index: UInt, coverageOffset: UInt16 = 0)
}

extension Line {
  func crop(y range: ClosedRange<Float>) -> Line {
    let dy = self.end.y - self.start.y

    let t1 = ((range.lowerBound - self.start.y) / dy).clamped(from: 0.0, to: 1.0)
    let t2 = ((range.upperBound - self.start.y) / dy).clamped(from: 0.0, to: 1.0)

    return Line(sample(t1), sample(t2))
  }

  func crop(x range: ClosedRange<Float>) -> Line {
    let dx = self.end.x - self.start.x

    let t1 = ((range.lowerBound - self.start.x) / dx).clamped(from: 0.0, to: 1.0)
    let t2 = ((range.upperBound - self.start.x) / dx).clamped(from: 0.0, to: 1.0)

    return Line(sample(t1), sample(t2))
  }

}
