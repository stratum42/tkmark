/*
 * c/mt_compat.h - perl5-mt Tier-1 XS compatibility and packed-AV zero-copy readers
 *
 * Pure C11 (no C++). On perl5-mt, emits mt_threadsafe_boot_<Mod> and reads
 * SVf_PACKED_AV buffers directly; on stock Perl 5, falls back to av_fetch.
 */
#ifndef TKMT_XS_MT_COMPAT_H
#define TKMT_XS_MT_COMPAT_H

#ifdef __cplusplus
#  error "TkMark::Compute XS must be compiled as pure C11, not C++"
#endif

#ifndef PERL_NO_GET_CONTEXT
#  define PERL_NO_GET_CONTEXT
#endif

#ifndef PERL_XS_THREADSAFE
#  define PERL_XS_THREADSAFE 1
#endif

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

/* Detect perl5-mt thread-safe XS marker support */
#ifdef PERL_MT_XS_MARKER
#  define TKMT_IS_PERL5_MT 1
#else
#  define TKMT_IS_PERL5_MT 0
#endif

/* Detect perl5-mt packed AV support (SVf_PACKED_AV / AvPACKED_TYPE / AvPACKED_DATA) */
#if defined(SVf_PACKED_AV) && defined(AvPACKED_TYPE) && defined(AvPACKED_DATA)
#  define TKMT_HAVE_PACKED_AV 1
#else
#  define TKMT_HAVE_PACKED_AV 0
#  ifndef AV_PACKED_NONE
#    define AV_PACKED_NONE 0
#    define AV_PACKED_IV   1
#    define AV_PACKED_NV   2
#    define AV_PACKED_U8   3
#  endif
#  ifndef AvPACKED_TYPE
#    define AvPACKED_TYPE(av) ((U8)AV_PACKED_NONE)
#  endif
#  ifndef AvPACKED_DATA
#    define AvPACKED_DATA(av) ((void *)NULL)
#  endif
#endif

/*
 * Zero-copy packed AV readers with automatic fallback on stock Perl 5 or
 * unpacked AVs.
 *
 * When *out_owned == 0, *out_buf points directly into the packed AV's backing
 * storage (valid for the duration of the XSUB call; caller must NOT free it).
 * When *out_owned == 1, *out_buf was allocated via malloc() and caller MUST
 * free(*out_buf).
 *
 * Returns 1 on success, 0 on allocation failure.
 */
static inline int
tkmt_av_read_nv(pTHX_ AV *av, const double **out_buf, size_t *out_len, int *out_owned)
{
    SSize_t top = av_top_index(av);
    size_t n = (top < 0) ? 0 : (size_t)(top + 1);
    *out_len = n;
    *out_owned = 0;

    if (n == 0) {
        *out_buf = NULL;
        return 1;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_NV && sizeof(NV) == sizeof(double)) {
        *out_buf = (const double *)AvPACKED_DATA(av);
        *out_owned = 0;
        return 1;
    }
#endif

    double *tmp = (double *)malloc(n * sizeof(double));
    if (!tmp) {
        *out_buf = NULL;
        return 0;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_IV) {
        const IV *src = (const IV *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (double)src[i];
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
    if (AvPACKED_TYPE(av) == AV_PACKED_U8) {
        const U8 *src = (const U8 *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (double)src[i];
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
#endif

    for (size_t i = 0; i < n; i++) {
        SV **svp = av_fetch(av, (SSize_t)i, 0);
        tmp[i] = (svp && *svp) ? (double)SvNV(*svp) : 0.0;
    }
    *out_buf = tmp;
    *out_owned = 1;
    return 1;
}

static inline int
tkmt_av_read_f32(pTHX_ AV *av, float **out_buf, size_t *out_len, int *out_owned)
{
    SSize_t top = av_top_index(av);
    size_t n = (top < 0) ? 0 : (size_t)(top + 1);
    *out_len = n;
    *out_owned = 0;

    if (n == 0) {
        *out_buf = NULL;
        return 1;
    }

    float *tmp = (float *)malloc(n * sizeof(float));
    if (!tmp) {
        *out_buf = NULL;
        return 0;
    }

#if TKMT_HAVE_PACKED_AV
    U8 ptype = AvPACKED_TYPE(av);
    if (ptype == AV_PACKED_NV) {
        const NV *src = (const NV *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (float)src[i];
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
    if (ptype == AV_PACKED_IV) {
        const IV *src = (const IV *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (float)src[i];
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
    if (ptype == AV_PACKED_U8) {
        const U8 *src = (const U8 *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (float)src[i];
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
#endif

    for (size_t i = 0; i < n; i++) {
        SV **svp = av_fetch(av, (SSize_t)i, 0);
        tmp[i] = (svp && *svp) ? (float)SvNV(*svp) : 0.0f;
    }
    *out_buf = tmp;
    *out_owned = 1;
    return 1;
}

static inline int
tkmt_av_read_u8(pTHX_ AV *av, const uint8_t **out_buf, size_t *out_len, int *out_owned)
{
    SSize_t top = av_top_index(av);
    size_t n = (top < 0) ? 0 : (size_t)(top + 1);
    *out_len = n;
    *out_owned = 0;

    if (n == 0) {
        *out_buf = NULL;
        return 1;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_U8) {
        *out_buf = (const uint8_t *)AvPACKED_DATA(av);
        *out_owned = 0;
        return 1;
    }
#endif

    uint8_t *tmp = (uint8_t *)malloc(n);
    if (!tmp) {
        *out_buf = NULL;
        return 0;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_IV) {
        const IV *src = (const IV *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (uint8_t)(src[i] & 0xFF);
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
    if (AvPACKED_TYPE(av) == AV_PACKED_NV) {
        const NV *src = (const NV *)AvPACKED_DATA(av);
        for (size_t i = 0; i < n; i++) tmp[i] = (uint8_t)((int)src[i] & 0xFF);
        *out_buf = tmp;
        *out_owned = 1;
        return 1;
    }
#endif

    for (size_t i = 0; i < n; i++) {
        SV **svp = av_fetch(av, (SSize_t)i, 0);
        tmp[i] = (svp && *svp) ? (uint8_t)(SvUV(*svp) & 0xFF) : 0;
    }
    *out_buf = tmp;
    *out_owned = 1;
    return 1;
}

static inline int
tkmt_av_read_iv(pTHX_ AV *av, const int64_t **out_buf, size_t *out_len, int *out_owned)
{
    SSize_t top = av_top_index(av);
    size_t n = (top < 0) ? 0 : (size_t)(top + 1);
    *out_len = n;
    *out_owned = 0;

    if (n == 0) {
        *out_buf = NULL;
        return 1;
    }

#if TKMT_HAVE_PACKED_AV
    if (AvPACKED_TYPE(av) == AV_PACKED_IV && sizeof(IV) == sizeof(int64_t)) {
        *out_buf = (const int64_t *)AvPACKED_DATA(av);
        *out_owned = 0;
        return 1;
    }
#endif

    int64_t *tmp = (int64_t *)malloc(n * sizeof(int64_t));
    if (!tmp) {
        *out_buf = NULL;
        return 0;
    }

    for (size_t i = 0; i < n; i++) {
        SV **svp = av_fetch(av, (SSize_t)i, 0);
        tmp[i] = (svp && *svp) ? (int64_t)SvIV(*svp) : 0;
    }
    *out_buf = tmp;
    *out_owned = 1;
    return 1;
}

#endif /* TKMT_XS_MT_COMPAT_H */
