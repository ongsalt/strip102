import Cstb

struct ImageWriteError: Error {
  let path: String
}

/// Writes RGBA8 pixels as a PNG via stb_image_write, keeping the alpha channel, so the AA living
/// in partial coverage makes it into the file.
func writePng(
  pixels: UnsafeBufferPointer<Pixel>, width: Int, height: Int, to filename: String
) throws {
  precondition(pixels.count >= width * height, "pixel buffer smaller than the image")

  let status = stbi_write_png(
    filename, Int32(width), Int32(height), 4, pixels.baseAddress, Int32(width * 4))
  guard status != 0 else {
    throw ImageWriteError(path: filename)
  }
}
