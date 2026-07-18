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
  // Array(unsafeUninitializedCapacity: Int, initializingWith: (_ buffer: inout UnsafeMutableBufferPointer<Element>, _ initializedCount: inout Int) throws(Error) -> Void)
  let strips: [[Strip]] = Array(unsafeUninitializedCapacity: ops.count) { out, wrote in
    let next = Atomic(0)
    wrote = ops.count
    nonisolated(unsafe) let buffer = out
    DispatchQueue.concurrentPerform(iterations: coreCount) { _ in
      // per thread
      let scratchBuffer: UnsafeMutableBufferPointer<Float16> = .allocate(
        capacity: tileSize * tileSize * 1024)

      // pull tasks
      while true {
        let i = next.add(1, ordering: .relaxed).oldValue
        guard i < ops.count else { break }

        let lines = ops[i].path.breakIntoLines(transform: ops[i].transform, tolerance: 0.25)
        let tiles = generateTiles(lines: lines)

        // print("tiles")
        // for t in tiles {
        //   print(" - \(t)")
        // }

        // also generate coverage
        let strips = generateStrips(
          tiles: tiles.span,
          coverageBuffer: coverageBuffer,
          scratchBuffer: scratchBuffer
        )

        // print("strips", strips)

        buffer.initializeElement(at: i, to: strips)
      }
    }
  }

  // for s in strips {
  //   for s in s {
  //     print(s)
  //     print(coverageBuffer.coverages[Int(s.coverageIndex)])
  //   }
  // }

  // generate per WideTile (screen space) draw commands ??
  let wideTileXCount = Int((Float(width) / 256).rounded(.up))
  let wideTileYCount = Int((Float(height) / 4).rounded(.up))

  // wide tile is in row major for conveniece
  var wideTileCommands: [[WideTileDrawOp]] = Array(
    repeating: [], count: wideTileXCount * wideTileYCount)

  for i in ops.indices {
    // generate command in painter order
    let strips = strips[i]

    // in tile unit (x, y), end of the last strip emitted on this row
    var lastStripEnd: (x: Int, y: Int)?
    for strip in strips {
      // strip is ordered by x anyway, so by the time we generate .solid it gonna be well form

      // in tile unit (w)
      let coverageWidth =
        coverageBuffer.coverages[Int(strip.coverageIndex)].buffer.count / (tileSize * tileSize)
      var coverageW = coverageWidth
      // in tile size

      // strip may got split
      // in wideTile index
      let wideTileXStart = Int(strip.x * 4 / 256)
      // wideTileX where this end
      let wideTileXEnd = Int(strip.x) + coverageW * 4 / 256
      let wideTileY = Int(strip.y)

      // 1 widetile is 64 4x4 tile, tile unit
      var x: UInt16 = UInt16(Int(strip.x) - wideTileXStart * 64)

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
          if fillWideTileIndex < wideTileCommands.count {
            // wideTileCommands[fillWideTileIndex].append(
            //   WideTileDrawOp.solid(
            //     x: UInt16(localX),
            //     w: UInt16(filledWidth),
            //     ops[i].color
            //   )
            // )
          }
          fillX += filledWidth
        }
      }

      for wideTileX in wideTileXStart...wideTileXEnd {
        let wideTileIndex = wideTileX + wideTileY * wideTileXCount
        // in tile unit (w)
        let areaLeft = Int(64 - x)
        let w = min(coverageW, areaLeft)
        // TODO: verify this
        // in pixel, but it will always be divisible by 16 tho

        if wideTileIndex >= wideTileCommands.count {
          break
        }

        wideTileCommands[wideTileIndex].append(
          WideTileDrawOp.aa(
            x: x,
            w: UInt16(w),  // it tile unit, should not overflow
            ops[i].color,
            index: UInt(strip.coverageIndex),
            offset: UInt16(0)
          )
        )
        // x will always be 0 in later iteration
        x = 0
        coverageW -= w
      }

      lastStripEnd = (x: Int(strip.x) + coverageWidth, y: wideTileY)
    }
  }

  // let total = wideTileCommands.lazy.map(\.count).reduce(0, +)
  // print(wideTileCommands[214].count)

  let _wideTileCommands = wideTileCommands
  for cmds in _wideTileCommands {
    // if !cmds.isEmpty {
    //   print(cmds)
    // }
  }

  // executing thos
  let next = Atomic(0)
  pixels.withUnsafeMutableBufferPointer { buffer in
    nonisolated(unsafe) let buffer = buffer
    DispatchQueue.concurrentPerform(iterations: coreCount) { _ in
      // pull tasks
      while true {
        let i = next.add(1, ordering: .relaxed).oldValue
        guard i < _wideTileCommands.count else { break }

        let commands = _wideTileCommands[i]
        let x = i % wideTileXCount
        let y = i / wideTileXCount

        drawWideTile(
          x: x, y: y, ops: commands.span, coverageBuffer: coverageBuffer,
          pixels: buffer.baseAddress!,
          width: width, height: height)
      }
    }
  }
}

