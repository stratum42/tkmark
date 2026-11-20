/*
 * c/compute.h - C11 SIMD and multi-threaded compute kernels
 *
 * Operates on flat C buffers (zero-copy perl5-mt SVf_PACKED_AV backing stores
 * via AvPACKED_DATA, or temporary buffers on stock Perl 5).
 *
 * Determinism invariants:
 *   - Compiled with #pragma STDC FP_CONTRACT OFF
 *   - PERL_FORCE_SCALAR=1 forces the single-threaded scalar twin
 *   - SIMD+pthread and scalar twin paths produce bit-identical output
 */
#ifndef TKMT_SCENE_COMPUTE_H
#define TKMT_SCENE_COMPUTE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Returns non-zero if PERL_FORCE_SCALAR is set to a truthy value. */
int tkmt_compute_force_scalar(void);

/* Returns default worker thread count (detected CPU cores, clamped to [1, 16]). */
int tkmt_compute_default_workers(void);

/*
 * Kernel 1: 2D N-body attractor particle step + fused instance & trail output.
 *
 * Reads and mutates x[0..n-1], y[0..n-1], vx[0..n-1], vy[0..n-1] in place.
 * Writes inst_out[0..n*4-1] as [x, y, (double)rgba_u32, size] (stride 4,
 * matching Tcl::Tk::MT::Gfx::Scene::create_instances).
 *
 * palette_u32:     256 packed RGBA8888 uint32_t entries.
 * trails_out:      optional output buffer for [x0, y0, x1, y1] segments (NULL to skip).
 * trails_cap_segs: max number of 4-double segments that fit in trails_out.
 * trail_step:      emit trail for particles with (i % trail_step == 0); 0 disables trails.
 * workers:         0 = auto, 1 = single-threaded, >1 = pthread worker count.
 *
 * Returns number of trail segments written (0 if trails disabled).
 */
size_t tkmt_step_particles_2d(
    double         *x,
    double         *y,
    double         *vx,
    double         *vy,
    double         *inst_out,
    const uint32_t *palette_u32,
    size_t          n,
    double          width,
    double          height,
    double          ax,
    double          ay,
    double          grav,
    double          dt,
    double          damp,
    double         *trails_out,
    size_t          trails_cap_segs,
    size_t          trail_step,
    int             workers
);

/*
 * Kernel 2: Mandelbrot / Julia RGBA8888 renderer with smooth continuous coloring.
 *
 * rgba_out:     output buffer of size w * h * 4 bytes (RGBA8888).
 * palette_rgba: 256 * 4 = 1024 bytes of RGBA8888 LUT.
 * w, h:         image dimensions in pixels.
 * cx, cy:       complex plane center.
 * scale:        complex plane span across image width (step = scale / w).
 * max_iter:     maximum escape iterations (>= 1).
 * is_julia:     0 = Mandelbrot (with cardioid/period-2 bulb reject), 1 = Julia.
 * jr, ji:       Julia constant c = jr + i*ji (ignored when is_julia == 0).
 * workers:      0 = auto, 1 = single-threaded, >1 = pthread worker count.
 *
 * Returns 0 on success, -1 on invalid arguments.
 */
int tkmt_render_fractal_rgba8(
    uint8_t       *rgba_out,
    const uint8_t *palette_rgba,
    uint32_t       w,
    uint32_t       h,
    double         cx,
    double         cy,
    double         scale,
    int            max_iter,
    int            is_julia,
    double         jr,
    double         ji,
    int            workers
);

#ifdef __cplusplus
}
#endif

#endif /* TKMT_SCENE_COMPUTE_H */
