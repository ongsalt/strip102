# Useful commands

```bash
swift build -c release -Xswiftc -g
perf record --call-graph dwarf .build/release/strip102 tiger.svg --bench
perf script | ./FlameGraph/stackcollapse-perf.pl | swift demangle | ./FlameGraph/flamegraph.pl > flame.svg

```

# Benchmark

```
bench tiger.svg x1000: total=13.91991820s, avg=13.919918ms, min=13.522885ms, max=22.299697ms
```

A bit faster than the [rust version](https://github.com/ongsalt/strip101) but its unfair cuz the rust version offer js canvas like path recording api and store it as `Vec<PathCommand>` rather than `Vec<PathSegment>`.

and note that this is just a shitty poc there are a lot of optimization to be done (for example: [sparse strips](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Description.pdf)). we dont even have an option for stroking. 

## Spec

```
CPU: AMD Ryzen 7 7730U (8 cores / 16 threads)
RAM: 16 GiB
OS: Fedora Linux 44 (Workstation Edition), kernel 7.0.12-201.fc44.x86_64
Swift version 6.3.2 (swift-6.3.2-RELEASE)
Target: x86_64-unknown-linux-gnu
```

