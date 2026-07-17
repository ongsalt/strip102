// The Swift Programming Language
// https://docs.swift.org/swift-book

import ArgumentParser

extension FillAlgorithm: ExpressibleByArgument {}

@main
struct strip102: ParsableCommand {
    @Argument(help: "Path to the SVG file to render.")
    var file: String

    @Flag(help: "Run the render pipeline 100 times with no file output, for benchmarking.")
    var bench = false

    @Option(name: .shortAndLong, help: "Output resolution multiplier, e.g. 2 for 2x.")
    var scale: Float = 1.0

    @Option(
        name: [.customShort("f"), .customLong("fill")], help: "Fill algorithm to rasterize with.")
    var fillAlgorithm: FillAlgorithm = .default

    func validate() throws {
        guard scale > 0 else {
            throw ValidationError("--scale must be greater than 0.")
        }
    }

    func run() {
        if file == "triangle" {
            idk(algorithm: fillAlgorithm)
        } else {
            if bench {
                benchSvg(file, scale: scale, algorithm: fillAlgorithm)
            } else {
                importSvg(file, scale: scale, algorithm: fillAlgorithm)
            }
        }
    }

    func idk(algorithm: FillAlgorithm) {
        var path = Path()
        // path.quad(to: Point(100, 100), control: Point(0, 100))
        path.move(to: Point(1, 2))
        path.line(to: Point(15, 8))
        path.line(to: Point(15, 2))

        var canvas = Canvas(width: 100, height: 100, fillAlgorithm: algorithm)
        canvas.draw(path, color: .red)
        canvas.flush()
        try! canvas.save(to: "idk.pam")
    }
}
