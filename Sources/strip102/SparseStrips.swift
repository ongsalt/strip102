struct Tile {
  let x: UInt16
  let y: UInt16
  let line: Line
  let hasWinding: Bool
}

struct Strip {
  var x: UInt16
  var y: UInt16
  var _coverageIndex: UInt32

  var coverageIndex: UInt32 {
    _coverageIndex & ~(0x1 << 31)
  }

  var shouldFillLeft: Bool {
    get {
      (_coverageIndex >> 31) == 0x1
    }
    set {
      _coverageIndex = ((newValue ? 0x1 : 0x0) << 31) | coverageIndex
    }
  }
}

enum FillCommand {
  case solid(x: UInt16, y: UInt16, w: UInt16)
  case antialiased(x: UInt16, y: UInt16, coverageIndex: UInt32)
}

func fillSparseStrip(
  path: borrowing Path,
  color: borrowing Color,
  transform: Affine = .identity,
  pixels: inout MutableSpan<Pixel>,
  width: Int,
  height: Int
) {
  let lines = path.breakIntoLines(transform: transform, tolerance: 0.25)

  var tiles: [Tile] = []

  let tileSize = 4  // 16; 4 by 4

  for line in lines {
    print(line)
    let yStart = line.yBounds.0 / tileSize
    let yEnd = line.yBounds.1 / tileSize

    // first bin line by y
    // for each segment: bin by x
    let dy = line.end.y - line.start.y
    for y in yStart...yEnd {
      let t1 = ((Float(tileSize * y) - line.start.y) / dy).clamped(from: 0.0, to: 1.0)
      let t2 = ((Float(tileSize * (y + 1)) - line.start.y) / dy).clamped(from: 0.0, to: 1.0)

      let yBinnedLine = Line(line.sample(t1), line.sample(t2))
      // print(" - \(yBinnedLine)")

      let xStart = yBinnedLine.xBounds.0 / tileSize
      let xEnd = yBinnedLine.xBounds.1 / tileSize
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      for x in xStart...xEnd {
        let t1 = ((Float(tileSize * x) - yBinnedLine.start.x) / dx).clamped(from: 0.0, to: 1.0)
        let t2 = ((Float(tileSize * (x + 1)) - yBinnedLine.start.x) / dx).clamped(
          from: 0.0, to: 1.0)

        let xBinnedLine = Line(yBinnedLine.sample(t1), yBinnedLine.sample(t2))
        let tile = Tile(x: UInt16(x), y: UInt16(y), line: xBinnedLine, hasWinding: xBinnedLine.start.y == Float(y * tileSize))
        tiles.append(tile)
        print("   - \(tile)")
        if t2 == 1.0 {
          break
        }
      }
    }

    // tiles.append(Tile(x: UInt16(x), y: UInt16(y), line: clipped, hasWinding: hasWinding))
  }

  tiles.sort { a, b in
    if a.x == b.x {
      return a.y < b.y
    }
    return a.x < b.x
  }
}
