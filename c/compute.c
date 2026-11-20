/*
 * c/compute.c - C11 SIMD and multi-threaded compute kernels
 *
 * Implements:
 *   1. tkmt_step_particles_2d    (N-body attractor physics + fused instance/trail gen)
 *   2. tkmt_render_fractal_rgba8 (Mandelbrot & Julia smooth RGBA8888 renderer)
 *
 * Determinism invariants:
 *   - #pragma STDC FP_CONTRACT OFF (Clang/MSVC) / -std=c11 (GCC) disables FMA contraction
 *   - NEON float64x2_t (aarch64) and SSE2 __m128d (x86_64) match the scalar IEEE-754 op order
 *   - PERL_FORCE_SCALAR=1 forces the single-threaded scalar twin
 *   - Persistent worker pool avoids per-frame thread creation overhead
 */

#if !defined(__GNUC__) || defined(__clang__)
#  pragma STDC FP_CONTRACT OFF
#endif

#include "tkmt_thread.h"
#include "compute.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__)
#  include <arm_neon.h>
#  define TKMT_HAVE_NEON_F64 1
#else
#  define TKMT_HAVE_NEON_F64 0
#endif

#if defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64)
#  include <emmintrin.h>
#  define TKMT_HAVE_SSE2_F64 1
#else
#  define TKMT_HAVE_SSE2_F64 0
#endif

/* =========================================================================
 * Environment & CPU core detection
 * ========================================================================= */

