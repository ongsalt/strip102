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

    // straight = premultiplied / alpha
    let working = unpack(pixel)
    let scale = 255 / working.w
    let straight = packBytes(working * PixelF(scale, scale, scale, 1))

    bytes[i * 4 + 0] = straight.x
    bytes[i * 4 + 1] = straight.y
    bytes[i * 4 + 2] = straight.z
    bytes[i * 4 + 3] = straight.w
  }

  let status = stbi_write_png(
    filename, Int32(width), Int32(height), 4, bytes, Int32(width * 4))
  guard status != 0 else {
    throw ImageWriteError(path: filename)
  }
}
