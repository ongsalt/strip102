import Dispatch

// dont need to fill immediately
func fillSparseStrip(
  path: borrowing Path,
  color: borrowing Color,
  transform: Affine = .identity,
  pixels: inout MutableSpan<Pixel>,
  width: Int,
  height: Int
) {
  let lines = path.breakIntoLines(transform: transform, tolerance: 0.25)
  let tiles = generateTiles(lines: lines)

  generateStrips(tiles: tiles)
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
      let t1 = ((Float(tileSize * y) - line.start.y) / dy).clamped(from: 0.0, to: 1.0)
      let t2 = ((Float(tileSize * (y + 1)) - line.start.y) / dy).clamped(from: 0.0, to: 1.0)

      let yBinnedLine = Line(line.sample(t1), line.sample(t2))
      // print(" - \(yBinnedLine)")

      let xStart = Int(yBinnedLine.start.x) / tileSize
      let xEnd = Int(yBinnedLine.end.x) / tileSize
      let dx = yBinnedLine.end.x - yBinnedLine.start.x

      let dir = if dx > 0 { 1 } else { -1 }
      for x in stride(from: xStart, through: xEnd, by: dir) {
        let t1 = ((Float(tileSize * x) - yBinnedLine.start.x) / dx).clamped(from: 0.0, to: 1.0)
        let t2 = ((Float(tileSize * (x + 1)) - yBinnedLine.start.x) / dx).clamped(
          from: 0.0, to: 1.0)

        let xBinnedLine = Line(yBinnedLine.sample(t1), yBinnedLine.sample(t2))
        let tile = Tile(
          x: UInt16(x), y: UInt16(y), line: xBinnedLine,
          hasWinding: xBinnedLine.start.y == Float(y * tileSize))
        tiles.append(tile)
        // print(" > \(tile)")
        if t2 == 1.0 {
          break
        }
      }

      if t2 == 1.0 {
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

struct _Strip {
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

struct Region {
  // inclusive, not half open
  let tileIndexStart: Int
  let tileIndexEnd: Int
  let winding: Int
}

func generateStrips(tiles: [Tile]) {
  var regions: [Region] = []
  var winding = 0

  var i = 0
  while i < tiles.count {
    let start = i
    let w = winding
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

    regions.append(Region(tileIndexStart: start, tileIndexEnd: i, winding: w))
    i += 1
  }

  print(regions)

  // spawn thread to compute coverage
}
