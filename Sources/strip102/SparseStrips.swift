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
  nonisolated(unsafe) let coverageBuffers: [CoverageBuffer] = (0..<coreCount).map { _ in
    CoverageBuffer(tileSize: tileSize)
  }

  let a: [Int] = Array(capacity: ops.count) { out in
    let next = Atomic(0)
    out.withUnsafeMutableBufferPointer { buffer, wrote in
      wrote = ops.count
      nonisolated(unsafe) let buffer = buffer

      DispatchQueue.concurrentPerform(iterations: coreCount) { index in
        // per thread data
        let coverageBuffer: CoverageBuffer = coverageBuffers[index]
        let scratchBuffer: UnsafeMutableBufferPointer<Float16> = .allocate(
          capacity: tileSize * tileSize * 1024)

        // pull tasks
        while true {
          let i = next.add(1, ordering: .relaxed).oldValue
          guard i < ops.count else { break }

          let lines = ops[i].path.breakIntoLines(transform: ops[i].transform, tolerance: 0.25)
          let tiles = generateTiles(lines: lines)

          for t in tiles {
            print(t)
          }
          // also generate coverage
          let strips = generateStrips(
            tiles: tiles.span, 
            coverageBuffer: coverageBuffer, 
            scratchBuffer: scratchBuffer
          )

          buffer[i] = 12
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
class CoverageBuffer {
  let buffer: UnsafeMutableBufferPointer<Float16>
  let tileSize: Int
  var current: Int = 0

  var coverages: [Coverage] = []

  init(tileSize: Int, tileCount: Int = 1024 * 32) {
    self.tileSize = tileSize
    buffer = .allocate(capacity: tileCount * tileSize * tileSize)
  }

  // each coverage is column major for simd4
  func allocate(_ width: Int) -> Coverage {
    if width + current > buffer.count {
      fatalError("out of memory")
    }
    defer {
      current += width
    }

    let c = Coverage(index: coverages.count, buffer: buffer.extracting(current..<current + width))
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

    // allocate buffer, known size
    let coverage = coverageBuffer.allocate(i - start + 1)
    computeCoverage(
      tiles: tiles, 
      start: start, 
      end: i, 
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
  start: Int,
  end: Int,
  buffer: UnsafeMutableBufferPointer<Float16>,
  scratchBuffer: UnsafeMutableBufferPointer<Float16>
) {
  let actualY = Float(tiles[0].y) * 4
  // h = 4

  // for each line in a tile
  for i in 0...tiles.count {
    let line = tiles[unchecked: i].line

    for y in 0...4 {
      let yBinnedLine = line.crop(y: actualY + Float(y)...actualY + Float(y + 1))

      for x in 0...4 {
        let actualX = Float(tiles[i].x) * 4
        let line = yBinnedLine.crop(x: actualX + Float(x)...actualX + Float(x + 1))

        // crop line into
        let dy = line.end.y - line.start.y
        let xMid = (line.start.x + line.end.x) / 2 - Float(x)

        // x is clamped to 0..<w and the tables are w long
        scratchBuffer[unchecked: x * 4 + y] += dy
        // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
        buffer[unchecked: x * 4 + y] += dy * (1 - xMid)
      }
    }
  }
}

enum WideTileDrawOp {
  case solid(x: UInt, Color)
  case aa(x: UInt, Color, index: Int)
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
