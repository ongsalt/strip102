import Foundation

/// A recorded, not-yet-rasterized draw. The canvas' transform is baked in when the op is recorded,
/// so later transform changes do not retroactively move it.
struct DrawOp {
  var path: Path
  var color: Color
  var transform: Affine
}

/// A pixel buffer plus the state a draw needs: the current transformation matrix and the fill
/// algorithm to rasterize with. `draw` only records; nothing touches pixels until `flush`.
///
/// The canvas owns its pixel buffer and frees it on `deinit`. To keep the pixels past the canvas'
/// lifetime, take them with `takePixels()`.
public struct Canvas: ~Copyable {
  public let width: Int
  public let height: Int
  public private(set) var pixels: UnsafeMutableBufferPointer<Pixel>

  /// Which rasterizer `flush` runs. Set once here instead of at every call site.
  public var fillAlgorithm: FillAlgorithm

  /// The current transformation matrix, applied to every path recorded from now on.
  public var transform: Affine

  private var transformStack: [Affine] = []
  private var ops: [DrawOp] = []

  /// Draws recorded but not yet rasterized.
  public var pendingCount: Int { ops.count }

  public init(
    width: Int,
    height: Int,
    fillAlgorithm: FillAlgorithm = .default,
    transform: Affine = .identity
  ) {
    precondition(width > 0 && height > 0, "canvas must have a positive size")
    self.width = width
    self.height = height
    self.fillAlgorithm = fillAlgorithm
    self.transform = transform
    self.pixels = .allocate(capacity: width * height)
    self.pixels.initialize(repeating: [0, 0, 0, 0])
  }

  deinit {
    pixels.deallocate()
  }

  // MARK: - Transform state

  /// Pushes the current transform so a later `restoreState()` brings it back.
  public mutating func saveState() {
    transformStack.append(transform)
  }

  public mutating func restoreState() {
    guard let previous = transformStack.popLast() else { return }
    transform = previous
  }

  /// Runs `body` with the transform saved, restoring it afterwards even if `body` throws.
  public mutating func withSavedTransform<T>(_ body: (inout Canvas) throws -> T) rethrows -> T {
    saveState()
    defer { restoreState() }
    return try body(&self)
  }

  public mutating func translate(x: Float, y: Float) {
    transform.translate(x: x, y: y)
  }

  public mutating func scale(x: Float, y: Float) {
    transform.scale(x: x, y: y)
  }

  public mutating func rotate(_ angle: Angle) {
    transform.rotate(angle)
  }

  public mutating func concatenate(_ other: Affine) {
    transform = transform.multiplied(by: other)
  }

  // MARK: - Recording

  /// Records a fill of `path` with `color`. Pass `transform` to override the canvas' current
  /// matrix for this op alone; otherwise the current matrix is used.
  public mutating func draw(_ path: Path, color: Color, transform: Affine? = nil) {
    ops.append(DrawOp(path: path, color: color, transform: transform ?? self.transform))
  }

  /// Throws away every recorded op without rasterizing any of them.
  public mutating func discard() {
    ops.removeAll(keepingCapacity: true)
  }

  /// Overwrites every pixel with `color`. Rasterizes immediately: it ignores the transform and
  /// clobbers whatever is there, so ordering against recorded ops would be a lie.
  public mutating func clear(to color: Color = Color(.srgb, red: 0, green: 0, blue: 0, alpha: 0)) {
    let c = Color8(color)
    pixels.update(repeating: [c.red, c.green, c.blue, c.alpha])
  }

  // MARK: - Rasterizing

  /// Rasterizes every recorded op in record order, then clears the queue.
  public mutating func flush() {
    guard !ops.isEmpty else { return }

    var span = pixels.mutableSpan
    if self.fillAlgorithm == .scanline {
      for op in ops {
        fillScanline(path: op.path, color: op.color, pixels: &span, width: width, height: height)
      }
    } else {
      drawSparseSprips(ops: ops, pixels: &span, width: width, height: height)
    }

    ops.removeAll(keepingCapacity: true)
  }

  // MARK: - Output

  /// Flushes, then writes the pixels to `path` as a binary PPM. Flushing first so a pending draw
  /// cannot silently miss the file.
  public mutating func save(to path: String) throws {
    flush()
    try writePpm(pixels: pixels.span, width: width, height: height, to: path)

    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let ppmPath = "\(stem).ppm"

    #if !os(Windows)
      convertToPng(ppmPath: ppmPath, pngPath: "\(stem).png")
    #endif  // !os(Windows)

  }
}
