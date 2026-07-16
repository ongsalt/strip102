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

// MARK: - Curves

public struct QuadraticBezierCurve: Sendable, Equatable {
  public var start: Point
  public var control: Point
  public var end: Point

  public init(start: Point, control: Point, end: Point) {
    self.start = start
    self.control = control
    self.end = end
  }

  public func sample(_ t: Float) -> Point {
    let a = start.lerp(to: control, t)
    let b = control.lerp(to: end, t)
    return a.lerp(to: b, t)
  }

  /// de Casteljau split into two curves meeting at `sample(t)`
  public func split(at t: Float) -> (QuadraticBezierCurve, QuadraticBezierCurve) {
    let a = start.lerp(to: control, t)
    let b = control.lerp(to: end, t)
    let mid = a.lerp(to: b, t)

    return (
      QuadraticBezierCurve(start: start, control: a, end: mid),
      QuadraticBezierCurve(start: mid, control: b, end: end)
    )
  }

  /// distance of the control point to the chord start..end is within `tolerance`
  public func isFlat(tolerance: Float) -> Bool {
    let chord = end - start
    let arm = control - start

    let cross = chord.cross(arm)
    return tolerance * tolerance * chord.lengthSquared >= cross * cross
  }

  /// polyline of `segments + 1` points sampled at even `t`
  public func flattenUniform(segments: Int) -> [Point] {
    let segments = max(segments, 1)
    return (0...segments).map { sample(Float($0) / Float(segments)) }
  }

  /// polyline that stays within `tolerance` of the curve
  public func flattenRecursiveSubdivision(tolerance: Float) -> [Point] {
    var points = [start]
    writeFlattened(tolerance: tolerance, into: &points)
    return points
  }

  /// appends every point after `start`, so the caller can chain segments without duplicating joints
  public func writeFlattened(tolerance: Float, into output: inout [Point]) {
    func walk(_ curve: QuadraticBezierCurve, _ depth: Int) {
      if curve.isFlat(tolerance: tolerance) || depth >= maxSubdivisionDepth {
        output.append(curve.end)
        return
      }

      let (left, right) = curve.split(at: 0.5)
      walk(left, depth + 1)
      walk(right, depth + 1)
    }

    walk(self, 0)
  }
}

public struct CubicBezierCurve: Sendable, Equatable {
  public var start: Point
  public var control1: Point
  public var control2: Point
  public var end: Point

  public init(start: Point, control1: Point, control2: Point, end: Point) {
    self.start = start
    self.control1 = control1
    self.control2 = control2
    self.end = end
  }

  public func sample(_ t: Float) -> Point {
    let a = start.lerp(to: control1, t)
    let b = control1.lerp(to: control2, t)
    let c = control2.lerp(to: end, t)

    let d = a.lerp(to: b, t)
    let e = b.lerp(to: c, t)
    return d.lerp(to: e, t)
  }

  public func split(at t: Float) -> (CubicBezierCurve, CubicBezierCurve) {
    let ab = start.lerp(to: control1, t)
    let bc = control1.lerp(to: control2, t)
    let cd = control2.lerp(to: end, t)
    let abc = ab.lerp(to: bc, t)
    let bcd = bc.lerp(to: cd, t)
    let mid = abc.lerp(to: bcd, t)  // = B(t), on the curve

    return (
      CubicBezierCurve(start: start, control1: ab, control2: abc, end: mid),
      CubicBezierCurve(start: mid, control1: bcd, control2: cd, end: end)
    )
  }

  public func isFlat(tolerance: Float) -> Bool {
    let chord = end - start

    let arm1 = abs((control1 - start).cross(chord))
    let arm2 = abs((control2 - start).cross(chord))

    let cross = max(arm1, arm2)
    return tolerance * tolerance * chord.lengthSquared >= cross * cross
  }

  /// polyline that stays within `tolerance` of the curve
  public func flattenRecursiveSubdivision(tolerance: Float) -> [Point] {
    var points = [start]
    writeFlattened(tolerance: tolerance, into: &points)
    return points
  }

  /// appends every point after `start`, so the caller can chain segments without duplicating joints
  public func writeFlattened(tolerance: Float, into output: inout [Point]) {
    func walk(_ curve: CubicBezierCurve, _ depth: Int) {
      if curve.isFlat(tolerance: tolerance) || depth >= maxSubdivisionDepth {
        output.append(curve.end)
        return
      }

      let (left, right) = curve.split(at: 0.5)
      walk(left, depth + 1)
      walk(right, depth + 1)
    }

    walk(self, 0)
  }
}

/// a cusp keeps failing the flatness test even as the chord shrinks to nothing, so cap the recursion
private let maxSubdivisionDepth = 20

public let defaultFlattenTolerance: Float = 0.5

// MARK: - Segments

public enum PathSegment: Sendable, Equatable {
  case line(Line)
  case quadratic(QuadraticBezierCurve)
  case cubic(CubicBezierCurve)

  public var start: Point {
    switch self {
    case .line(let line): line.start
    case .quadratic(let curve): curve.start
    case .cubic(let curve): curve.start
    }
  }

  public var end: Point {
    switch self {
    case .line(let line): line.end
    case .quadratic(let curve): curve.end
    case .cubic(let curve): curve.end
    }
  }

  public func reversed() -> PathSegment {
    switch self {
    case .line(let line):
      .line(Line(line.end, line.start))
    case .quadratic(let curve):
      .quadratic(
        QuadraticBezierCurve(start: curve.end, control: curve.control, end: curve.start))
    case .cubic(let curve):
      .cubic(
        CubicBezierCurve(
          start: curve.end, control1: curve.control2, control2: curve.control1, end: curve.start))
    }
  }

