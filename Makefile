run:
	swift build -c release -Xswiftc -g
	perf record -o perf/sparse-strip.data --call-graph dwarf .build/release/strip102 tiger.svg --bench --fill sparse-strip
	perf record -o perf/banded.data --call-graph dwarf .build/release/strip102 tiger.svg --bench --fill banded-scanline
	perf record -o perf/scanline.data --call-graph dwarf .build/release/strip102 tiger.svg --bench
