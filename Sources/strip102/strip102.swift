// The Swift Programming Language
// https://docs.swift.org/swift-book

import ArgumentParser

@main
struct strip102: ParsableCommand {
    @Argument(help: "Path to the SVG file to render.")
    var file: String

    @Flag(help: "Run the render pipeline 100 times with no file output, for benchmarking.")
    var bench = false

    @Option(name: .shortAndLong, help: "Output resolution multiplier, e.g. 2 for 2x.")
    var scale: Float = 1.0

    func validate() throws {
        guard scale > 0 else {
            throw ValidationError("--scale must be greater than 0.")
        }
    }

    func run() {
        idk()
        // if bench {
        //     benchSvg(file, scale: scale)
        // } else {
        //     importSvg(file, scale: scale)
        // }
    }

    func idk() {
        var path = Path()
        // path.quad(to: Point(100, 100), control: Point(0, 100))
        path.move(to: Point(1, 2))
        path.line(to: Point(15, 8))

        let width = 100
        let height = 100
        let pixels = UnsafeMutableBufferPointer<Pixel>
            .allocate(capacity: width * height)

        var span = pixels.mutableSpan
        fillSparseStrip(
            path: path,
            color: .red,
            pixels: &span,
            width: width,
            height: height
        )

    }
}