static int ascii_strcasecmp(const char *a, const char *b) {
    if (!a || !b) return (a == b) ? 0 : (a ? 1 : -1);
    while (*a && *b) {
        int ca = tolower((unsigned char)*a);
        int cb = tolower((unsigned char)*b);
        if (ca != cb) return ca - cb;
        a++;
        b++;
    }
    return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

int tkmt_compute_force_scalar(void) {
    const char *val = getenv("PERL_FORCE_SCALAR");
    if (!val || !*val) return 0;
    if (strcmp(val, "0") == 0) return 0;
    if (ascii_strcasecmp(val, "false") == 0) return 0;
    if (ascii_strcasecmp(val, "no") == 0) return 0;
    if (ascii_strcasecmp(val, "off") == 0) return 0;
    return 1;
}

int tkmt_compute_default_workers(void) {
    int cores = tkmt_cpu_count();
    if (cores < 1)  cores = 1;
    if (cores > 16) cores = 16;
    return cores;
}

/* =========================================================================
 * Persistent worker thread pool (POSIX / Win32)
 * ========================================================================= */

#define TKMT_MAX_POOL_WORKERS 16

typedef void (*tkmt_job_fn_t)(void *ctx, int worker_id, int total_workers);

typedef struct tkmt_pool_state {
    tkmt_static_mutex_t dispatch_lock; /* serializes concurrent dispatch calls */
    tkmt_mutex_t        work_lock;
    tkmt_cond_t         work_cv;
    tkmt_cond_t         done_cv;
    int                 sync_inited;

    tkmt_thread_t       threads[TKMT_MAX_POOL_WORKERS];
    int                 num_threads;   /* spawned helper threads (excludes caller) */
    int                 shutdown;
    int                 atexit_reg;
    uint64_t            owner_pid;

    /* Current batch state */
    uint64_t            generation;
    tkmt_job_fn_t       fn;
    void               *ctx;
    int                 active_helpers; /* helpers participating in this batch */
    int                 total_workers;  /* active_helpers + 1 (caller) */
    int                 helpers_done;
} tkmt_pool_state_t;

static tkmt_pool_state_t g_pool = {
    .dispatch_lock  = TKMT_STATIC_MUTEX_INIT,
    .sync_inited    = 0,
    .num_threads    = 0,
    .shutdown       = 0,
    .atexit_reg     = 0,
    .owner_pid      = 0,
    .generation     = 0,
    .fn             = NULL,
    .ctx            = NULL,
    .active_helpers = 0,
    .total_workers  = 1,
    .helpers_done   = 0,
};

typedef struct tkmt_helper_arg {
    int helper_idx; /* 0 .. TKMT_MAX_POOL_WORKERS-1 -> worker_id = helper_idx + 1 */
} tkmt_helper_arg_t;

static tkmt_helper_arg_t g_helper_args[TKMT_MAX_POOL_WORKERS];

static tkmt_thread_ret_t TKMT_THREAD_CALL pool_worker_main(void *arg) {
    int helper_idx = ((tkmt_helper_arg_t *)arg)->helper_idx;
    int worker_id  = helper_idx + 1;
    uint64_t seen_gen = 0;

    tkmt_mutex_lock(&g_pool.work_lock);
    for (;;) {
        while (!g_pool.shutdown && g_pool.generation == seen_gen) {
            tkmt_cond_wait(&g_pool.work_cv, &g_pool.work_lock);
        }
        if (g_pool.shutdown) {
            tkmt_mutex_unlock(&g_pool.work_lock);
            TKMT_THREAD_RETURN_ZERO;
        }
        seen_gen = g_pool.generation;
        int participating = (helper_idx < g_pool.active_helpers);
        tkmt_job_fn_t fn  = g_pool.fn;
        void *ctx         = g_pool.ctx;
        int total         = g_pool.total_workers;
        tkmt_mutex_unlock(&g_pool.work_lock);

        if (participating && fn) {
            fn(ctx, worker_id, total);
        }

        tkmt_mutex_lock(&g_pool.work_lock);
        if (participating) {
            g_pool.helpers_done++;
            if (g_pool.helpers_done >= g_pool.active_helpers) {
                tkmt_cond_signal(&g_pool.done_cv);
            }
        }
    }
}

static void pool_atexit_shutdown(void) {
    if (!g_pool.sync_inited || g_pool.owner_pid != tkmt_process_id()) return;
    tkmt_mutex_lock(&g_pool.work_lock);
    int n = g_pool.num_threads;
    if (n <= 0 || g_pool.shutdown) {
        tkmt_mutex_unlock(&g_pool.work_lock);
        return;
    }
    g_pool.shutdown = 1;
    tkmt_cond_broadcast(&g_pool.work_cv);
    tkmt_mutex_unlock(&g_pool.work_lock);

    for (int i = 0; i < n; i++) {
        tkmt_thread_join(g_pool.threads[i]);
    }
    g_pool.num_threads = 0;
}

static void pool_ensure_helpers_locked(int need_helpers) {
    uint64_t me = tkmt_process_id();
    if (!g_pool.sync_inited || (g_pool.owner_pid != 0 && g_pool.owner_pid != me)) {
        /* First init or post-fork in child process: initialize sync primitives cleanly */
        tkmt_mutex_init(&g_pool.work_lock);
        tkmt_cond_init(&g_pool.work_cv);
        tkmt_cond_init(&g_pool.done_cv);
        g_pool.sync_inited = 1;
        g_pool.num_threads = 0;
        g_pool.shutdown    = 0;
        g_pool.generation  = 0;
        g_pool.owner_pid   = me;
    }
    if (g_pool.owner_pid == 0) {
        g_pool.owner_pid = me;
    }
    if (!g_pool.atexit_reg) {
        atexit(pool_atexit_shutdown);
        g_pool.atexit_reg = 1;
    }
    if (need_helpers > TKMT_MAX_POOL_WORKERS) {
        need_helpers = TKMT_MAX_POOL_WORKERS;
    }
    while (g_pool.num_threads < need_helpers) {
        int idx = g_pool.num_threads;
        g_helper_args[idx].helper_idx = idx;
        if (tkmt_thread_create(&g_pool.threads[idx], pool_worker_main, &g_helper_args[idx]) != 0) {
            break;
        }
        g_pool.num_threads++;
    }
}

static void pool_dispatch(int workers, tkmt_job_fn_t fn, void *ctx) {
    if (workers <= 1) {
        fn(ctx, 0, 1);
        return;
    }
    if (workers > TKMT_MAX_POOL_WORKERS + 1) {
        workers = TKMT_MAX_POOL_WORKERS + 1;
    }

    tkmt_static_mutex_lock(&g_pool.dispatch_lock);
    int want_helpers = workers - 1;
    pool_ensure_helpers_locked(want_helpers);

    int active_helpers = (want_helpers <= g_pool.num_threads) ? want_helpers : g_pool.num_threads;
    int total_workers  = active_helpers + 1;

    if (active_helpers <= 0) {
        tkmt_static_mutex_unlock(&g_pool.dispatch_lock);
        fn(ctx, 0, 1);
        return;
    }

    tkmt_mutex_lock(&g_pool.work_lock);
    g_pool.fn             = fn;
    g_pool.ctx            = ctx;
    g_pool.active_helpers = active_helpers;
    g_pool.total_workers  = total_workers;
    g_pool.helpers_done   = 0;
    g_pool.generation++;
    tkmt_cond_broadcast(&g_pool.work_cv);
    tkmt_mutex_unlock(&g_pool.work_lock);

    /* Caller executes worker_id 0 directly */
    fn(ctx, 0, total_workers);

    /* Wait for helper threads to finish */
    tkmt_mutex_lock(&g_pool.work_lock);
    while (g_pool.helpers_done < active_helpers) {
        tkmt_cond_wait(&g_pool.done_cv, &g_pool.work_lock);
    }
    tkmt_mutex_unlock(&g_pool.work_lock);

    tkmt_static_mutex_unlock(&g_pool.dispatch_lock);
}

/* =========================================================================
 * Kernel 1: tkmt_step_particles_2d
 * ========================================================================= */

typedef struct particles_ctx {
    double       *x;
    double       *y;
    double       *vx;
    double       *vy;
    double       *inst_out;
    double        pal_d[256];
    size_t        n;
    double        width;
    double        height;
    double        ax;
    double        ay;
    double        grav;
    double        dt;
    double        damp;
    double       *trails_out;
    size_t        trails_cap_segs;
    size_t        trail_step;
    int           force_scalar;
} particles_ctx_t;

static inline void particle_emit_inst_and_trail(
    const particles_ctx_t *c,
    size_t i,
    double px,
    double py,
    double nvx,
    double nvy,
    double spd2)
{
    int cidx = (int)(spd2 * 6.5);
    if (cidx < 0)   cidx = 0;
    if (cidx > 255) cidx = 255;
    double sz = (spd2 > 18.0) ? 3.2 : 2.2;

    size_t o = i * 4u;
    c->inst_out[o + 0u] = px;
    c->inst_out[o + 1u] = py;
    c->inst_out[o + 2u] = c->pal_d[cidx];
    c->inst_out[o + 3u] = sz;

    if (c->trails_out && c->trail_step > 0u && (i % c->trail_step) == 0u) {
        size_t tidx = i / c->trail_step;
        if (tidx < c->trails_cap_segs) {
            size_t to = tidx * 4u;
            c->trails_out[to + 0u] = px - (nvx * 2.5);
            c->trails_out[to + 1u] = py - (nvy * 2.5);
            c->trails_out[to + 2u] = px;
            c->trails_out[to + 3u] = py;
        }
    }
}

static void step_particles_scalar_range(const particles_ctx_t *c, size_t start, size_t end) {
    double *x  = c->x;
    double *y  = c->y;
    double *vx = c->vx;
    double *vy = c->vy;

    const double ax     = c->ax;
    const double ay     = c->ay;
    const double grav   = c->grav;
    const double dt     = c->dt;
    const double damp   = c->damp;
    const double width  = c->width;
    const double height = c->height;
    const double soft   = 225.0;

    for (size_t i = start; i < end; i++) {
        double px = x[i];
        double py = y[i];
        double dx = ax - px;
        double dy = ay - py;
        double d2 = ((dx * dx) + (dy * dy)) + soft;
        double f  = grav / d2;

        double nvx = (vx[i] + (dx * f)) * damp;
        double nvy = (vy[i] + (dy * f)) * damp;
        px = px + (nvx * dt);
        py = py + (nvy * dt);

        if (width > 0.0) {
            if (px < 0.0)        px = px + width;
            else if (px >= width) px = px - width;
        }
        if (height > 0.0) {
            if (py < 0.0)         py = py + height;
            else if (py >= height) py = py - height;
        }

        x[i]  = px;
        y[i]  = py;
        vx[i] = nvx;
        vy[i] = nvy;

        double spd2 = (nvx * nvx) + (nvy * nvy);
        particle_emit_inst_and_trail(c, i, px, py, nvx, nvy, spd2);
    }
}

#if TKMT_HAVE_NEON_F64
static void step_particles_neon_range(const particles_ctx_t *c, size_t start, size_t end) {
    double *x  = c->x;
    double *y  = c->y;
    double *vx = c->vx;
    double *vy = c->vy;

    const float64x2_t vax   = vdupq_n_f64(c->ax);
    const float64x2_t vay   = vdupq_n_f64(c->ay);
    const float64x2_t vgrav = vdupq_n_f64(c->grav);
    const float64x2_t vdt   = vdupq_n_f64(c->dt);
    const float64x2_t vdamp = vdupq_n_f64(c->damp);
    const float64x2_t vw    = vdupq_n_f64(c->width);
    const float64x2_t vh    = vdupq_n_f64(c->height);
    const float64x2_t vsoft = vdupq_n_f64(225.0);
    const float64x2_t vzero = vdupq_n_f64(0.0);
    const int wrap_w = (c->width  > 0.0);
    const int wrap_h = (c->height > 0.0);

    size_t i = start;
    for (; i + 1u < end; i += 2u) {
        float64x2_t vpx = vld1q_f64(x + i);
        float64x2_t vpy = vld1q_f64(y + i);
        float64x2_t vvx = vld1q_f64(vx + i);
        float64x2_t vvy = vld1q_f64(vy + i);

        float64x2_t vdx = vsubq_f64(vax, vpx);
        float64x2_t vdy = vsubq_f64(vay, vpy);
        float64x2_t vd2 = vaddq_f64(vaddq_f64(vmulq_f64(vdx, vdx), vmulq_f64(vdy, vdy)), vsoft);
        float64x2_t vf  = vdivq_f64(vgrav, vd2);

        float64x2_t vnvx = vmulq_f64(vaddq_f64(vvx, vmulq_f64(vdx, vf)), vdamp);
        float64x2_t vnvy = vmulq_f64(vaddq_f64(vvy, vmulq_f64(vdy, vf)), vdamp);
        vpx = vaddq_f64(vpx, vmulq_f64(vnvx, vdt));
        vpy = vaddq_f64(vpy, vmulq_f64(vnvy, vdt));

        if (wrap_w) {
            uint64x2_t lt0 = vcltq_f64(vpx, vzero);
            uint64x2_t gew = vcgeq_f64(vpx, vw);
            vpx = vbslq_f64(lt0, vaddq_f64(vpx, vw), vbslq_f64(gew, vsubq_f64(vpx, vw), vpx));
        }
        if (wrap_h) {
            uint64x2_t lt0 = vcltq_f64(vpy, vzero);
            uint64x2_t geh = vcgeq_f64(vpy, vh);
            vpy = vbslq_f64(lt0, vaddq_f64(vpy, vh), vbslq_f64(geh, vsubq_f64(vpy, vh), vpy));
        }

        vst1q_f64(x + i, vpx);
        vst1q_f64(y + i, vpy);
        vst1q_f64(vx + i, vnvx);
        vst1q_f64(vy + i, vnvy);

        float64x2_t vspd2 = vaddq_f64(vmulq_f64(vnvx, vnvx), vmulq_f64(vnvy, vnvy));

        particle_emit_inst_and_trail(
            c, i,
            vgetq_lane_f64(vpx, 0), vgetq_lane_f64(vpy, 0),
            vgetq_lane_f64(vnvx, 0), vgetq_lane_f64(vnvy, 0),
            vgetq_lane_f64(vspd2, 0));
        particle_emit_inst_and_trail(
            c, i + 1u,
            vgetq_lane_f64(vpx, 1), vgetq_lane_f64(vpy, 1),
            vgetq_lane_f64(vnvx, 1), vgetq_lane_f64(vnvy, 1),
            vgetq_lane_f64(vspd2, 1));
    }

    if (i < end) {
        step_particles_scalar_range(c, i, end);
    }
}
#elif TKMT_HAVE_SSE2_F64
static void step_particles_sse2_range(const particles_ctx_t *c, size_t start, size_t end) {
    double *x  = c->x;
    double *y  = c->y;
    double *vx = c->vx;
    double *vy = c->vy;

    const __m128d vax   = _mm_set1_pd(c->ax);
    const __m128d vay   = _mm_set1_pd(c->ay);
    const __m128d vgrav = _mm_set1_pd(c->grav);
    const __m128d vdt   = _mm_set1_pd(c->dt);
    const __m128d vdamp = _mm_set1_pd(c->damp);
    const __m128d vw    = _mm_set1_pd(c->width);
    const __m128d vh    = _mm_set1_pd(c->height);
    const __m128d vsoft = _mm_set1_pd(225.0);
    const __m128d vzero = _mm_setzero_pd();
    const int wrap_w = (c->width  > 0.0);
    const int wrap_h = (c->height > 0.0);

    size_t i = start;
    for (; i + 1u < end; i += 2u) {
        __m128d vpx = _mm_loadu_pd(x + i);
        __m128d vpy = _mm_loadu_pd(y + i);
        __m128d vvx = _mm_loadu_pd(vx + i);
        __m128d vvy = _mm_loadu_pd(vy + i);

        __m128d vdx = _mm_sub_pd(vax, vpx);
        __m128d vdy = _mm_sub_pd(vay, vpy);
        __m128d vd2 = _mm_add_pd(_mm_add_pd(_mm_mul_pd(vdx, vdx), _mm_mul_pd(vdy, vdy)), vsoft);
        __m128d vf  = _mm_div_pd(vgrav, vd2);

        __m128d vnvx = _mm_mul_pd(_mm_add_pd(vvx, _mm_mul_pd(vdx, vf)), vdamp);
        __m128d vnvy = _mm_mul_pd(_mm_add_pd(vvy, _mm_mul_pd(vdy, vf)), vdamp);
        vpx = _mm_add_pd(vpx, _mm_mul_pd(vnvx, vdt));
        vpy = _mm_add_pd(vpy, _mm_mul_pd(vnvy, vdt));

        if (wrap_w) {
            __m128d lt0  = _mm_cmplt_pd(vpx, vzero);
            __m128d gew  = _mm_cmpge_pd(vpx, vw);
            __m128d subw = _mm_or_pd(_mm_and_pd(gew, _mm_sub_pd(vpx, vw)), _mm_andnot_pd(gew, vpx));
            vpx = _mm_or_pd(_mm_and_pd(lt0, _mm_add_pd(vpx, vw)), _mm_andnot_pd(lt0, subw));
        }
        if (wrap_h) {
            __m128d lt0  = _mm_cmplt_pd(vpy, vzero);
            __m128d geh  = _mm_cmpge_pd(vpy, vh);
            __m128d subh = _mm_or_pd(_mm_and_pd(geh, _mm_sub_pd(vpy, vh)), _mm_andnot_pd(geh, vpy));
            vpy = _mm_or_pd(_mm_and_pd(lt0, _mm_add_pd(vpy, vh)), _mm_andnot_pd(lt0, subh));
        }

        _mm_storeu_pd(x + i, vpx);
        _mm_storeu_pd(y + i, vpy);
        _mm_storeu_pd(vx + i, vnvx);
        _mm_storeu_pd(vy + i, vnvy);

        __m128d vspd2 = _mm_add_pd(_mm_mul_pd(vnvx, vnvx), _mm_mul_pd(vnvy, vnvy));

        double px_a[2], py_a[2], nvx_a[2], nvy_a[2], spd2_a[2];
        _mm_storeu_pd(px_a, vpx);
        _mm_storeu_pd(py_a, vpy);
        _mm_storeu_pd(nvx_a, vnvx);
        _mm_storeu_pd(nvy_a, vnvy);
        _mm_storeu_pd(spd2_a, vspd2);

        particle_emit_inst_and_trail(c, i,      px_a[0], py_a[0], nvx_a[0], nvy_a[0], spd2_a[0]);
        particle_emit_inst_and_trail(c, i + 1u, px_a[1], py_a[1], nvx_a[1], nvy_a[1], spd2_a[1]);
    }

    if (i < end) {
        step_particles_scalar_range(c, i, end);
    }
}
#endif

static void particles_worker_fn(void *vctx, int worker_id, int total_workers) {
    const particles_ctx_t *c = (const particles_ctx_t *)vctx;
    /* Align chunks to 8 doubles (64 bytes) to avoid false sharing */
    size_t n = c->n;
    size_t blocks = (n + 7u) / 8u;
    size_t b0 = (blocks * (size_t)worker_id) / (size_t)total_workers;
    size_t b1 = (blocks * (size_t)(worker_id + 1)) / (size_t)total_workers;
    size_t start = b0 * 8u;
    size_t end   = b1 * 8u;
    if (start > n) start = n;
    if (end   > n) end   = n;
    if (start >= end) return;

    if (c->force_scalar) {
        step_particles_scalar_range(c, start, end);
        return;
    }

#if TKMT_HAVE_NEON_F64
    step_particles_neon_range(c, start, end);
#elif TKMT_HAVE_SSE2_F64
    step_particles_sse2_range(c, start, end);
#else
    step_particles_scalar_range(c, start, end);
#endif
}

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
    int             workers)
{
    if (!x || !y || !vx || !vy || !inst_out || !palette_u32 || n == 0u) {
        return 0u;
    }

    int force_scalar = tkmt_compute_force_scalar();

    particles_ctx_t ctx;
    ctx.x               = x;
    ctx.y               = y;
    ctx.vx              = vx;
    ctx.vy              = vy;
    ctx.inst_out        = inst_out;
    ctx.n               = n;
    ctx.width           = width;
    ctx.height          = height;
    ctx.ax              = ax;
    ctx.ay              = ay;
    ctx.grav            = grav;
    ctx.dt              = dt;
    ctx.damp            = damp;
    ctx.trails_out      = (trails_out && trails_cap_segs > 0u && trail_step > 0u) ? trails_out : NULL;
    ctx.trails_cap_segs = trails_cap_segs;
    ctx.trail_step      = trail_step;
    ctx.force_scalar    = force_scalar;

    for (int i = 0; i < 256; i++) {
        ctx.pal_d[i] = (double)palette_u32[i];
    }

    int use_workers;
    if (force_scalar) {
        use_workers = 1;
    } else if (workers <= 0) {
        use_workers = (n < 1024u) ? 1 : tkmt_compute_default_workers();
    } else {
        use_workers = workers;
    }
    if ((size_t)use_workers > (n + 7u) / 8u) {
        use_workers = (int)((n + 7u) / 8u);
        if (use_workers < 1) use_workers = 1;
    }

    pool_dispatch(use_workers, particles_worker_fn, &ctx);

    if (ctx.trails_out && trail_step > 0u) {
        size_t total_segs = (n + trail_step - 1u) / trail_step;
        return (total_segs < trails_cap_segs) ? total_segs : trails_cap_segs;
    }
    return 0u;
}