func drawWideTile(
  x: Int,
  y: Int,
  ops: Span<WideTileDrawOp>,
  coverageBuffer: CoverageBuffer,
  pixels: UnsafeMutablePointer<Pixel>,  // row major tho
  width: Int,
  height: Int
) {
  let tileStartX = x * 256
  let tileStartY = y * 4
  let rowCount = min(4, height - tileStartY)
  guard rowCount > 0, ops.count > 0 else { return }
  // print("Drawing wide tile at (\(tileStartX) \(tileStartY))")

  for i in ops.indices {
    switch ops[i] {
    case .solid(let x, let w, let color):
      let startX = tileStartX + Int(x) * 4
      let endX = min(startX + Int(w) * 4, width)
      guard startX < endX else { continue }

      if color.alpha == 1.0 {
        let pixel: Pixel = [
          UInt8(color.red * 255), UInt8(color.green * 255), UInt8(color.blue * 255), 255,
        ]
        for row in 0..<rowCount {
          let rowStart = (tileStartY + row) * width
          for px in startX..<endX {
            pixels[rowStart + px] = pixel
          }
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

    case .aa(let x, let w, let color, let index, let offset):
      let coverage = coverageBuffer.coverages[Int(index)].buffer
      let startX = tileStartX + Int(x) * 4  // actual pixel
      let endX = min(startX + Int(w) * 4, width)
      // print(" - Executing aa at x=\(startX)...\(endX)")
      guard startX < endX else { continue }

      let source = Color8(color)
      for column in 0..<(endX - startX) {
        // column major, 4 rows per pixel column
        let columnStart = (Int(offset) + column) * 4
        // print(coverage, columnStart)
        for row in 0..<rowCount {
          // TODO: fill rule, this is nonzero
          let opacity = min(abs(Float(coverage[columnStart + row])), 1.0)
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

// [0, 4) [4, 8) [8, 12) [12, 15)

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
    // print("new dy=\(dy) yStart=\(yStart) yEnd=\(yEnd)")
    for y in stride(from: yStart, through: yEnd, by: dir) {
      // let yBinnedLine = Line(line.sample(t1), line.sample(t2))
      let yBinnedLine = line.crop(y: Float(tileSize * y)...(Float(tileSize * (y + 1))))

      // ignore horizontal line
      // if yBinnedLine.start.y == yBinnedLine.end.y { continue }

      // print(line, yBinnedLine)
      // print(" - \(yBinnedLine)")

      let xStart = Int(yBinnedLine.start.x) / tileSize
      let xEnd = Int(yBinnedLine.end.x) / tileSize
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      let dir = if dx > 0 { 1 } else { -1 }
      for x in stride(from: xStart, through: xEnd, by: dir) {
        let xBinnedLine = yBinnedLine.crop(x: Float(tileSize * x)...(Float(tileSize * (x + 1))))
        if xBinnedLine.isPoint { continue }

        let tile = Tile(
          x: UInt16(x),
          y: UInt16(y),
          line: xBinnedLine,
          hasWinding: abs(min(xBinnedLine.start.y, xBinnedLine.end.y) - Float(y * tileSize)) < 0.001
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

// TODO: bump allocator, per thread?
class CoverageBuffer: @unchecked Sendable {
  let buffer: UnsafeMutableBufferPointer<Float16>
  let tileSize: Int
  let current: Mutex<Int> = Mutex(0)

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
    return current.withLock {
      let prev = $0
      $0 += count
      let newBuffer =
        UnsafeMutableBufferPointer(start: buffer.baseAddress! + prev, count: count)
      let c = Coverage(index: coverages.count, buffer: newBuffer)
      self.coverages.append(c)
      return c
    }
  }

  func print(index: Int) {
    let c = coverages[index]
    let w = c.buffer.count / tileSize
    // column majot
    for y in 0..<tileSize {
      for x in 0..<w {
        Swift.print("\(c.buffer[x * tileSize + y]) ", terminator: "")
      }
      Swift.print()
    }
  }

  deinit {
    buffer.deallocate()
  }
}

struct Coverage: @unchecked Sendable {
  let index: Int
  let buffer: UnsafeMutableBufferPointer<Float16>
}

func generateStrips(
  tiles: Span<Tile>,
  coverageBuffer: CoverageBuffer,
  scratchBuffer: UnsafeMutableBufferPointer<Float16>
) -> [Strip] {
  var strips: [Strip] = []
  var winding = 0
  var lastY = 0

  var i = 0
  while i < tiles.count {
    if lastY != tiles[i].y {
      winding = 0
      // print("reset winding \(winding) \(tiles[i])")
    }
    lastY = Int(tiles[i].y)

    let start = i
    let w = winding
    let x = tiles[i].x
    let y = tiles[i].y

    while i < tiles.count - 1 {
      if tiles[i].hasWinding {
        winding += tiles[i].line.direction > 0 ? 1 : -1
        // print("winding=\(winding)")
      }

      let next = tiles[i + 1]
      if next.y == tiles[i].y && next.x - tiles[i].x <= 1 {
        i += 1
      } else {
        break
      }
    }

    // zeroing only needed
    let stripWidth = Int(tiles[i].x - tiles[start].x + 1)
    scratchBuffer.extracting(0..<stripWidth * coverageBuffer.tileSize * coverageBuffer.tileSize)
      .update(repeating: 0.0)
    // scratchBuffer.initialize(repeating: 0.0)

    // allocate buffer, known size
    let coverage = coverageBuffer.allocate(stripWidth)
    // print(
    //   "Compute coverage: background=\(w) stripWidth=\(stripWidth), tiles[\(start)...\(i)], x: \(tiles[start].x)...\(tiles[i].x) y: \(tiles[start].y)...\(tiles[i].y)"
    // )

    let range = tiles.extracting(start...i)
    computeCoverage(
      tiles: range,
      tileSize: coverageBuffer.tileSize,
      buffer: coverage.buffer,
      scratchBuffer: scratchBuffer,
      background: w,
    )

    // coverageBuffer.print(index: coverage.index)

    // TODO: fill rule
    strips.append(Strip(x: x, y: y, coverageIndex: UInt16(coverage.index), shouldFillLeft: w != 0))
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
  scratchBuffer: UnsafeMutableBufferPointer<Float16>,  // coverage
  background: Int
) {
  // in pixel
  let stripStartY = Float(tiles[0].y) * 4

  for i in tiles.indices {
    let line = tiles[unchecked: i].line

    for ly in 0..<4 {
      let yBinnedLine = line.crop(y: stripStartY + Float(ly)...stripStartY + Float(ly + 1))
      // print(yBinnedLine, ly + Int(stripStartY) * 4)

      for lx in 0..<4 {
        let tileStartX = Float(tiles[i].x) * 4
        let line = yBinnedLine.crop(x: tileStartX + Float(lx)...tileStartX + Float(lx + 1))
        // if its out of this pixel, continue
        if line.xBounds.0 != lx + Int(tiles[i].x) * 4 { continue }
        if line.isPoint { continue }
        // print("> [\(Int(tileStartX) + lx), \(Int(stripStartY) + ly)] \(line)")

        // crop line into; math in f32, f16 only at the store
        let dy = line.end.y - line.start.y
        let xMid = (line.start.x + line.end.x) / 2 - (tileStartX + Float(lx))

        let offset = Int(tiles[i].x - tiles[0].x) * tileSize * tileSize + lx * tileSize + ly
        // coverage
        // print(" - \(offset), \(buffer.count)")
        scratchBuffer[offset] += Float16(dy)
        // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
        // fill
        // buffer[offset] += Float16(dy)
        buffer[offset] += Float16(dy * (1 - xMid))

        // print(" > coverage:\(scratchBuffer[offset]) fill:\(buffer[offset])")

      }
    }
  }

  let fill: UnsafeMutablePointer<SIMD4<Float16>> = UnsafeMutablePointer<SIMD4<Float16>>(
    OpaquePointer(buffer.baseAddress))!
  let coverage = UnsafeMutablePointer<SIMD4<Float16>>(OpaquePointer(scratchBuffer.baseAddress))!
  var acc: SIMD4<Float> = .zero

  for x in 0..<(tiles[tiles.count - 1].x - tiles[0].x + 1) * 4 {
    fill[Int(x)] = SIMD4<Float16>(SIMD4<Float>(fill[Int(x)]) + acc + Float(background))
    acc += SIMD4<Float>(coverage[Int(x)])
  }

}

enum WideTileDrawOp {
  case solid(x: UInt16, w: UInt16, Color)
  case aa(x: UInt16, w: UInt16, Color, index: UInt, offset: UInt16)
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
