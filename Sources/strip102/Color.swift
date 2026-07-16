import Foundation

// store
public struct Color: Sendable, Equatable {
  public var red: Float
  public var green: Float
  public var blue: Float
  public var alpha: Float = 1.0
  public var colorSpace: ColorSpace

  public init(
    _ colorSpace: ColorSpace = .displayP3, red: Float, green: Float, blue: Float, alpha: Float = 1.0,
  ) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
    self.colorSpace = colorSpace
  }

  public init(hex rgb: UInt32, alpha: Float = 1.0) {
    let r = Float((rgb >> 16) & 0xFF) / 255.0
    let g = Float((rgb >> 8) & 0xFF) / 255.0
    let b = Float((rgb >> 0) & 0xFF) / 255.0
    self = Color(.srgb, red: r, green: g, blue: b, alpha: 1.0)
  }

  // public static func oklch(lightness: Float, chroma: Float, hue: Float) -> Self {

  // }

  var values: (Float, Float, Float, Float) {
    (red, green, blue, alpha)
  }

  var premultiplied: Color {
    Color(
      colorSpace,
      red: red * alpha,
      green: green * alpha,
      blue: blue * alpha,
      alpha: alpha,
    )
  }

  // this should depends on working space, probably the same as what swapchain tell us
  var linearized: Color {
    func apply(_ x: Float) -> Float {
      if x <= 0.04045 {
        x / 12.92
      } else {
        pow((x + 0.055) / 1.055, 2.4)
      }
    }
    return Color(
      colorSpace,
      red: apply(red),
      green: apply(green),
      blue: apply(blue),
      alpha: alpha,
    )
  }
}

public enum ColorSpace: Sendable {
  case srgb
  case displayP3
}

public enum ColorInterpolatingSpace: UInt32, Sendable {
  case srgb = 0
  case displayP3 = 1
  case oklch = 2
  case oklab = 3
}

extension Color {
  public static let transparent = Color(red: 0, green: 0, blue: 0, alpha: 0)
  public static let black = Color(red: 0, green: 0, blue: 0)
  public static let white = Color(red: 1, green: 1, blue: 1)

  public static let red = Color(red: 1.0, green: 0.2196, blue: 0.2353)
  public static let orange = Color(red: 1.0, green: 0.5529, blue: 0.1569)
  public static let yellow = Color(red: 1.0, green: 0.8, blue: 0.0)
  public static let green = Color(red: 0.2039, green: 0.7804, blue: 0.349)
  public static let mint = Color(red: 0.0, green: 0.7843, blue: 0.702)
  public static let teal = Color(red: 0.0, green: 0.7647, blue: 0.8157)
  public static let cyan = Color(red: 0.0, green: 0.7529, blue: 0.9098)
  public static let blue = Color(red: 0.0, green: 0.5333, blue: 1.0)
  public static let indigo = Color(red: 0.3804, green: 0.3333, blue: 0.9608)
  public static let purple = Color(red: 0.7961, green: 0.1882, blue: 0.8784)
  public static let pink = Color(red: 1.0, green: 0.1765, blue: 0.3333)
  public static let brown = Color(red: 0.6745, green: 0.498, blue: 0.3686)

  public func with(alpha: Float) -> Self {
    var new = self
    new.alpha = alpha
    return new
  }
}
