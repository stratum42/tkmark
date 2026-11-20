/*
 * c/tkmt_thread.h - Cross-platform C11 threading, synchronization, and OS helpers
 *
 * Portable across macOS (Clang), Linux (GCC/Clang), and Windows Win64
 * (MinGW-w64 / Strawberry Perl / MSVC).
 *
 * Provides:
 *   - tkmt_static_mutex_t (SRWLOCK on Win32, pthread_mutex_t on POSIX)
 *   - tkmt_mutex_t        (CRITICAL_SECTION on Win32, pthread_mutex_t on POSIX)
 *   - tkmt_cond_t         (CONDITION_VARIABLE on Win32, pthread_cond_t on POSIX)
 *   - tkmt_thread_t       (HANDLE/CreateThread on Win32, pthread_t on POSIX)
 *   - tkmt_cpu_count(), tkmt_thread_id(), tkmt_process_id(), tkmt_thread_yield()
 */
#ifndef TKMT_THREAD_H
#define TKMT_THREAD_H

#if !defined(_WIN32) && !defined(__APPLE__)
#  if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE) && !defined(_DEFAULT_SOURCE)
#    define _POSIX_C_SOURCE 200809L
#  endif
#endif

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>

/* ---- Static mutex (SRWLOCK: statically initializable, lightweight) ---- */
typedef SRWLOCK tkmt_static_mutex_t;
#  define TKMT_STATIC_MUTEX_INIT SRWLOCK_INIT

static inline void tkmt_static_mutex_lock(tkmt_static_mutex_t *m) {
    AcquireSRWLockExclusive(m);
}
static inline void tkmt_static_mutex_unlock(tkmt_static_mutex_t *m) {
    ReleaseSRWLockExclusive(m);
}

/* ---- Dynamic mutex (CRITICAL_SECTION: pairs with CONDITION_VARIABLE) ---- */
typedef CRITICAL_SECTION tkmt_mutex_t;

static inline int tkmt_mutex_init(tkmt_mutex_t *m) {
    InitializeCriticalSection(m);
    return 0;
}
static inline void tkmt_mutex_destroy(tkmt_mutex_t *m) {
    DeleteCriticalSection(m);
}
static inline void tkmt_mutex_lock(tkmt_mutex_t *m) {
    EnterCriticalSection(m);
}
static inline void tkmt_mutex_unlock(tkmt_mutex_t *m) {
    LeaveCriticalSection(m);
}

/* ---- Condition variable (Vista+ CONDITION_VARIABLE) ---- */
typedef CONDITION_VARIABLE tkmt_cond_t;

static inline int tkmt_cond_init(tkmt_cond_t *c) {
    InitializeConditionVariable(c);
    return 0;
}
static inline void tkmt_cond_destroy(tkmt_cond_t *c) {
    (void)c;
}
static inline void tkmt_cond_wait(tkmt_cond_t *c, tkmt_mutex_t *m) {
    SleepConditionVariableCS(c, m, INFINITE);
}
static inline void tkmt_cond_signal(tkmt_cond_t *c) {
    WakeConditionVariable(c);
}
static inline void tkmt_cond_broadcast(tkmt_cond_t *c) {
    WakeAllConditionVariable(c);
}

/* ---- OS Thread ---- */
typedef HANDLE tkmt_thread_t;
typedef DWORD  tkmt_thread_ret_t;
#  define TKMT_THREAD_CALL        WINAPI
#  define TKMT_THREAD_RETURN_ZERO return 0u

typedef tkmt_thread_ret_t (TKMT_THREAD_CALL *tkmt_thread_fn_t)(void *arg);

static inline int tkmt_thread_create(tkmt_thread_t *out, tkmt_thread_fn_t fn, void *arg) {
    HANDLE h = CreateThread(NULL, 0, fn, arg, 0, NULL);
    if (!h) return -1;
    *out = h;
    return 0;
}
static inline int tkmt_thread_join(tkmt_thread_t t) {
    if (!t) return -1;
    DWORD rc = WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
    return (rc == WAIT_OBJECT_0) ? 0 : -1;
}

