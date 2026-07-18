public struct Rect: Sendable {
    public static let zero = Rect(top: 0, left: 0, width: 0, height: 0)
    public static let unit = Rect(top: 0, left: 0, width: 1, height: 1)

    public var top: Float
    public var left: Float
    public var width: Float
    public var height: Float

    public init(
        top: Float, left: Float, width: Float, height: Float
    ) {
        self.top = top
        self.left = left
        self.width = width
        self.height = height
    }

    
    public init(
        top: Float, left: Float, bottom: Float, right: Float
    ) {
        self.top = top
        self.left = left
        self.width = right - left
        self.height = bottom - top
    }


    public init(
        topLeft: SIMD2<Float>, size: SIMD2<Float>
    ) {
        self.top = topLeft.y
        self.left = topLeft.x
        self.width = size.x
        self.height = size.y
    }

    public init(
        center: SIMD2<Float>, size: SIMD2<Float>
    ) {
        self.top = center.y - size.y / 2
        self.left = center.x - size.x / 2
        self.width = size.x
        self.height = size.y
    }

    public var right: Float {
        get {
            left + width
        }
        set {
            width = newValue - left
        }
    }

    public var bottom: Float {
        get {
            top + height
        }
        set {
            height = newValue - bottom
        }
    }

    public var center: SIMD2<Float> {
        SIMD2(left + width / 2, top + height / 2)
    }

    public var topLeft: SIMD2<Float> {
        get {
            SIMD2(left, top)
        }
        set {
            left = newValue.x
            top = newValue.y
        }
    }

    public var size: SIMD2<Float> {
        get {
            SIMD2(width, height)
        }
        set {
            width = newValue.x
            height = newValue.y
        }
    }

    public var atOrigin: Rect {
        Rect(top: 0, left: 0, width: width, height: height)
    }

    public var vertices: [4 of SIMD2<Float>] {
        [
            SIMD2(left, top),
            SIMD2(right, top),
            SIMD2(right, bottom),
            SIMD2(left, bottom),
        ]
    }

    public func padded(_ amount: Float) -> Rect {
        Rect(
            top: top - amount, left: left - amount, width: width + 2 * amount,
            height: height + 2 * amount
        )
    }

    public func offset(_ offset: SIMD2<Float>) -> Rect {
        Rect(top: top + offset.y, left: left + offset.x, width: width, height: height)
    }

    public func contains(_ position: SIMD2<Float>) -> Bool {
        let x = position.x
        let y = position.y
        return x >= left && x <= left + width && y >= top && y <= top + height
    }

    /// shared area with `other`, or `nil` when they do not overlap
    public func intersection(with other: Rect) -> Rect? {
        let top = max(self.top, other.top)
        let left = max(self.left, other.left)
        let bottom = min(self.bottom, other.bottom)
        let right = min(self.right, other.right)
        if left > right || top > bottom { return nil }
        return Rect(top: top, left: left, bottom: bottom, right: right)
    }

    public func overlap(with other: Rect) -> Bool {
        return self.left < other.right && self.right > other.left
            && self.top < other.bottom && self.bottom > other.top
    }

    public func transformBounds(_ affine: Affine) -> Rect {
        let vs = vertices
        let vt0 = affine.multiplyVector(SIMD4(lowHalf: vs[0], highHalf: SIMD2(0, 1)))
        let vt1 = affine.multiplyVector(SIMD4(lowHalf: vs[1], highHalf: SIMD2(0, 1)))
        let vt2 = affine.multiplyVector(SIMD4(lowHalf: vs[2], highHalf: SIMD2(0, 1)))
        let vt3 = affine.multiplyVector(SIMD4(lowHalf: vs[3], highHalf: SIMD2(0, 1)))
        let x1 = min(vt0.x, vt1.x, vt2.x,  vt3.x)
        let x2 = max(vt0.x, vt1.x, vt2.x,  vt3.x)
        let y1 = min(vt0.y, vt1.y, vt2.y,  vt3.y)
        let y2 = max(vt0.y, vt1.y, vt2.y,  vt3.y)
        
        return Rect(top: y1, left: x1, bottom: y2, right: x2)
    }
}


extension Rect: CustomStringConvertible {
    public var description: String {
        "Rect(\(top), \(left), \(width), \(height))"
    }
}

extension Rect: Equatable {}