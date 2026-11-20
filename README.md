# TkMark Studio

TkMark Studio is a small, reproducible benchmark testbed and interactive canvas runner for comparing three ways of driving the same Perl/Tk graphics workloads:

1. **`stock`**: Stock Perl 5 with GPU acceleration disabled (`TCL_TK_MT_ACCEL=off`, baseline Tcl/Tk and CPU software rasterizer).
2. **`dropin`**: Stock Perl 5 running through [`Tcl::Tk::MT`](../tcl-tk-mt) with GPU acceleration enabled (Metal on macOS, Vulkan on Linux/Windows) using standard Tk Canvas calls.
3. **`mt_gpu`**: `perl5-mt` with packed `NV`/`U8` arrays (`MT::Array`), C11 SIMD and worker-thread compute kernels (`TkMark::Compute`), and batched/instanced GPU canvas calls (`createInstances`, `createLinesBatch`, `Photo::put_rgba_packed`).

## What Runs Where

Each stack runs the same three scenes, but the division of work between Perl, C, and the GPU differs by design so you can see where time is actually spent:

- **Mandelbrot & Julia (`fractal`)**: Escape-time fractal renderer with smooth coloring, a Julia preview inset, drag-to-zoom, and scroll-wheel zoom.
  - `stock`: Pure Perl escape loops, formatted as classic Tk Photo `{#rrggbb ...}` row strings and drawn on the CPU.
  - `dropin`: Pure Perl escape loops producing RGBA bytes, uploaded to the GPU texture path.
  - `mt_gpu`: C11 NEON/SSE2 + worker-thread tile renderer (`TkMark::Compute::render_fractal_rgba8`) writing directly into a packed `U8` `MT::Array`, uploaded to the GPU via `Photo::put_rgba_packed`.
- **N-Body / Boids (`boids`)**: 20k-50k particle attractor simulation with an interactive gravity well and optional velocity trails.
  - `stock`: Pure Perl physics loop with per-item `createOval` / `coords` updates on the CPU.
  - `dropin`: Pure Perl physics loop with batched `coords` updates rendered on the GPU.
  - `mt_gpu`: C11 NEON/SSE2 + worker-thread physics and trail generation (`TkMark::Compute::step_particles_2d`) operating in place on packed `NV` `MT::Array` buffers, drawn via GPU instancing (`createInstances`) and `createLinesBatch`.
- **100k-Point Telemetry Chart (`chart`)**: Candlestick and raw-tick chart with a 12k-segment waveform trace, EMA20/EMA50/Bollinger overlays, volume histogram, pan/zoom, and crosshair.
  - All three stacks run the indicator math and waveform sampling in Perl. `stock` and `dropin` emit individual `createLine` / `createRectangle` items, whereas `mt_gpu` packs the coordinates into `NV` arrays and submits them via `createLinesBatch` and `createInstances`.

## Sample Measurements (Apple Silicon, Metal)

The table below shows one machine's measurements on macOS arm64 using the Metal backend (8 workers for `mt_gpu`), collected with:

```sh
perl bench/tkmark_compare.pl --frames=15 --fractal-size=640x480 --boids=20000 --chart-points=100000
```

