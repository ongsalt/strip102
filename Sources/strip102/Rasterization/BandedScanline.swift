import Foundation

/// Rows per band. 16 so one column of a band's accumulator is exactly one `SIMD16<Float>`:
/// the resolve pass then carries the winding across all 16 rows in a single sweep.
let BAND_HEIGHT = 16

/// one column of a band's accumulator, one lane per row
typealias Band = SIMD16<Float>

/// A path's flattened lines, clipped into bands and packed CSR-style: band `b` owns
/// `lines[offsets[b]..<offsets[b + 1]]`. A line crossing a band boundary is stored once per
/// band it touches, already cut to that band, so a band render never looks outside its own rows.
struct BandedLines: Sendable {
  var lines: [Line]
  /// `bandCount + 1` long
  var offsets: [Int]

  @inline(__always)
  func range(inBand band: Int) -> Range<Int> {
    offsets[band]..<offsets[band + 1]
  }
}

/// Everything a band needs from one draw op.
private struct BandJob {
  let source: PixelF
  let fillRule: FillRule
  let lines: BandedLines
}

/// floor division, so a line above the canvas bins into a negative band instead of band 0
@inline(__always)
private func bandIndex(_ y: Int) -> Int {
  Int((Float(y) / Float(BAND_HEIGHT)).rounded(.down))
}

/// Cuts `lines` into bands, dropping whatever falls outside the canvas vertically.
func bandLines(_ lines: consuming [Line], height: Int) -> BandedLines {
  let bandCount = (height + BAND_HEIGHT - 1) / BAND_HEIGHT

  // one pass to cut and tally, so the counts can never disagree with what gets placed
  var counts = [Int](repeating: 0, count: bandCount)
  var pieces: [(band: Int, line: Line)] = []
  pieces.reserveCapacity(lines.count * 2)

  for line in lines {
    let (y0, y1) = line.yBounds
    let first = max(bandIndex(y0), 0)
    let last = min(bandIndex(y1), bandCount - 1)
    guard first <= last else { continue }

    for band in first...last {
      guard
        let piece = line.clipY(
          from: Float(band * BAND_HEIGHT), to: Float((band + 1) * BAND_HEIGHT))
      else { continue }

      counts[band] += 1
      pieces.append((band: band, line: piece))
    }
  }

  var offsets = [Int](repeating: 0, count: bandCount + 1)
  var running = 0
  for band in 0..<bandCount {
    offsets[band] = running
    running += counts[band]
  }
  offsets[bandCount] = running

  var cursor = Array(offsets.prefix(bandCount))
  let packed = [Line](unsafeUninitializedCapacity: running) { out, initializedCount in
    initializedCount = running
    for piece in pieces {
      out.initializeElement(at: cursor[piece.band], to: piece.line)
      cursor[piece.band] += 1
    }
  }

  return BandedLines(lines: packed, offsets: offsets)
}

/// Scanline coverage, but with the screen cut into 16-row bands.
///
/// Three things it buys over `fillScanline`:
/// - the flattening and the per-band binning are cached per (path, transform), so a frame that
///   redraws the same shapes only pays for accumulation and blending
/// - bands own disjoint rows, so they render in parallel with no coordination
/// - a band's accumulator is column-major `SIMD16<Float>`, one lane per row, so the winding
///   prefix sum advances 16 rows at a time
///
/// Coverage semantics match `fillScanline` exactly, including its handling of geometry that runs
/// off the left edge: a line left of x = 0 contributes no winding to the visible columns.
final class BandedScanlineRenderer: @unchecked Sendable {
  let coreCount = getRealCoreCount()

  private struct CacheKey: Hashable {
    let pathId: Path.ID
    let transform: Affine
    /// band layout depends on the canvas height, so a resize must not reuse the old bins
    let height: Int
  }

  /// render-thread only; workers never touch it
  private var cache: [CacheKey: BandedLines] = [:]

  /// per worker, `fill` then `coverage`, `scratchWidth` columns each. Reused across bands and
  /// frames; every band hands it back zeroed, so it is only cleared over columns actually touched
  private var scratch: [UnsafeMutableBufferPointer<Band>] = []
  private var scratchWidth = 0

  deinit {
    for buffer in scratch {
      buffer.deallocate()
    }
  }

  private func ensureScratch(width: Int) {
    guard width > scratchWidth else { return }

    for buffer in scratch {
      buffer.deallocate()
    }
    scratch = (0..<coreCount).map { _ in
      let buffer = UnsafeMutableBufferPointer<Band>.allocate(capacity: width * 2)
      buffer.initialize(repeating: .zero)
      return buffer
    }
    scratchWidth = width
  }