/* =========================================================================
 * Kernel 2: tkmt_render_fractal_rgba8
 * ========================================================================= */

typedef struct fractal_ctx {
    uint8_t        *rgba_out;
    const uint8_t  *palette_rgba;
    uint32_t        w;
    uint32_t        h;
    double          x_origin;
    double          y_origin;
    double          step;
    double          inv_ln2;
    int             max_iter;
    int             is_julia;
    double          jr;
    double          ji;
    int             force_scalar;
    _Atomic uint32_t next_row;
} fractal_ctx_t;

static inline void write_interior_pixel(uint8_t *dst) {
    dst[0] = 6u;
    dst[1] = 8u;
    dst[2] = 16u;
    dst[3] = 255u;
}

static inline void write_fractal_pixel(
    uint8_t *dst,
    const uint8_t *palette_rgba,
    int iter,
    int max_iter,
    double zr2,
    double zi2,
    double inv_ln2)
{
    if (iter >= max_iter) {
        write_interior_pixel(dst);
        return;
    }
    double mag2 = zr2 + zi2;
    double nu = (mag2 > 1.0) ? (log(log(mag2) * 0.5) * inv_ln2) : 0.0;
    double smooth = (double)iter + 1.0 - nu;
    unsigned int idx = ((unsigned int)(int)(smooth * 5.0)) & 255u;
    const uint8_t *c = palette_rgba + (idx * 4u);
    dst[0] = c[0];
    dst[1] = c[1];
    dst[2] = c[2];
    dst[3] = c[3];
}