/* ---- OS / CPU / Thread identity helpers ---- */
static inline int tkmt_cpu_count(void) {
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return (si.dwNumberOfProcessors > 0u) ? (int)si.dwNumberOfProcessors : 1;
}
static inline uint64_t tkmt_thread_id(void) {
    return (uint64_t)GetCurrentThreadId();
}
static inline uint64_t tkmt_process_id(void) {
    return (uint64_t)GetCurrentProcessId();
}
static inline void tkmt_thread_yield(void) {
    SwitchToThread();
}

#else /* POSIX (macOS / Linux / BSD) */

#  include <pthread.h>
#  include <sched.h>
#  include <unistd.h>

/* ---- Static mutex ---- */
typedef pthread_mutex_t tkmt_static_mutex_t;
#  define TKMT_STATIC_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER

static inline void tkmt_static_mutex_lock(tkmt_static_mutex_t *m) {
    pthread_mutex_lock(m);
}
static inline void tkmt_static_mutex_unlock(tkmt_static_mutex_t *m) {
    pthread_mutex_unlock(m);
}

/* ---- Dynamic mutex ---- */
typedef pthread_mutex_t tkmt_mutex_t;

static inline int tkmt_mutex_init(tkmt_mutex_t *m) {
    return pthread_mutex_init(m, NULL);
}
static inline void tkmt_mutex_destroy(tkmt_mutex_t *m) {
    pthread_mutex_destroy(m);
}
static inline void tkmt_mutex_lock(tkmt_mutex_t *m) {
    pthread_mutex_lock(m);
}
static inline void tkmt_mutex_unlock(tkmt_mutex_t *m) {
    pthread_mutex_unlock(m);
}

/* ---- Condition variable ---- */
typedef pthread_cond_t tkmt_cond_t;

static inline int tkmt_cond_init(tkmt_cond_t *c) {
    return pthread_cond_init(c, NULL);
}
static inline void tkmt_cond_destroy(tkmt_cond_t *c) {
    pthread_cond_destroy(c);
}
static inline void tkmt_cond_wait(tkmt_cond_t *c, tkmt_mutex_t *m) {
    pthread_cond_wait(c, m);
}
static inline void tkmt_cond_signal(tkmt_cond_t *c) {
    pthread_cond_signal(c);
}
static inline void tkmt_cond_broadcast(tkmt_cond_t *c) {
    pthread_cond_broadcast(c);
}

/* ---- OS Thread ---- */
typedef pthread_t tkmt_thread_t;
typedef void     *tkmt_thread_ret_t;
#  define TKMT_THREAD_CALL
#  define TKMT_THREAD_RETURN_ZERO return NULL

typedef tkmt_thread_ret_t (TKMT_THREAD_CALL *tkmt_thread_fn_t)(void *arg);

static inline int tkmt_thread_create(tkmt_thread_t *out, tkmt_thread_fn_t fn, void *arg) {
    return pthread_create(out, NULL, fn, arg);
}
static inline int tkmt_thread_join(tkmt_thread_t t) {
    return pthread_join(t, NULL);
}

/* ---- OS / CPU / Thread identity helpers ---- */
static inline int tkmt_cpu_count(void) {
#  if defined(_SC_NPROCESSORS_ONLN)
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return (n > 0) ? (int)n : 1;
#  else
    return 4;
#  endif
}
static inline uint64_t tkmt_thread_id(void) {
#  if defined(__APPLE__)
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return tid;
#  else
    return (uint64_t)(uintptr_t)pthread_self();
#  endif
}
static inline uint64_t tkmt_process_id(void) {
    return (uint64_t)getpid();
}
static inline void tkmt_thread_yield(void) {
    sched_yield();
}

#endif /* _WIN32 */

#endif /* TKMT_THREAD_H */
