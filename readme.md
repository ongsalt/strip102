# What is this
me want 2d renderer.

The algorithm is basically [vello cpu](https://github.com/linebender/vello/blob/main/sparse_strips/vello_cpu/) sparse strips.


# Benchmark

## Spare strip (our implementation, not vello)
```
bench tiger.svg x1000: total=3.52965215s, avg=3.529652ms, min=2.792255ms, max=12.024770ms
```

## Scanline
```
bench tiger.svg x1000: total=12.76478413s, avg=12.764784ms, min=12.210389ms, max=22.468483ms
```
## Cairo
```
bench tiger.svg x1000: total=13.12967282s, avg=13.129673ms, min=12.002300ms, max=19.617795ms
```

BUT this comparison is unfair cuz we dont even have a proper stroking yet. Advanced brush/paint is also non existent. And cairo also re-tessellates path every frame.

## Spec

```
CPU: AMD Ryzen 7 7730U (8 cores / 16 threads)
RAM: 16 GiB
OS: Fedora Linux 44 (Workstation Edition), kernel 7.0.12-201.fc44.x86_64
Swift version 6.3.2 (swift-6.3.2-RELEASE)
Target: x86_64-unknown-linux-gnu
```

# References
- [Spare strips](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf)
- [Flattening quadratic Béziers](https://raphlinus.github.io/graphics/curves/2019/12/23/flatten-quadbez.html)
- [Parallel vector graphics rasterization on CPU](https://gasiulis.name/parallel-rasterization-on-cpu/)
- [Fast cubic Bézier curve offsetting.
](https://gasiulis.name/cubic-curve-offsetting/)
- [The Scanline Sweeper: A Glyph Rendering Algorithm](https://www.youtube.com/watch?v=B9bztU1sTFA)



# Todo
- stroke
- correct even odd fill rule
- fix bug when some path are offscreen
- rect clip (viewport)
  - still need to calculate winding number of stuff outside of this
  - when its outside of viewport tile size can be much larger, arbitrary 
- think about arbitrary clipping