static inline int mandelbrot_in_cardioid_or_bulb(double cr, double ci) {
    double crm = cr - 0.25;
    double ci2 = ci * ci;
    double q   = (crm * crm) + ci2;
    if (q * (q + crm) <= (0.25 * ci2)) return 1;
    double cr1 = cr + 1.0;
    if (((cr1 * cr1) + ci2) <= 0.0625) return 1;
    return 0;
}

static inline void compute_pixel_scalar(
    const fractal_ctx_t *c,
    uint8_t *dst,
    double cr_in,
    double ci_in)
{
    double zr, zi, zr2, zi2, cr, ci;
    if (!c->is_julia) {
        if (mandelbrot_in_cardioid_or_bulb(cr_in, ci_in)) {
            write_interior_pixel(dst);
            return;
        }
        zr = 0.0; zi = 0.0; zr2 = 0.0; zi2 = 0.0;
        cr = cr_in; ci = ci_in;
    } else {
        zr = cr_in; zi = ci_in;
        zr2 = zr * zr; zi2 = zi * zi;
        cr = c->jr; ci = c->ji;
    }

    int iter = 0;
    const int max_iter = c->max_iter;
    while (iter < max_iter && (zr2 + zi2) <= 4.0) {
        zi  = ((2.0 * zr) * zi) + ci;
        zr  = (zr2 - zi2) + cr;
        zr2 = zr * zr;
        zi2 = zi * zi;
        iter++;
    }
    write_fractal_pixel(dst, c->palette_rgba, iter, max_iter, zr2, zi2, c->inv_ln2);
}

