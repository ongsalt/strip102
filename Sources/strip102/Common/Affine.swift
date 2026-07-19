import Foundation

extension Comparable {
    func clamped(from lowerBound: Self, to upperBound: Self) -> Self {
        max(min(upperBound, self), lowerBound)
    }
}


public enum Angle: Sendable, Equatable {
    case radians(Float)
    case degrees(Float)
    case pi(Float)

    var radians: Float {
        switch self {
        case .radians(let r): return r
        case .degrees(let d): return d * .pi / 180
        case .pi(let p): return p * .pi
        }
    }
}

public struct Affine: Sendable, Equatable {
    public var col0: SIMD4<Float>
    public var col1: SIMD4<Float>
    public var col2: SIMD4<Float>
    public var col3: SIMD4<Float>

    public static let identity = Affine(
        col0: SIMD4<Float>(1, 0, 0, 0),
        col1: SIMD4<Float>(0, 1, 0, 0),
        col2: SIMD4<Float>(0, 0, 1, 0),
        col3: SIMD4<Float>(0, 0, 0, 1)
    )

    public init(col0: SIMD4<Float>, col1: SIMD4<Float>, col2: SIMD4<Float>, col3: SIMD4<Float>) {
        self.col0 = col0
        self.col1 = col1
        self.col2 = col2
        self.col3 = col3
    }

    public init() {
        self = .identity
    }

    // MARK: - Core Multiplication

    @inline(__always)
    func multiplyVector(_ v: SIMD4<Float>) -> SIMD4<Float> {
        return (v.x * col0) + (v.y * col1) + (v.z * col2) + (v.w * col3)
    }

    /// transforms a 2D point, treating it as (x, y, 0, 1)
    @inline(__always)
    public func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
        if self == .identity { return point }
        let v = multiplyVector(SIMD4(lowHalf: point, highHalf: SIMD2(0, 1)))
        return SIMD2(v.x, v.y)
    }

    /// transforms a 2D direction, treating it as (x, y, 0, 0); translation does not apply
    @inline(__always)
    public func applyVector(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        if self == .identity { return vector }
        let v = multiplyVector(SIMD4(lowHalf: vector, highHalf: SIMD2(0, 0)))
        return SIMD2(v.x, v.y)
    }

    public func multiplied(by other: Affine) -> Affine {
        return Affine(
            col0: multiplyVector(other.col0),
            col1: multiplyVector(other.col1),
            col2: multiplyVector(other.col2),
            col3: multiplyVector(other.col3)
        )
    }

    // MARK: - Chaining Methods (Returns new Affine)

    public func scaled(x: Float, y: Float, z: Float = 1.0) -> Affine {
        let scaleMatrix = Affine(
            col0: SIMD4<Float>(x, 0, 0, 0),
            col1: SIMD4<Float>(0, y, 0, 0),
            col2: SIMD4<Float>(0, 0, z, 0),
            col3: SIMD4<Float>(0, 0, 0, 1)
        )
        return self.multiplied(by: scaleMatrix)
    }

    public func translated(x: Float, y: Float, z: Float = 0.0) -> Affine {
        let translationMatrix = Affine(
            col0: SIMD4<Float>(1, 0, 0, 0),
            col1: SIMD4<Float>(0, 1, 0, 0),
            col2: SIMD4<Float>(0, 0, 1, 0),
            col3: SIMD4<Float>(x, y, z, 1)
        )
        return self.multiplied(by: translationMatrix)
    }

    public func rotated(_ angle: Angle, axis: SIMD3<Float> = SIMD3<Float>(0, 0, 1)) -> Affine {
        let r = angle.radians
        let length = sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
        let n = axis / length

        let c = cos(r)
        let s = sin(r)
        let t = 1.0 - c

        let x = n.x
        let y = n.y
        let z = n.z

        let rotationMatrix = Affine(
            col0: SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            col1: SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            col2: SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            col3: SIMD4<Float>(0, 0, 0, 1)
        )
        return self.multiplied(by: rotationMatrix)
    }

    // MARK: - Mutating Methods (Modifies in place)

    public mutating func scale(x: Float, y: Float, z: Float = 1.0) {
        self = self.scaled(x: x, y: y, z: z)
    }

    public mutating func translate(x: Float, y: Float, z: Float = 0.0) {
        self = self.translated(x: x, y: y, z: z)
    }

    public mutating func rotate(_ angle: Angle, axis: SIMD3<Float> = SIMD3<Float>(0, 0, 1)) {
        self = self.rotated(angle, axis: axis)
    }
}

extension Affine: CustomStringConvertible {
    public var description: String {
        let cols = [col0, col1, col2, col3]
        return (0..<4).map { row in
            let vals = cols.map { String(format: "%8.3f", $0[row]) }
            return "[ \(vals.joined(separator: "  ")) ]"
        }.joined(separator: "\n")
    }
}
