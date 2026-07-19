import Foundation

public typealias Point = SIMD2<Float>

extension SIMD2 where Scalar == Float {
  @inline(__always)
  public func lerp(to other: Self, _ t: Float) -> Self {
    self + (other - self) * t
  }

  /// z-component of the 3D cross product; signed area of the parallelogram
  @inline(__always)
  public func cross(_ other: Self) -> Float {
    x * other.y - y * other.x
  }

  @inline(__always)
  public var lengthSquared: Float {
    x * x + y * y
  }
}

public enum FillRule: Sendable, Equatable {
  case nonZero
  case evenOdd
}

// MARK: - Path

/// Unlike the usual command list, a `Path` stores its segments already resolved: every segment
/// carries its own start point, so a subpath boundary is just a discontinuity between
/// `segments[i - 1].end` and `segments[i].start` (what a `moveTo` used to produce).

public struct Path: Sendable, Equatable, Identifiable {
  /// mutated only while uniquely referenced (copy-on-write), so the unsynchronized vars are safe
  private final class Storage: @unchecked Sendable {
    var segments: [PathSegment]
    var fillRule: FillRule
    /// starts true so a cache purges any entries left under this address by a freed path
    var dirty: Bool = true

    init(segments: [PathSegment], fillRule: FillRule) {
      self.segments = segments
      self.fillRule = fillRule
    }
  }

  private var storage: Storage

  /// cache key for anything derived from this path; stable across copies until one side mutates.
  /// A cache must check `dirty` before using it: same id with `dirty` set means the content changed
  public var id: ObjectIdentifier { ObjectIdentifier(storage) }

  /// set on every mutation. A cache clears it after purging the old entries for `id`
  public var dirty: Bool {
    get { storage.dirty }
    nonmutating set { storage.dirty = newValue }
  }

  public var segments: [PathSegment] {
    get { storage.segments }
    set {
      ensureUnique()
      storage.segments = newValue
      storage.dirty = true
    }
  }

  public var fillRule: FillRule {
    get { storage.fillRule }
    set {
      ensureUnique()
      storage.fillRule = newValue
      storage.dirty = true
    }
  }

  /// where the next segment starts; the pen position a command list would track
  private var currentPoint: Point
  /// where the current subpath began, i.e. what `close()` draws back to
  private var subPathStart: Point

  public init(segments: [PathSegment] = [], fillRule: FillRule = .nonZero) {
    self.storage = Storage(segments: segments, fillRule: fillRule)
    self.currentPoint = segments.last?.end ?? .zero
    self.subPathStart = segments.first?.start ?? .zero
  }

  /// value equality of the rendered content; builder state (pen position) does not participate
  public static func == (lhs: Path, rhs: Path) -> Bool {
    lhs.storage === rhs.storage
      || (lhs.storage.fillRule == rhs.storage.fillRule
        && lhs.storage.segments == rhs.storage.segments)
  }

  private mutating func ensureUnique() {
    if !isKnownUniquelyReferenced(&storage) {
      storage = Storage(segments: storage.segments, fillRule: storage.fillRule)
    }
  }

  private mutating func append(_ segment: PathSegment) {
    ensureUnique()
    storage.segments.append(segment)
    storage.dirty = true
  }

  public mutating func move(to point: Point) {
    currentPoint = point
    subPathStart = point
  }

  public mutating func line(to point: Point) {
    append(.line(Line(currentPoint, point)))
    currentPoint = point
  }

  public mutating func quad(to point: Point, control: Point) {
    append(.quadratic(QuadraticBezierCurve(start: currentPoint, control: control, end: point)))
    currentPoint = point
  }

  public mutating func cubic(to point: Point, control1: Point, control2: Point) {
    append(
      .cubic(
        CubicBezierCurve(
          start: currentPoint, control1: control1, control2: control2, end: point)))
    currentPoint = point
  }

  /// canvas-style: when the pen is not already at the arc's start, a line connects them first
  public mutating func arc(center: Point, radius: Float, startAngle: Angle, endAngle: Angle) {
    arc(Arc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle))
  }

  /// canvas-style: when the pen is not already at the arc's start, a line connects them first
  public mutating func arc(_ arc: Arc) {
    if storage.segments.isEmpty {
      move(to: arc.start)
    } else if currentPoint != arc.start {
      append(.line(Line(currentPoint, arc.start)))
    }
    append(.arc(arc))
    currentPoint = arc.end
  }

  public mutating func close() {
    if currentPoint != subPathStart {
      append(.line(Line(currentPoint, subPathStart)))
    }
    currentPoint = subPathStart
  }

  public func subPaths(transform: Affine = .identity) -> SubPathSequence {
    SubPathSequence(segments: storage.segments, transform: transform)
  }

  public func breakIntoLines(
    transform: Affine = .identity, tolerance: Float = defaultFlattenTolerance
  ) -> [Line] {
    var out: [Line] = []
    out.reserveCapacity(256)

    for subPath in subPaths(transform: transform) {
      // let area = subPath.shoelace
      // if area > 0 {
      //   subPath.reverse()
      // }
      subPath.writeLines(tolerance: tolerance, into: &out)
    }

    return out
  }
}

public struct SubPath: Sendable, Equatable {
  public var segments: [PathSegment]

  public init(segments: [PathSegment] = []) {
    self.segments = segments
  }

  /// twice the signed area; sign tells whether the subpath winds clockwise or counter-clockwise
  public var shoelace: Float {
    var area: Float = 0

    for segment in segments {
      area += segment.start.x * segment.end.y
      area -= segment.end.x * segment.start.y
    }

    return area
  }

  public mutating func reverse() {
    segments = segments.reversed().map { $0.reversed() }
  }

  public func reversed() -> SubPath {
    var copy = self
    copy.reverse()
    return copy
  }

  public func writeLines(tolerance: Float = defaultFlattenTolerance, into output: inout [Line]) {
    for segment in segments {
      segment.writeLines(tolerance: tolerance, into: &output)
    }
  }

  public func lines(tolerance: Float = defaultFlattenTolerance) -> [Line] {
    var out: [Line] = []
    writeLines(tolerance: tolerance, into: &out)
    return out
  }
}

/// Walks the segment list and cuts it into subpaths, transforming each segment on the way out.
/// A subpath ends when the next segment does not start where this one ended, or when the pen
/// comes back to the subpath's start point. Subpaths left open are closed with a line, since a
/// fill only makes sense on a closed contour.
public struct SubPathSequence: Sequence, IteratorProtocol {
  private let segments: [PathSegment]
  private let transform: Affine
  private var index: Int = 0

  init(segments: [PathSegment], transform: Affine) {
    self.segments = segments
    self.transform = transform
  }

  public mutating func next() -> SubPath? {
    guard index < segments.count else { return nil }

    let startPoint = segments[index].start
    var currentPoint = startPoint
    var out: [PathSegment] = []

    while index < segments.count {
      let segment = segments[index]
      // a gap means the old command list would have had a `moveTo` here
      if !out.isEmpty && segment.start != currentPoint { break }

      out.append(segment.transformed(by: transform))
      currentPoint = segment.end
      index += 1

      if currentPoint == startPoint { break }
    }

    if currentPoint != startPoint {
      out.append(
        .line(Line(transform.apply(currentPoint), transform.apply(startPoint))))
    }

    return SubPath(segments: out)
  }
}