static void render_fractal_row_scalar(const fractal_ctx_t *c, uint32_t py) {
    const double ci_row = c->y_origin + (double)py * c->step;
    uint8_t *row_dst    = c->rgba_out + ((size_t)py * (size_t)c->w * 4u);
    const uint32_t w    = c->w;

    for (uint32_t px = 0; px < w; px++) {
        double cr_px = c->x_origin + (double)px * c->step;
        compute_pixel_scalar(c, row_dst + ((size_t)px * 4u), cr_px, ci_row);
    }
}

#if TKMT_HAVE_NEON_F64
static void render_fractal_row_neon(const fractal_ctx_t *c, uint32_t py) {
    const double ci_row  = c->y_origin + (double)py * c->step;
    uint8_t *row_dst     = c->rgba_out + ((size_t)py * (size_t)c->w * 4u);
    const uint32_t w     = c->w;
    const int max_iter   = c->max_iter;
    const int is_julia   = c->is_julia;
    const float64x2_t vtwo  = vdupq_n_f64(2.0);
    const float64x2_t vfour = vdupq_n_f64(4.0);

    uint32_t px = 0;
    for (; px + 1u < w; px += 2u) {
        double x0 = c->x_origin + (double)px * c->step;
        double x1 = c->x_origin + (double)(px + 1u) * c->step;
        uint8_t *dst0 = row_dst + ((size_t)px * 4u);
        uint8_t *dst1 = dst0 + 4u;

        double cr_arr[2], ci_arr[2];
        double zr_arr[2], zi_arr[2], zr2_arr[2], zi2_arr[2];

        if (!is_julia) {
            int in0 = mandelbrot_in_cardioid_or_bulb(x0, ci_row);
            int in1 = mandelbrot_in_cardioid_or_bulb(x1, ci_row);
            if (in0 && in1) {
                write_interior_pixel(dst0);
                write_interior_pixel(dst1);
                continue;
            }
            if (in0) {
                write_interior_pixel(dst0);
                compute_pixel_scalar(c, dst1, x1, ci_row);
                continue;
            }
            if (in1) {
                compute_pixel_scalar(c, dst0, x0, ci_row);
                write_interior_pixel(dst1);
                continue;
            }
            cr_arr[0] = x0;     cr_arr[1] = x1;
            ci_arr[0] = ci_row; ci_arr[1] = ci_row;
            zr_arr[0] = 0.0;    zr_arr[1] = 0.0;
            zi_arr[0] = 0.0;    zi_arr[1] = 0.0;
            zr2_arr[0] = 0.0;   zr2_arr[1] = 0.0;
            zi2_arr[0] = 0.0;   zi2_arr[1] = 0.0;
        } else {
            cr_arr[0]  = c->jr;   cr_arr[1]  = c->jr;
            ci_arr[0]  = c->ji;   ci_arr[1]  = c->ji;
            zr_arr[0]  = x0;      zr_arr[1]  = x1;
            zi_arr[0]  = ci_row;  zi_arr[1]  = ci_row;
            zr2_arr[0] = x0 * x0; zr2_arr[1] = x1 * x1;
            zi2_arr[0] = ci_row * ci_row;
            zi2_arr[1] = ci_row * ci_row;
        }

        float64x2_t vcr  = vld1q_f64(cr_arr);
        float64x2_t vci  = vld1q_f64(ci_arr);
        float64x2_t vzr  = vld1q_f64(zr_arr);
        float64x2_t vzi  = vld1q_f64(zi_arr);
        float64x2_t vzr2 = vld1q_f64(zr2_arr);
        float64x2_t vzi2 = vld1q_f64(zi2_arr);

        int iter = 0;
        while (iter < max_iter) {
            float64x2_t vsum = vaddq_f64(vzr2, vzi2);
            uint64x2_t  vmask = vcleq_f64(vsum, vfour);
            uint64_t m0 = vgetq_lane_u64(vmask, 0);
            uint64_t m1 = vgetq_lane_u64(vmask, 1);
            if ((m0 & m1) == 0u) break;

            vzi  = vaddq_f64(vmulq_f64(vmulq_f64(vtwo, vzr), vzi), vci);
            vzr  = vaddq_f64(vsubq_f64(vzr2, vzi2), vcr);
            vzr2 = vmulq_f64(vzr, vzr);
            vzi2 = vmulq_f64(vzi, vzi);
            iter++;
        }

        double zr0  = vgetq_lane_f64(vzr, 0),  zr1  = vgetq_lane_f64(vzr, 1);
        double zi0  = vgetq_lane_f64(vzi, 0),  zi1  = vgetq_lane_f64(vzi, 1);
        double zr20 = vgetq_lane_f64(vzr2, 0), zr21 = vgetq_lane_f64(vzr2, 1);
        double zi20 = vgetq_lane_f64(vzi2, 0), zi21 = vgetq_lane_f64(vzi2, 1);

        int iter0 = iter;
        while (iter0 < max_iter && (zr20 + zi20) <= 4.0) {
            zi0  = ((2.0 * zr0) * zi0) + ci_arr[0];
            zr0  = (zr20 - zi20) + cr_arr[0];
            zr20 = zr0 * zr0;
            zi20 = zi0 * zi0;
            iter0++;
        }
        write_fractal_pixel(dst0, c->palette_rgba, iter0, max_iter, zr20, zi20, c->inv_ln2);

        int iter1 = iter;
        while (iter1 < max_iter && (zr21 + zi21) <= 4.0) {
            zi1  = ((2.0 * zr1) * zi1) + ci_arr[1];
            zr1  = (zr21 - zi21) + cr_arr[1];
            zr21 = zr1 * zr1;
            zi21 = zi1 * zi1;
            iter1++;
        }
        write_fractal_pixel(dst1, c->palette_rgba, iter1, max_iter, zr21, zi21, c->inv_ln2);
    }

    if (px < w) {
        double cr_px = c->x_origin + (double)px * c->step;
        compute_pixel_scalar(c, row_dst + ((size_t)px * 4u), cr_px, ci_row);
    }
}
#elif TKMT_HAVE_SSE2_F64
static void render_fractal_row_sse2(const fractal_ctx_t *c, uint32_t py) {
    const double ci_row  = c->y_origin + (double)py * c->step;
    uint8_t *row_dst     = c->rgba_out + ((size_t)py * (size_t)c->w * 4u);
    const uint32_t w     = c->w;
    const int max_iter   = c->max_iter;
    const int is_julia   = c->is_julia;
    const __m128d vtwo   = _mm_set1_pd(2.0);
    const __m128d vfour  = _mm_set1_pd(4.0);

    uint32_t px = 0;
    for (; px + 1u < w; px += 2u) {
        double x0 = c->x_origin + (double)px * c->step;
        double x1 = c->x_origin + (double)(px + 1u) * c->step;
        uint8_t *dst0 = row_dst + ((size_t)px * 4u);
        uint8_t *dst1 = dst0 + 4u;

        double cr_arr[2], ci_arr[2];
        double zr_arr[2], zi_arr[2], zr2_arr[2], zi2_arr[2];

        if (!is_julia) {
            int in0 = mandelbrot_in_cardioid_or_bulb(x0, ci_row);
            int in1 = mandelbrot_in_cardioid_or_bulb(x1, ci_row);
            if (in0 && in1) {
                write_interior_pixel(dst0);
                write_interior_pixel(dst1);
                continue;
            }
            if (in0) {
                write_interior_pixel(dst0);
                compute_pixel_scalar(c, dst1, x1, ci_row);
                continue;
            }
            if (in1) {
                compute_pixel_scalar(c, dst0, x0, ci_row);
                write_interior_pixel(dst1);
                continue;
            }
            cr_arr[0] = x0;     cr_arr[1] = x1;
            ci_arr[0] = ci_row; ci_arr[1] = ci_row;
            zr_arr[0] = 0.0;    zr_arr[1] = 0.0;
            zi_arr[0] = 0.0;    zi_arr[1] = 0.0;
            zr2_arr[0] = 0.0;   zr2_arr[1] = 0.0;
            zi2_arr[0] = 0.0;   zi2_arr[1] = 0.0;
        } else {
            cr_arr[0]  = c->jr;   cr_arr[1]  = c->jr;
            ci_arr[0]  = c->ji;   ci_arr[1]  = c->ji;
            zr_arr[0]  = x0;      zr_arr[1]  = x1;
            zi_arr[0]  = ci_row;  zi_arr[1]  = ci_row;
            zr2_arr[0] = x0 * x0; zr2_arr[1] = x1 * x1;
            zi2_arr[0] = ci_row * ci_row;
            zi2_arr[1] = ci_row * ci_row;
        }

        __m128d vcr  = _mm_loadu_pd(cr_arr);
        __m128d vci  = _mm_loadu_pd(ci_arr);
        __m128d vzr  = _mm_loadu_pd(zr_arr);
        __m128d vzi  = _mm_loadu_pd(zi_arr);
        __m128d vzr2 = _mm_loadu_pd(zr2_arr);
        __m128d vzi2 = _mm_loadu_pd(zi2_arr);

        int iter = 0;
        while (iter < max_iter) {
            __m128d vsum  = _mm_add_pd(vzr2, vzi2);
            __m128d vmask = _mm_cmple_pd(vsum, vfour);
            if (_mm_movemask_pd(vmask) != 3) break;

            vzi  = _mm_add_pd(_mm_mul_pd(_mm_mul_pd(vtwo, vzr), vzi), vci);
            vzr  = _mm_add_pd(_mm_sub_pd(vzr2, vzi2), vcr);
            vzr2 = _mm_mul_pd(vzr, vzr);
            vzi2 = _mm_mul_pd(vzi, vzi);
            iter++;
        }

        _mm_storeu_pd(zr_arr, vzr);
        _mm_storeu_pd(zi_arr, vzi);
        _mm_storeu_pd(zr2_arr, vzr2);
        _mm_storeu_pd(zi2_arr, vzi2);

        double zr0 = zr_arr[0], zi0 = zi_arr[0], zr20 = zr2_arr[0], zi20 = zi2_arr[0];
        int iter0 = iter;
        while (iter0 < max_iter && (zr20 + zi20) <= 4.0) {
            zi0  = ((2.0 * zr0) * zi0) + ci_arr[0];
            zr0  = (zr20 - zi20) + cr_arr[0];
            zr20 = zr0 * zr0;
            zi20 = zi0 * zi0;
            iter0++;
        }
        write_fractal_pixel(dst0, c->palette_rgba, iter0, max_iter, zr20, zi20, c->inv_ln2);

        double zr1 = zr_arr[1], zi1 = zi_arr[1], zr21 = zr2_arr[1], zi21 = zi2_arr[1];
        int iter1 = iter;
        while (iter1 < max_iter && (zr21 + zi21) <= 4.0) {
            zi1  = ((2.0 * zr1) * zi1) + ci_arr[1];
            zr1  = (zr21 - zi21) + cr_arr[1];
            zr21 = zr1 * zr1;
            zi21 = zi1 * zi1;
            iter1++;
        }
        write_fractal_pixel(dst1, c->palette_rgba, iter1, max_iter, zr21, zi21, c->inv_ln2);
    }

    if (px < w) {
        double cr_px = c->x_origin + (double)px * c->step;
        compute_pixel_scalar(c, row_dst + ((size_t)px * 4u), cr_px, ci_row);
    }
}
#endif

