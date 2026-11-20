/*
 * Compute.xs - C11 Tier-1 thread-safe XS bindings for TkMark::Compute
 *
 * Exposes SIMD + multi-threaded compute kernels:
 *   - TkMark::Compute::step_particles_2d
 *   - TkMark::Compute::render_fractal_rgba8
 *
 * Uses zero-copy perl5-mt SVf_PACKED_AV (AV_PACKED_NV / AV_PACKED_U8) backing
 * stores when available, with automatic fallback to standard Perl arrays on
 * stock Perl 5.
 */

#include "c/mt_compat.h"
#include "c/compute.h"

#include <string.h>

static inline uint32_t tkmark_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (uint32_t)r
         | ((uint32_t)g << 8)
         | ((uint32_t)b << 16)
         | ((uint32_t)a << 24);
}

/* Read pixel bytes from either a Perl byte string SV or an arrayref (with
 * zero-copy SVf_PACKED_AV AV_PACKED_U8 fast path). */
static int read_u8_pixels(pTHX_ SV *sv, const uint8_t **out_buf, size_t *out_len, int *out_owned) {
    *out_buf   = NULL;
    *out_len   = 0;
    *out_owned = 0;

    if (!sv || !SvOK(sv)) return 1;

    if (SvROK(sv) && SvTYPE(SvRV(sv)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(sv);
        return tkmt_av_read_u8(aTHX_ av, out_buf, out_len, out_owned);
    }

    STRLEN len = 0;
    const char *pv = SvPVbyte(sv, len);
    *out_buf   = (const uint8_t *)pv;
    *out_len   = (size_t)len;
    *out_owned = 0;
    return 1;
}

/* -------------------------------------------------------------------------
 * Zero-copy mutable packed-AV helpers for compute kernels (with stock fallback)
 * ------------------------------------------------------------------------- */

static int tkmt_av_rw_nv(
    pTHX_ SV *aref, size_t min_len, int read_in,
    double **out_buf, size_t *out_len, int *out_owned, AV **out_av,
    const char *label)
{
    *out_buf   = NULL;
    *out_len   = 0;
    *out_owned = 0;
    *out_av    = NULL;

    if (!aref || !SvROK(aref) || SvTYPE(SvRV(aref)) != SVt_PVAV) {
        croak("%s: expected arrayref", label);
    }
    AV *av = (AV *)SvRV(aref);
    SSize_t top = av_top_index(av);
    size_t len = (top < 0) ? 0u : (size_t)(top + 1);
    if (len < min_len) {
        croak("%s: array too small (%zu < %zu)", label, len, min_len);
    }
    *out_len = len;
    *out_av  = av;

    if (min_len == 0u) {
        return 1;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_NV && sizeof(NV) == sizeof(double)) {
        *out_buf   = (double *)AvPACKED_DATA(av);
        *out_owned = 0;
        return 1;
    }
#endif

    double *tmp = (double *)malloc(min_len * sizeof(double));
    if (!tmp) return 0;

    if (read_in) {
#if TKMT_HAVE_PACKED_AV
        U8 ptype = AvPACKED_TYPE(av);
        if (ptype == AV_PACKED_NV) {
            const NV *src = (const NV *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else if (ptype == AV_PACKED_IV) {
            const IV *src = (const IV *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else if (ptype == AV_PACKED_U8) {
            const U8 *src = (const U8 *)AvPACKED_DATA(av);
            for (size_t i = 0; i < min_len; i++) tmp[i] = (double)src[i];
        } else
#endif
        {
            for (size_t i = 0; i < min_len; i++) {
                SV **svp = av_fetch(av, (SSize_t)i, 0);
                tmp[i] = (svp && *svp) ? (double)SvNV(*svp) : 0.0;
            }
        }
    }

    *out_buf   = tmp;
    *out_owned = 1;
    return 1;
}

static void tkmt_av_commit_nv(pTHX_ AV *av, double *buf, size_t write_len, int owned) {
    if (!owned) return;
    if (av && buf && write_len > 0u) {
        for (size_t i = 0; i < write_len; i++) {
            SV **svp = av_fetch(av, (SSize_t)i, 1);
            if (svp && *svp) {
                sv_setnv(*svp, (NV)buf[i]);
            }
        }
    }
    free(buf);
}

static void tkmt_read_palette_u32(pTHX_ SV *pal_sv, uint32_t out_u32[256], const char *label) {
    if (!pal_sv || !SvOK(pal_sv)) {
        croak("%s: palette_lut is required", label);
    }

    if (SvROK(pal_sv) && SvTYPE(SvRV(pal_sv)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(pal_sv);
        SSize_t top = av_top_index(av);
        size_t len = (top < 0) ? 0u : (size_t)(top + 1);

        if (len >= 1024u) {
            const uint8_t *u8 = NULL;
            size_t u8_len = 0;
            int u8_owned = 0;
            if (!tkmt_av_read_u8(aTHX_ av, &u8, &u8_len, &u8_owned) || u8_len < 1024u) {
                if (u8_owned) free((void *)u8);
                croak("%s: failed to read 256*4 U8 palette LUT", label);
            }
            for (int i = 0; i < 256; i++) {
                const uint8_t *p = u8 + (i * 4);
                out_u32[i] = tkmark_rgba(p[0], p[1], p[2], p[3]);
            }
            if (u8_owned) free((void *)u8);
            return;
        }

        if (len < 256u) {
            croak("%s: palette_lut must have 256 u32 entries or 1024 u8 RGBA bytes (got %zu)", label, len);
        }

#if TKMT_HAVE_PACKED_AV
        U8 ptype = AvPACKED_TYPE(av);
        if (ptype == AV_PACKED_IV) {
            const IV *src = (const IV *)AvPACKED_DATA(av);
            for (int i = 0; i < 256; i++) out_u32[i] = (uint32_t)(uint64_t)src[i];
            return;
        }
        if (ptype == AV_PACKED_NV) {
            const NV *src = (const NV *)AvPACKED_DATA(av);
            for (int i = 0; i < 256; i++) out_u32[i] = (uint32_t)(uint64_t)src[i];
            return;
        }
#endif
        for (int i = 0; i < 256; i++) {
            SV **svp = av_fetch(av, (SSize_t)i, 0);
            out_u32[i] = (svp && *svp) ? (uint32_t)SvUV(*svp) : 0xFF000000u;
        }
        return;
    }

    /* Raw 1024-byte RGBA string */
    STRLEN slen = 0;
    const uint8_t *pv = (const uint8_t *)SvPVbyte(pal_sv, slen);
    if (slen < 1024u) {
        croak("%s: byte-string palette_lut too small (%zu < 1024)", label, (size_t)slen);
    }
    for (int i = 0; i < 256; i++) {
        const uint8_t *p = pv + (i * 4);
        out_u32[i] = tkmark_rgba(p[0], p[1], p[2], p[3]);
    }
}

static int tkmt_av_rw_u8(
    pTHX_ SV *out_sv, size_t need_bytes,
    uint8_t **out_buf, int *out_owned, AV **out_av,
    const char *label)
{
    *out_buf   = NULL;
    *out_owned = 0;
    *out_av    = NULL;

    if (!out_sv) croak("%s: output buffer required", label);

    if (SvROK(out_sv) && SvTYPE(SvRV(out_sv)) == SVt_PVAV) {
        AV *av = (AV *)SvRV(out_sv);
        SSize_t top = av_top_index(av);
        size_t len = (top < 0) ? 0u : (size_t)(top + 1);
        if (len < need_bytes) {
            croak("%s: output array too small (%zu < %zu)", label, len, need_bytes);
        }
        *out_av = av;

#if TKMT_HAVE_PACKED_AV
        if (AvPACKED_TYPE(av) == AV_PACKED_U8) {
            *out_buf   = (uint8_t *)AvPACKED_DATA(av);
            *out_owned = 0;
            return 1;
        }
#endif
        uint8_t *tmp = (uint8_t *)malloc(need_bytes ? need_bytes : 1u);
        if (!tmp) return 0;
        *out_buf   = tmp;
        *out_owned = 1;
        return 1;
    }

    if (!SvREADONLY(out_sv)) {
        if (!SvPOK(out_sv)) {
            sv_setpvn(out_sv, "", 0);
        }
        SvPOK_only(out_sv);
        char *dst = SvGROW(out_sv, need_bytes + 1u);
        *out_buf   = (uint8_t *)dst;
        *out_owned = 2; /* direct PV scalar write */
        return 1;
    }

    croak("%s: output buffer must be a mutable U8 arrayref or writable byte scalar", label);
    return 0;
}

static void tkmt_av_commit_u8(pTHX_ SV *out_sv, AV *av, uint8_t *buf, size_t len, int owned) {
    if (owned == 0) {
        return; /* zero-copy packed U8 AV already written in place */
    }
    if (owned == 2) {
        SvCUR_set(out_sv, len);
        buf[len] = '\0';
        return;
    }
    if (owned == 1) {
        if (av && buf && len > 0u) {
            for (size_t i = 0; i < len; i++) {
                SV **svp = av_fetch(av, (SSize_t)i, 1);
                if (svp && *svp) {
                    sv_setuv(*svp, (UV)buf[i]);
                }
            }
        }
        free(buf);
    }
}

/* ========================================================================= */

MODULE = TkMark::Compute   PACKAGE = TkMark::Compute

PROTOTYPES: DISABLE

int
is_perl5_mt()
    CODE:
        RETVAL = TKMT_IS_PERL5_MT;
    OUTPUT:
        RETVAL

int
have_packed_av()
    CODE:
        RETVAL = TKMT_HAVE_PACKED_AV;
    OUTPUT:
        RETVAL

int
av_packed_type(aref)
        SV *aref
    CODE:
        if (!aref || !SvROK(aref) || SvTYPE(SvRV(aref)) != SVt_PVAV) {
            RETVAL = 0;
        } else {
            AV *av = (AV *)SvRV(aref);
            RETVAL = (int)AvPACKED_TYPE(av);
        }
    OUTPUT:
        RETVAL

int
force_scalar()
    CODE:
        RETVAL = tkmt_compute_force_scalar();
    OUTPUT:
        RETVAL

int
default_workers()
    CODE:
        RETVAL = tkmt_compute_default_workers();
    OUTPUT:
        RETVAL

UV
step_particles_2d(px_aref, py_aref, vx_aref, vy_aref, inst_aref, palette_lut, n, width, height, attr_x, attr_y, grav, dt, damp, trails_aref = &PL_sv_undef, trail_step = 0, workers = 0)
        SV *px_aref
        SV *py_aref
        SV *vx_aref
        SV *vy_aref
        SV *inst_aref
        SV *palette_lut
        UV n
        double width
        double height
        double attr_x
        double attr_y
        double grav
        double dt
        double damp
        SV *trails_aref
        UV trail_step
        int workers
    CODE:
        if (n == 0) {
            RETVAL = 0;
        } else {
            uint32_t pal_u32[256];
            tkmt_read_palette_u32(aTHX_ palette_lut, pal_u32, "step_particles_2d");

            double *px = NULL, *py = NULL, *vx = NULL, *vy = NULL, *inst = NULL, *trails = NULL;
            size_t px_len = 0, py_len = 0, vx_len = 0, vy_len = 0, inst_len = 0, trails_len = 0;
            int px_own = 0, py_own = 0, vx_own = 0, vy_own = 0, inst_own = 0, trails_own = 0;
            AV *px_av = NULL, *py_av = NULL, *vx_av = NULL, *vy_av = NULL, *inst_av = NULL, *trails_av = NULL;

            if (!tkmt_av_rw_nv(aTHX_ px_aref,   (size_t)n,      1, &px,   &px_len,   &px_own,   &px_av,   "step_particles_2d(px)") ||
                !tkmt_av_rw_nv(aTHX_ py_aref,   (size_t)n,      1, &py,   &py_len,   &py_own,   &py_av,   "step_particles_2d(py)") ||
                !tkmt_av_rw_nv(aTHX_ vx_aref,   (size_t)n,      1, &vx,   &vx_len,   &vx_own,   &vx_av,   "step_particles_2d(vx)") ||
                !tkmt_av_rw_nv(aTHX_ vy_aref,   (size_t)n,      1, &vy,   &vy_len,   &vy_own,   &vy_av,   "step_particles_2d(vy)") ||
                !tkmt_av_rw_nv(aTHX_ inst_aref, (size_t)n * 4u, 0, &inst, &inst_len, &inst_own, &inst_av, "step_particles_2d(inst)"))
            {
                if (px_own)   free(px);
                if (py_own)   free(py);
                if (vx_own)   free(vx);
                if (vy_own)   free(vy);
                if (inst_own) free(inst);
                croak("step_particles_2d: out of memory");
            }

            size_t trails_cap_segs = 0;
            if (trails_aref && SvOK(trails_aref) && trail_step > 0) {
                size_t need_segs = ((size_t)n + (size_t)trail_step - 1u) / (size_t)trail_step;
                if (!tkmt_av_rw_nv(aTHX_ trails_aref, 0u, 0, &trails, &trails_len, &trails_own, &trails_av, "step_particles_2d(trails)")) {
                    if (px_own)   free(px);
                    if (py_own)   free(py);
                    if (vx_own)   free(vx);
                    if (vy_own)   free(vy);
                    if (inst_own) free(inst);
                    croak("step_particles_2d: out of memory");
                }
                trails_cap_segs = trails_len / 4u;
                if (trails_cap_segs > need_segs) trails_cap_segs = need_segs;
                if (trails_cap_segs > 0u && trails_own && !trails) {
                    trails = (double *)malloc(trails_cap_segs * 4u * sizeof(double));
                    if (!trails) {
                        if (px_own)   free(px);
                        if (py_own)   free(py);
                        if (vx_own)   free(vx);
                        if (vy_own)   free(vy);
                        if (inst_own) free(inst);
                        croak("step_particles_2d: out of memory allocating trails buffer");
                    }
                } else if (trails_cap_segs > 0u && !trails && trails_av) {
                    if (!tkmt_av_rw_nv(aTHX_ trails_aref, trails_cap_segs * 4u, 0,
                                       &trails, &trails_len, &trails_own, &trails_av,
                                       "step_particles_2d(trails)"))
                    {
                        if (px_own)   free(px);
                        if (py_own)   free(py);
                        if (vx_own)   free(vx);
                        if (vy_own)   free(vy);
                        if (inst_own) free(inst);
                        croak("step_particles_2d: out of memory allocating trails buffer");
                    }
                }
            }

            size_t segs_written = tkmt_step_particles_2d(
                px, py, vx, vy, inst, pal_u32,
                (size_t)n, width, height, attr_x, attr_y, grav, dt, damp,
                trails, trails_cap_segs, (size_t)trail_step, workers);

            tkmt_av_commit_nv(aTHX_ px_av,     px,     (size_t)n,        px_own);
            tkmt_av_commit_nv(aTHX_ py_av,     py,     (size_t)n,        py_own);
            tkmt_av_commit_nv(aTHX_ vx_av,     vx,     (size_t)n,        vx_own);
            tkmt_av_commit_nv(aTHX_ vy_av,     vy,     (size_t)n,        vy_own);
            tkmt_av_commit_nv(aTHX_ inst_av,   inst,   (size_t)n * 4u,   inst_own);
            if (trails) {
                tkmt_av_commit_nv(aTHX_ trails_av, trails, segs_written * 4u, trails_own);
            }
            RETVAL = (UV)segs_written;
        }
    OUTPUT:
        RETVAL

int
render_fractal_rgba8(rgba_out_sv, palette_lut, w, h, cx, cy, scale, max_iter, is_julia = 0, jr = 0.0, ji = 0.0, workers = 0)
        SV *rgba_out_sv
        SV *palette_lut
        UV w
        UV h
        double cx
        double cy
        double scale
        int max_iter
        int is_julia
        double jr
        double ji
        int workers
    CODE:
        if (w == 0 || h == 0 || max_iter < 1) {
            croak("render_fractal_rgba8: invalid dimensions or max_iter");
        }
        const uint8_t *pal_buf = NULL;
        size_t pal_len = 0;
        int pal_owned = 0;
        if (!read_u8_pixels(aTHX_ palette_lut, &pal_buf, &pal_len, &pal_owned) || !pal_buf || pal_len < 1024u) {
            if (pal_owned) free((void *)pal_buf);
            croak("render_fractal_rgba8: palette_lut must be 256*4=1024 U8 bytes");
        }

        size_t need = (size_t)w * (size_t)h * 4u;
        uint8_t *out_buf = NULL;
        int out_owned = 0;
        AV *out_av = NULL;
        if (!tkmt_av_rw_u8(aTHX_ rgba_out_sv, need, &out_buf, &out_owned, &out_av, "render_fractal_rgba8")) {
            if (pal_owned) free((void *)pal_buf);
            croak("render_fractal_rgba8: out of memory");
        }

        int rc = tkmt_render_fractal_rgba8(
            out_buf, pal_buf, (uint32_t)w, (uint32_t)h,
            cx, cy, scale, max_iter, is_julia, jr, ji, workers);

        tkmt_av_commit_u8(aTHX_ rgba_out_sv, out_av, out_buf, need, out_owned);
        if (pal_owned) free((void *)pal_buf);
        RETVAL = rc;
    OUTPUT:
        RETVAL