| Scene | Stack | Backend | Perl | FPS | p50 (ms) | p95 (ms) | Compute (ms) | Render (ms) | vs Stock |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Fractal (640x480, iter=128) | `stock` | `software` | v5.44.0 | 1.27 | 785.25 | 823.72 | 777.17 | 7.24 | 1.00x |
| Fractal (640x480, iter=128) | `dropin` | `metal` | v5.44.0 | 1.54 | 650.13 | 682.85 | 648.05 | 1.28 | 1.21x |
| Fractal (640x480, iter=128) | `mt_gpu` | `metal` | v5.40.2 (mt) | 439.09 | 2.23 | 2.64 | 1.28 | 0.99 | 344.38x |
| Boids (20k) | `stock` | `software` | v5.44.0 | 22.56 | 44.53 | 45.04 | 11.99 | 32.31 | 1.00x |
| Boids (20k) | `dropin` | `metal` | v5.44.0 | 33.60 | 29.61 | 30.42 | 11.62 | 18.12 | 1.49x |
| Boids (20k) | `mt_gpu` | `metal` | v5.40.2 (mt) | 439.21 | 2.20 | 3.20 | 0.07 | 2.19 | 19.47x |
| Chart (100k pts) | `stock` | `software` | v5.44.0 | 12.54 | 80.72 | 83.67 | 6.48 | 72.83 | 1.00x |
| Chart (100k pts) | `dropin` | `metal` | v5.44.0 | 12.37 | 81.25 | 83.70 | 6.69 | 73.67 | 0.99x |
| Chart (100k pts) | `mt_gpu` | `metal` | v5.40.2 (mt) | 84.97 | 11.60 | 12.62 | 8.55 | 2.17 | 6.78x |

On the same machine at 50k particles (`--boids=50000 --frames=15`, 800x600, Metal, 8 workers), `mt_gpu` measured 253.16 FPS (`p50=3.82 ms`, `compute=0.12 ms`, `render=3.81 ms`).

Numbers will vary with CPU, GPU, driver, Perl build flags, and scene parameters. Notice in particular how `Compute (ms)` and `Render (ms)` separate the two effects: `fractal` and `boids` move both compute (into C11/SIMD + threads) and drawing (into batched GPU calls), while `chart` keeps compute in Perl and only changes how geometry is submitted to the renderer.

## Building `TkMark::Compute`

`TkMark::Compute` is a standalone C11 XS module (`PERL_XS_THREADSAFE`) targeting macOS, Linux, and Win64. Under `perl5-mt` it reads and writes `SVf_PACKED_AV` backing stores directly; under stock Perl 5 it falls back to standard `av_fetch`/`sv_set*` loops. Setting `PERL_FORCE_SCALAR=1` runs a single-threaded scalar reference path that produces bit-identical output to the SIMD+threaded path.

### Under `perl5-mt` (enables `mt_gpu`)

```sh
PERL=../perl5-mt/perl
PERL_LIB=../perl5-mt/lib

"$PERL" -I"$PERL_LIB" Makefile.PL
make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)
```

### Under Stock Perl 5

```sh
perl Makefile.PL
make -j$(sysctl -n hw.ncpu 2>/dev/null || nproc)
```

## Locating `Tcl::Tk::MT`

`tkmark.pl`, `bench/tkmark_compare.pl`, and the test suite look for `Tcl::Tk::MT` in `@INC` first (when installed), then fall back to `$ENV{TCL_TK_MT_DIR}/blib/{arch,lib}` or a sibling `../tcl-tk-mt/blib/{arch,lib}` checkout. Set `TCL_TK_MT_NO_REPO_BLIB=1` to disable the sibling checkout fallback.

## Running `tkmark.pl`

### Interactive GUI

```sh
# perl5-mt (auto-selects mt_gpu when a GPU backend and packed arrays are available)
"$PERL" -I"$PERL_LIB" -Iblib/arch -Iblib/lib -Ilib tkmark.pl

# Stock Perl 5, drop-in GPU mode
perl -Iblib/arch -Iblib/lib -Ilib tkmark.pl --stack=dropin

# Stock Perl 5, unaccelerated baseline
TCL_TK_MT_ACCEL=off perl -Iblib/arch -Iblib/lib -Ilib tkmark.pl --stack=stock
```

### Headless Single-Scene Run

```sh
"$PERL" -I"$PERL_LIB" -Iblib/arch -Iblib/lib -Ilib \
    tkmark.pl --headless --scene=boids --stack=mt_gpu --frames=30 --boids=20000 \
    --json --snapshot=/tmp/boids.ppm
```

### `tkmark.pl` CLI Flags