static void fractal_worker_fn(void *vctx, int worker_id, int total_workers) {
    (void)worker_id;
    (void)total_workers;
    fractal_ctx_t *c = (fractal_ctx_t *)vctx;
    const uint32_t h = c->h;
    const uint32_t tile = 4u;

    for (;;) {
        uint32_t y0 = atomic_fetch_add_explicit(&c->next_row, tile, memory_order_relaxed);
        if (y0 >= h) break;
        uint32_t y1 = y0 + tile;
        if (y1 > h) y1 = h;

        for (uint32_t py = y0; py < y1; py++) {
            if (c->force_scalar) {
                render_fractal_row_scalar(c, py);
            } else {
#if TKMT_HAVE_NEON_F64
                render_fractal_row_neon(c, py);
#elif TKMT_HAVE_SSE2_F64
                render_fractal_row_sse2(c, py);
#else
                render_fractal_row_scalar(c, py);
#endif
            }
        }
    }
}

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
    int            workers)
{
    if (!rgba_out || !palette_rgba || w == 0u || h == 0u || max_iter < 1) {
        return -1;
    }

    int force_scalar = tkmt_compute_force_scalar();
    double step      = scale / (double)w;

    fractal_ctx_t ctx;
    ctx.rgba_out     = rgba_out;
    ctx.palette_rgba = palette_rgba;
    ctx.w            = w;
    ctx.h            = h;
    ctx.x_origin     = cx - ((double)w * 0.5) * step;
    ctx.y_origin     = cy - ((double)h * 0.5) * step;
    ctx.step         = step;
    ctx.inv_ln2      = 1.0 / log(2.0);
    ctx.max_iter     = max_iter;
    ctx.is_julia     = is_julia ? 1 : 0;
    ctx.jr           = jr;
    ctx.ji           = ji;
    ctx.force_scalar = force_scalar;
    atomic_init(&ctx.next_row, 0u);

    int use_workers;
    if (force_scalar) {
        use_workers = 1;
    } else if (workers <= 0) {
        use_workers = (h < 16u) ? 1 : tkmt_compute_default_workers();
    } else {
        use_workers = workers;
    }
    if ((uint32_t)use_workers > h) {
        use_workers = (int)h;
    }
    if (use_workers < 1) use_workers = 1;

    pool_dispatch(use_workers, fractal_worker_fn, &ctx);
    return 0;
}
