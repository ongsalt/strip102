# Useful commands

```bash
swift build -c release -Xswiftc -g
perf record --call-graph dwarf .build/release/strip102 tiger.svg --bench
perf script | ./FlameGraph/stackcollapse-perf.pl | swift demangle | ./FlameGraph/flamegraph.pl > flame.svg

```