  public func transformed(by transform: Affine) -> PathSegment {
    switch self {
    case .line(let line):
      .line(Line(transform.apply(line.start), transform.apply(line.end)))
    case .quadratic(let curve):
      .quadratic(
        QuadraticBezierCurve(
          start: transform.apply(curve.start),
          control: transform.apply(curve.control),
          end: transform.apply(curve.end)))
    case .cubic(let curve):
      .cubic(
        CubicBezierCurve(
          start: transform.apply(curve.start),
          control1: transform.apply(curve.control1),
          control2: transform.apply(curve.control2),
          end: transform.apply(curve.end)))
    }
  }

  public func writeLines(tolerance: Float, into output: inout [Line]) {
    switch self {
    case .line(let line):
      output.append(line)
    case .quadratic(let curve):
      var points = [curve.start]
      curve.writeFlattened(tolerance: tolerance, into: &points)
      appendLines(points, into: &output)
    case .cubic(let curve):
      var points = [curve.start]
      curve.writeFlattened(tolerance: tolerance, into: &points)
      appendLines(points, into: &output)
    }
  }

  private func appendLines(_ points: [Point], into output: inout [Line]) {
    var current = points[0]
    for point in points.dropFirst() {
      output.append(Line(current, point))
      current = point
    }
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
public struct Path: Sendable, Equatable {
  public var segments: [PathSegment]
  public var fillRule: FillRule

  /// where the next segment starts; the pen position a command list would track
  private var currentPoint: Point
  /// where the current subpath began, i.e. what `close()` draws back to
  private var subPathStart: Point

  public init(segments: [PathSegment] = [], fillRule: FillRule = .nonZero) {
    self.segments = segments
    self.fillRule = fillRule
    self.currentPoint = segments.last?.end ?? .zero
    self.subPathStart = segments.first?.start ?? .zero
  }

  public mutating func move(to point: Point) {
    currentPoint = point
    subPathStart = point
  }

  public mutating func line(to point: Point) {
    segments.append(.line(Line(currentPoint, point)))
    currentPoint = point
  }

  public mutating func quad(to point: Point, control: Point) {
    segments.append(
      .quadratic(QuadraticBezierCurve(start: currentPoint, control: control, end: point)))
    currentPoint = point
  }

  public mutating func cubic(to point: Point, control1: Point, control2: Point) {
    segments.append(
      .cubic(
        CubicBezierCurve(
          start: currentPoint, control1: control1, control2: control2, end: point)))
    currentPoint = point
  }

  public mutating func close() {
    if currentPoint != subPathStart {
      segments.append(.line(Line(currentPoint, subPathStart)))
    }
    currentPoint = subPathStart
  }

  public func subPaths(transform: Affine = .identity) -> SubPathSequence {
    SubPathSequence(segments: segments, transform: transform)
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

// MARK: - Line

public struct Line: Sendable, Equatable {
  public var start: Point
  public var end: Point

  public init(_ start: Point, _ end: Point) {
    self.start = start
    self.end = end
  }

  public func sample(_ t: Float) -> Point {
    start.lerp(to: end, t)
  }

  public func split(atY y: Float) -> (Line, Line)? {
    let (a, b) = (start, end)
    let dy = b.y - a.y
    if dy == 0 {
      return nil
    }

    let t = (y - a.y) / dy
    if t < 0 || t > 1 {
      return nil
    }

    let p = Point(a.x + t * (b.x - a.x), y)
    return (Line(a, p), Line(p, b))
  }

  /// cell bounds, so its floor
  public var yBounds: (Int, Int) {
    (Int(min(start.y, end.y).rounded(.down)), Int(max(start.y, end.y).rounded(.down)))
  }

  /// cell bounds, so its floor
  public var xBounds: (Int, Int) {
    (Int(min(start.x, end.x).rounded(.down)), Int(max(start.x, end.x).rounded(.down)))
  }

  public var minX: Int {
    Int(min(start.x, end.x).rounded(.down))
  }

  /// -1 up, 1 down
  public var direction: Float {
    end.y > start.y ? 1 : -1
  }

  /// portion of the line inside the strip `startY...endY`, or `nil` if disjoint.
  /// keeps the original start-to-end direction, so winding is preserved.
  /// `startY` must be less than `endY`
  public func clipY(from startY: Float, to endY: Float) -> Line? {
    let (a, b) = (start, end)

    let dy = b.y - a.y
    if dy == 0 {
      // horizontal: wholly inside or wholly outside
      return (startY...endY).contains(a.y) ? self : nil
    }

    let ta = ((startY - a.y) / dy).clamped(from: 0, to: 1)
    let tb = ((endY - a.y) / dy).clamped(from: 0, to: 1)
    let (enter, exit) = ta <= tb ? (ta, tb) : (tb, ta)

    if exit <= enter {
      // both ends clamped to the same side: no overlap
      return nil
    }

    return Line(sample(enter), sample(exit))
  }

  /// `startX` must be less than `endX`
  public func clipX(from startX: Float, to endX: Float) -> Line? {
    let (a, b) = (start, end)

    let dx = b.x - a.x
    if dx == 0 {
      // vertical: wholly inside or wholly outside
      return (startX...endX).contains(a.x) ? self : nil
    }

    let ta = ((startX - a.x) / dx).clamped(from: 0, to: 1)
    let tb = ((endX - a.x) / dx).clamped(from: 0, to: 1)
    let (enter, exit) = ta <= tb ? (ta, tb) : (tb, ta)

    if exit <= enter {
      // both ends clamped to the same side: no overlap
      return nil
    }

    return Line(sample(enter), sample(exit))
  }

  public var bounds: Rect {
    Rect(
      top: min(start.y, end.y),
      left: min(start.x, end.x),
      bottom: max(start.y, end.y),
      right: max(start.x, end.x)
    )
  }
}
