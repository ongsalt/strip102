import Cstb

struct ImageWriteError: Error {
  let path: String
}

/// Writes the canvas as a PNG via stb_image_write, keeping the alpha channel, so the AA living
/// in partial coverage makes it into the file.
///
/// The canvas stores premultiplied float; PNG wants straight RGBA8, so this is where the
/// unpremultiply and the quantization happen — once per image rather than once per blend.
func writePng(
  pixels: UnsafeBufferPointer<Pixel>, width: Int, height: Int, to filename: String
) throws {
  precondition(pixels.count >= width * height, "pixel buffer smaller than the image")

  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  for i in 0..<(width * height) {
    let pixel = pixels[i]
    let alpha = pixel.w
    guard alpha > 0 else { continue }

    // straight = premultiplied / alpha, rounded and clamped into a byte
    let scale = 255 / alpha
    let straight = pixel * SIMD4(scale, scale, scale, 255) + SIMD4(repeating: 0.5)
    let clamped = straight
      .replacing(with: SIMD4.zero, where: straight .< .zero)
      .replacing(with: SIMD4(repeating: 255), where: straight .> SIMD4(repeating: 255))

    bytes[i * 4 + 0] = UInt8(clamped.x)
    bytes[i * 4 + 1] = UInt8(clamped.y)
    bytes[i * 4 + 2] = UInt8(clamped.z)
    bytes[i * 4 + 3] = UInt8(clamped.w)
  }

  let status = stbi_write_png(
    filename, Int32(width), Int32(height), 4, bytes, Int32(width * 4))
  guard status != 0 else {
    throw ImageWriteError(path: filename)
  }
}
