#!/usr/bin/env python3
"""Benchmark rendering an SVG through cairo (via librsvg), matching the
parse-once/rasterize-many pattern used by the Swift and Rust benchmarks."""

import sys
import time

import gi

gi.require_version("Rsvg", "2.0")
from gi.repository import Rsvg
import cairo

DEFAULT_ITERATIONS = 1000


def bench(filename: str, iterations: int = DEFAULT_ITERATIONS, scale: float = 1.0) -> None:
    handle = Rsvg.Handle.new_from_file(filename)
    ok, base_width, base_height = handle.get_intrinsic_size_in_pixels()
    if not ok:
        # no intrinsic pixel size (e.g. viewBox-only SVG); fall back to a default viewport
        base_width, base_height = 900, 900
    width = int(base_width * scale)
    height = int(base_height * scale)
    viewport = Rsvg.Rectangle()
    viewport.x = 0
    viewport.y = 0
    viewport.width = width
    viewport.height = height

    durations = []
    for _ in range(iterations):
        start = time.perf_counter()

        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        ctx = cairo.Context(surface)
        ctx.scale(scale, scale)
        handle.render_document(ctx, viewport)

        durations.append(time.perf_counter() - start)

    total = sum(durations)
    average = total / iterations
    minimum = min(durations)
    maximum = max(durations)

    print(
        f"bench {filename} x{iterations}: "
        f"total={total:.8f}s, avg={average * 1000:.6f}ms, "
        f"min={minimum * 1000:.6f}ms, max={maximum * 1000:.6f}ms"
    )


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "tiger.svg"
    bench(path)