  func push(
    ops: Span<DrawOp>,
    pixels: inout MutableSpan<Pixel>,
    width: Int,
    height: Int
  ) {
    guard width > 0, height > 0, ops.count > 0 else { return }
    ensureScratch(width: width)

    let bandCount = (height + BAND_HEIGHT - 1) / BAND_HEIGHT

    // serial prepass: purge dirty paths, resolve hits, collect misses. All cache mutation
    // happens here on the render thread
    // Collect every dirty id first and purge in one sweep. Filtering per dirty path instead
    // rebuilds the whole dictionary once per path — O(paths x cache), which is invisible while
    // geometry is static and quadratic the moment it animates.
    var dirtyIds: Set<Path.ID> = []
    for i in 0..<ops.count {
      let path = ops[unchecked: i].path
      if path.dirty {
        // the old shape under this id is gone; this also drops entries a freed path left
        // behind when its storage address gets reused
        dirtyIds.insert(path.id)
        path.dirty = false
      }
    }
    if !dirtyIds.isEmpty {
      cache = cache.filter { !dirtyIds.contains($0.key.pathId) }
    }

    // resolving hits only after every purge, so a path drawn twice cannot pick up a stale
    // entry on its first op and a rebuilt one on its second
    var banded: [BandedLines?] = []
    banded.reserveCapacity(ops.count)
    var misses: [Int] = []
    for i in 0..<ops.count {
      let key = CacheKey(
        pathId: ops[unchecked: i].path.id, transform: ops[unchecked: i].transform,
        height: height)
      let hit = cache[key]
      if hit == nil { misses.append(i) }
      banded.append(hit)
    }

    // flatten and bin the misses in parallel
    let built = misses.parallelMap(threads: coreCount) { i, _ in
      let lines = ops[unchecked: i].path.breakIntoLines(transform: ops[unchecked: i].transform)
      return bandLines(lines, height: height)
    }

    for (task, i) in misses.enumerated() {
      let path = ops[unchecked: i].path
      cache[CacheKey(pathId: path.id, transform: ops[unchecked: i].transform, height: height)] =
        built[task]
      banded[i] = built[task]
    }

    // flatten the draw list into plain data, so the band workers never reach back into the ops
    // span and never touch a refcount
    let jobs = (0..<ops.count).map { i in
      BandJob(
        source: ops[unchecked: i].color.pixel,
        fillRule: ops[unchecked: i].path.fillRule,
        lines: banded[i]!)
    }

    nonisolated(unsafe) let scratch = scratch
    pixels.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let pixels = buffer.baseAddress!

      // bands own disjoint row ranges, so no two workers ever write the same pixel, and
      // looping the ops inside a band keeps painter order intact for every pixel in it
      parallelFor(count: bandCount, threads: coreCount) { band, thread in
        let bandTop = band * BAND_HEIGHT
        let rowCount = min(BAND_HEIGHT, height - bandTop)
        guard rowCount > 0 else { return }

        let base = scratch[thread].baseAddress!
        let fill = base
        let coverage = base + self.scratchWidth

        // by index, not `for job in jobs`: binding an element copies it, and a `BandedLines`
        // holds two arrays, so each copy is an atomic retain/release pair — on every worker,
        // once per op per band. Subscripting borrows in place instead.
        for j in jobs.indices {
          let range = jobs[j].lines.range(inBand: band)
          guard !range.isEmpty else { continue }

          var dirtyStart = width
          var dirtyEnd = -1
          var background = Band.zero
          var overflowsRight = false

          accumulate(
            lines: jobs[j].lines.lines, range: range,
            bandTop: bandTop, rowCount: rowCount, width: width,
            fill: fill, coverage: coverage, dirtyStart: &dirtyStart, dirtyEnd: &dirtyEnd,
            background: &background, overflowsRight: &overflowsRight)

          // a row carrying winding in from the left is covered from column 0, and one whose
          // shape runs off the right edge stays covered all the way to the last column
          if any(background .!= .zero) { dirtyStart = min(dirtyStart, 0) }
          if overflowsRight && dirtyEnd >= 0 { dirtyEnd = width - 1 }

          guard dirtyStart <= dirtyEnd else { continue }

          resolve(
            fill: fill, coverage: coverage, from: dirtyStart, to: dirtyEnd,
            bandTop: bandTop, rowCount: rowCount, width: width,
            source: jobs[j].source, fillRule: jobs[j].fillRule, background: background,
            pixels: pixels)

          // hand the scratch back zeroed for the next op, over just the columns touched
          let dirtyCount = dirtyEnd - dirtyStart + 1
          (fill + dirtyStart).update(repeating: .zero, count: dirtyCount)
          (coverage + dirtyStart).update(repeating: .zero, count: dirtyCount)
        }
      }
    }
  }
}