- `--stack=auto|stock|dropin|mt_gpu`: Execution stack (default: `auto`).
- `--scene=fractal|boids|chart|all`: Scene to run (`all` is valid with `--headless`; default: `fractal`).
- `--headless`: Run offscreen benchmark without a GUI `MainLoop`.
- `--frames=N`: Measured frames per scene in headless mode (default: `30`).
- `--width=W`, `--height=H`: Viewport dimensions in pixels (default: `800x600`).
- `--count=N`: Generic item-count override for `boids` or `chart`.
- `--boids=N`: Boids particle count (default: `20000`).
- `--chart-points=N`: Chart telemetry point count (default: `100000`).
- `--max-iter=N`: Fractal escape iteration limit (default: `128`).
- `--workers=N`: Worker count for `mt_gpu` (default: `0` = auto).
- `--backend=auto|metal|vulkan|software|off`: Explicit graphics backend override.
- `--cpan-tcltk`: In interactive `stock` mode, prefer CPAN `Tcl::Tk` if installed.
- `--json`: Emit machine-readable JSON in headless mode.
- `--snapshot=PATH`: Write a binary PPM (`P6`) snapshot of the final frame.
- `--snapshot-dir=DIR`: Write `<DIR>/<scene>_<stack>.ppm` snapshots.
- `--auto-exit-ms=N`: Automatically close the interactive window after `N` ms.

## Automated 3-Stack Benchmark (`bench/tkmark_compare.pl`)

```sh
perl bench/tkmark_compare.pl \
    --stock-perl=perl \
    --stock-blib=/tmp/tkmark-blib-stock \
    --mt-perl=../perl5-mt/perl \
    --mt-lib=../perl5-mt/lib \
    --tcl-tk-mt-dir=../tcl-tk-mt \
    --frames=20 \
    --fractal-size=640x480 \
    --boids=20000 \
    --chart-points=100000 \
    --snapshot-dir=/tmp/tkmark-snapshots
```

### `bench/tkmark_compare.pl` Options

- `--stock-perl=PATH`: Stock Perl 5 binary (default: `/opt/homebrew/bin/perl` if executable, else `$^X`).
- `--stock-blib=DIR`: Separate `blib/` built for stock Perl (for side-by-side runs).
- `--mt-perl=PATH`: `perl5-mt` binary (default: `$ENV{PERL5_MT}`, sibling `../perl5-mt/perl`, or `$^X`).
- `--mt-lib=DIR`: `perl5-mt` library directory (default: `$ENV{PERL5_MT_LIB}` or sibling `../perl5-mt/lib`).
- `--mt-blib=DIR`: `blib/` built for `perl5-mt` (default: `<repo>/blib`).
- `--tcl-tk-mt-dir=DIR`: Path to `tcl-tk-mt` checkout (default: `$ENV{TCL_TK_MT_DIR}` or `../tcl-tk-mt`).
- `--accel=metal|vulkan|auto|software`: GPU backend for `dropin` and `mt_gpu`.
- `--frames=N`: Measured frames per scene (default: `20`).
- `--fractal-size=WxH`: Fractal resolution (default: `640x480`).
- `--boids=N`: Boids particle count (default: `20000`).
- `--chart-points=N`: Telemetry chart points (default: `100000`).
- `--scenes=LIST`, `--stacks=LIST`: Comma-separated subsets of scenes or stacks.
- `--snapshot-dir=DIR`: Save PPM visual comparison snapshots (`<scene>_<stack>.ppm`).
- `--json-out=PATH`: Write full raw JSON results to a file.

## Test Suite

```sh
# Full test suite under perl5-mt
PERL5LIB="$PERL_LIB" "$PERL" -S prove -b -v t/

# Scalar-twin determinism check
PERL_FORCE_SCALAR=1 PERL5LIB="$PERL_LIB" "$PERL" -S prove -b -v t/01_compute_kernels.t
```

## Acknowledgements

TkMark Studio rests on decades of work by the Perl 5 Porters and the Tcl/Tk community, as well as the authors of CPAN's `Tcl::Tk` bindings.

## License

This software is available under the same terms as Perl 5 itself.