/// Trapezoid coverage for one op's lines within one band, scattered into the column-major
/// accumulator: row `y` lands in lane `y - bandTop`.
@inline(__always)
private func accumulate(
  // borrowing, so passing the array in costs no retain; the span is built inside, where it
  // cannot outlive the borrow
  lines: borrowing [Line],
  range: Range<Int>,
  bandTop: Int,
  rowCount: Int,
  width: Int,
  fill: UnsafeMutablePointer<Band>,
  coverage: UnsafeMutablePointer<Band>,
  dirtyStart: inout Int,
  dirtyEnd: inout Int,
  background: inout Band,
  overflowsRight: inout Bool
) {
  let lines = lines.span.extracting(range)

  for i in lines.indices {
    let line = lines[unchecked: i]

    let (y0, y1) = line.yBounds
    // the line is already cut to the band; the clamp only trims the last band's overhang
    let yStart = max(y0, bandTop)
    let yEnd = min(y1, bandTop + rowCount - 1)
    guard yStart <= yEnd else { continue }

    for y in yStart...yEnd {
      guard let row = line.clipY(from: Float(y), to: Float(y + 1)) else { continue }

      let (x0, x1) = row.xBounds
      let lane = y - bandTop

      // a crossing left of the viewport still decides the winding this row starts with, so
      // its dy goes into the row's background instead of into a column
      if x0 < 0 {
        let leftmost = min(row.start.x, row.end.x)
        if let left = row.clipX(from: leftmost - 1, to: 0) {
          background[lane] += left.end.y - left.start.y
        }
      }
      // the winding it carries does not come back to zero inside the viewport, so the sweep
      // has to run to the right edge rather than stopping at the last column written
      if x1 >= width {
        overflowsRight = true
      }

      let xStart = max(x0, 0)
      let xEnd = min(x1, width - 1)
      guard xStart <= xEnd else { continue }

      dirtyStart = min(dirtyStart, xStart)
      dirtyEnd = max(dirtyEnd, xEnd)

      for x in xStart...xEnd {
        guard let cell = row.clipX(from: Float(x), to: Float(x + 1)) else { continue }

        let dy = cell.end.y - cell.start.y
        let xMid = (cell.start.x + cell.end.x) / 2 - Float(x)

        // x is clamped to 0..<width and lane to 0..<rowCount, both inside the accumulator
        coverage[x][lane] += dy
        // trapezoid, see https://www.youtube.com/watch?v=B9bztU1sTFA
        fill[x][lane] += dy * (1 - xMid)
      }
    }
  }
}

/// Sweeps the dirty columns once, carrying the winding of all 16 rows in a single SIMD
/// accumulator, and blends what comes out.
@inline(__always)
private func resolve(
  fill: UnsafeMutablePointer<Band>,
  coverage: UnsafeMutablePointer<Band>,
  from dirtyStart: Int,
  to dirtyEnd: Int,
  bandTop: Int,
  rowCount: Int,
  width: Int,
  source: PixelF,
  fillRule: FillRule,
  background: Band,
  pixels: UnsafeMutablePointer<Pixel>
) {
  // every column left of dirtyStart is untouched, so the sweep starts with only the winding
  // carried in from the geometry left of the viewport
  var acc = background
  let ones = Band(repeating: 1)
  let evenOdd = fillRule == .evenOdd

  // lanes past the last band's short row count never hold real coverage, so they must not
  // hold a run back from being solid
  var active = SIMDMask<SIMD16<Int32>>(repeating: false)
  for lane in 0..<rowCount {
    active[lane] = true
  }
  let inactive = .!active

  // a run of columns where every row is fully inside the shape. Only worth taking when the
  // source is opaque: then the run is a straight overwrite, one memset per row, and the
  // per-pixel blend (and its per-column SIMD tail) is skipped entirely
  let opaqueSource = source.w >= 255
  let solidPixel = pack(source)
  var runStart = -1

  @inline(__always)
  func flushRun(through end: Int) {
    guard runStart >= 0 else { return }
    let count = end - runStart + 1
    for lane in 0..<rowCount {
      // bandTop + lane < height and the run stays inside dirtyStart...dirtyEnd < width
      let start = (bandTop + lane) * width + runStart
      UnsafeMutableBufferPointer(start: pixels + start, count: count)
        .update(repeating: solidPixel)
    }
    runStart = -1
  }

  for x in dirtyStart...dirtyEnd {
    let winding = acc + fill[x]
    acc += coverage[x]

    var opacity: Band
    if evenOdd {
      opacity = .zero
      for lane in 0..<rowCount {
        opacity[lane] = evenOddOpacity(winding[lane])
      }
    } else {
      // min(abs(winding), 1), branchlessly across all 16 rows
      let magnitude = winding.replacing(with: -winding, where: winding .< .zero)
      opacity = magnitude.replacing(with: ones, where: magnitude .> ones)
    }

    if opaqueSource && all((opacity .>= ones) .| inactive) {
      if runStart < 0 { runStart = x }
      continue
    }
    flushRun(through: x - 1)

    let covered = opacity .>= Band(repeating: .ulpOfOne)
    if !any(covered) { continue }

    for lane in 0..<rowCount where covered[lane] {
      // bandTop + lane < height and x < width, so this is inside the image
      blend(source, &pixels[(bandTop + lane) * width + x], opacity[lane])
    }
  }

  flushRun(through: dirtyEnd)
}
