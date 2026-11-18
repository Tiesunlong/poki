// TEMPORARY DIAGNOSTIC — not for merging.
//
// On a physical iPhone Duo (iOS 27.2.1) Poki never finishes its first frame: the main thread spins
// inside the first CA commit until the scene-create watchdog (0x8BADF00D) kills it after 20 s. The
// crash report only has one snapshot, all inside SwiftUI/UIKit. This file finds out what the loop is,
// without a debugger:
//
//  - a background thread posts a heartbeat to the main queue; if it has not run for 1.5 s, the main
//    thread is stuck, and the probe records once, for this launch:
//  - main-thread stack samples (thread_get_state + frame-pointer walk, every 4 ms for 9 s), aggregated
//    by frame (inclusive) and by whole stack;
//  - while recording, counters behind swizzles of layout, invalidation and geometry setters (by
//    receiver class and caller address), and the first events in order, with their values;
//  - UIKit/SwiftUI/QuartzCore callers named from the Objective-C method tables (their own symbols
//    are redacted on the device).
//
// The report goes to Documents/launch-hang.txt and to the unified log (subsystem
// nz.zheha.poki.hangprobe, public). Poki's own frames are symbolicated offline with atos.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <os/log.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#if defined(__arm64__)

#define PKH_MAX_FRAMES 192
#define PKH_MAX_SAMPLES 2250          // 9 s at 4 ms
#define PKH_SAMPLE_USEC 4000
#define PKH_TABLE 4096                // counter slots (open addressing)
#define PKH_TRACE 900                 // first events while recording, in order

static os_log_t PKHLog;
static mach_port_t PKHMainThread = MACH_PORT_NULL;
static uintptr_t PKHStackLow, PKHStackHigh;
static _Atomic double PKHLastBeat;
static atomic_int PKHBeatPending;
static atomic_int PKHRecording;
static atomic_int PKHDone;

static double PKHNow(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

static inline uintptr_t PKHStrip(uintptr_t p) { return p & 0x0000000FFFFFFFFFULL; }

// MARK: - Counters and trace (written on the main thread only, read after recording stops)

typedef struct { uintptr_t kind, key, caller; unsigned long count; } PKHSlot;
static PKHSlot PKHSlots[PKH_TABLE];

typedef struct { uintptr_t kind, key, caller; CGRect value; } PKHEvent;
static PKHEvent PKHTrace[PKH_TRACE];
static int PKHTraceCount;

enum {
    PKHKindLayout = 1, PKHKindViewNeedsLayout, PKHKindLayerNeedsLayout, PKHKindInvalidateIntrinsic,
    PKHKindSetBounds, PKHKindSetFrame, PKHKindSafeArea, PKHKindAdjustedInset, PKHKindContentOffset,
    PKHKindContentInset, PKHKindContentSize,
};

static void PKHCount(uintptr_t kind, uintptr_t key, uintptr_t caller) {
    uintptr_t h = (kind * 0x9E3779B97F4A7C15ULL) ^ (key * 0xC2B2AE3D27D4EB4FULL) ^ (caller * 0x165667B19E3779F9ULL);
    for (int probe = 0; probe < 64; probe++) {
        PKHSlot *s = &PKHSlots[(h + probe) & (PKH_TABLE - 1)];
        if (s->count == 0 && s->kind == 0) { s->kind = kind; s->key = key; s->caller = caller; s->count = 1; return; }
        if (s->kind == kind && s->key == key && s->caller == caller) { s->count++; return; }
    }
}

static inline void PKHNote(uintptr_t kind, uintptr_t key, uintptr_t caller, CGRect value) {
    PKHCount(kind, key, caller);
    if (PKHTraceCount < PKH_TRACE) PKHTrace[PKHTraceCount++] = (PKHEvent){ kind, key, caller, value };
}

#define PKH_ON atomic_load_explicit(&PKHRecording, memory_order_relaxed)
#define PKH_CLS(obj) ((uintptr_t)object_getClass(obj))
#define PKH_CALLER PKHStrip((uintptr_t)__builtin_return_address(0))
#define PKH_INSETS(i) CGRectMake((i).top, (i).left, (i).bottom, (i).right)

// MARK: - Swizzles

static void (*PKHOrigLayoutSublayers)(id, SEL, CALayer *);
static void (*PKHOrigViewNeedsLayout)(id, SEL);
static void (*PKHOrigLayerNeedsLayout)(id, SEL);
static void (*PKHOrigInvalidateIntrinsic)(id, SEL);
static void (*PKHOrigSetBounds)(id, SEL, CGRect);
static void (*PKHOrigSetFrame)(id, SEL, CGRect);
static void (*PKHOrigSafeAreaDidChange)(id, SEL);
static void (*PKHOrigAdjustedInsetDidChange)(id, SEL);
static void (*PKHOrigSetContentOffset)(id, SEL, CGPoint);
static void (*PKHOrigSetContentInset)(id, SEL, UIEdgeInsets);
static void (*PKHOrigSetContentSize)(id, SEL, CGSize);

static void PKHLayoutSublayers(__unsafe_unretained id self, SEL _cmd, __unsafe_unretained CALayer *layer) {
    if (PKH_ON) PKHNote(PKHKindLayout, PKH_CLS(self), 0, ((UIView *)self).bounds);
    PKHOrigLayoutSublayers(self, _cmd, layer);
}

static void PKHViewNeedsLayout(__unsafe_unretained id self, SEL _cmd) {
    if (PKH_ON) PKHNote(PKHKindViewNeedsLayout, PKH_CLS(self), PKH_CALLER, CGRectZero);
    PKHOrigViewNeedsLayout(self, _cmd);
}

static void PKHLayerNeedsLayout(__unsafe_unretained id self, SEL _cmd) {
    if (PKH_ON) {
        __unsafe_unretained id delegate = ((CALayer *)self).delegate;
        PKHNote(PKHKindLayerNeedsLayout, delegate ? PKH_CLS(delegate) : PKH_CLS(self), PKH_CALLER, CGRectZero);
    }
    PKHOrigLayerNeedsLayout(self, _cmd);
}

static void PKHInvalidateIntrinsic(__unsafe_unretained id self, SEL _cmd) {
    if (PKH_ON) PKHNote(PKHKindInvalidateIntrinsic, PKH_CLS(self), PKH_CALLER, CGRectZero);
    PKHOrigInvalidateIntrinsic(self, _cmd);
}

static void PKHSetBounds(__unsafe_unretained id self, SEL _cmd, CGRect r) {
    if (PKH_ON) PKHNote(PKHKindSetBounds, PKH_CLS(self), PKH_CALLER, r);
    PKHOrigSetBounds(self, _cmd, r);
}

static void PKHSetFrame(__unsafe_unretained id self, SEL _cmd, CGRect r) {
    if (PKH_ON) PKHNote(PKHKindSetFrame, PKH_CLS(self), PKH_CALLER, r);
    PKHOrigSetFrame(self, _cmd, r);
}

static void PKHSafeAreaDidChange(__unsafe_unretained id self, SEL _cmd) {
    if (PKH_ON) PKHNote(PKHKindSafeArea, PKH_CLS(self), PKH_CALLER, CGRectZero);
    PKHOrigSafeAreaDidChange(self, _cmd);
}

static void PKHAdjustedInsetDidChange(__unsafe_unretained id self, SEL _cmd) {
    if (PKH_ON) PKHNote(PKHKindAdjustedInset, PKH_CLS(self), PKH_CALLER, PKH_INSETS(((UIScrollView *)self).adjustedContentInset));
    PKHOrigAdjustedInsetDidChange(self, _cmd);
}

static void PKHSetContentOffset(__unsafe_unretained id self, SEL _cmd, CGPoint p) {
    if (PKH_ON) PKHNote(PKHKindContentOffset, PKH_CLS(self), PKH_CALLER, CGRectMake(p.x, p.y, 0, 0));
    PKHOrigSetContentOffset(self, _cmd, p);
}

static void PKHSetContentInset(__unsafe_unretained id self, SEL _cmd, UIEdgeInsets i) {
    if (PKH_ON) PKHNote(PKHKindContentInset, PKH_CLS(self), PKH_CALLER, PKH_INSETS(i));
    PKHOrigSetContentInset(self, _cmd, i);
}

static void PKHSetContentSize(__unsafe_unretained id self, SEL _cmd, CGSize s) {
    if (PKH_ON) PKHNote(PKHKindContentSize, PKH_CLS(self), PKH_CALLER, CGRectMake(0, 0, s.width, s.height));
    PKHOrigSetContentSize(self, _cmd, s);
}

static void PKHSwizzle(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { os_log(PKHLog, "PKH swizzle missing %{public}s %{public}s", class_getName(cls), sel_getName(sel)); return; }
    *original = method_setImplementation(m, replacement);
}

// MARK: - Objective-C names for system code (built after recording, off the main thread)

typedef struct { uintptr_t imp; const char *cls; const char *sel; bool meta; } PKHMethod;
static PKHMethod *PKHMethods;
static size_t PKHMethodCount;

static int PKHMethodCompare(const void *a, const void *b) {
    uintptr_t x = ((const PKHMethod *)a)->imp, y = ((const PKHMethod *)b)->imp;
    return x < y ? -1 : x > y ? 1 : 0;
}

static void PKHAddMethods(Class cls, bool meta, size_t *capacity) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (PKHMethodCount == *capacity) {
            *capacity *= 2;
            PKHMethods = realloc(PKHMethods, *capacity * sizeof(PKHMethod));
        }
        PKHMethods[PKHMethodCount++] = (PKHMethod){ PKHStrip((uintptr_t)method_getImplementation(list[i])),
                                                    class_getName(cls), sel_getName(method_getName(list[i])), meta };
    }
    free(list);
}

static void PKHBuildMethodTable(void) {
    size_t capacity = 65536;
    PKHMethods = malloc(capacity * sizeof(PKHMethod));
    const char *wanted[] = { "/UIKitCore", "/SwiftUI", "/SwiftUICore", "/QuartzCore", "/AttributeGraph" };
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        bool take = false;
        for (size_t w = 0; w < sizeof(wanted) / sizeof(*wanted); w++) {
            size_t n = strlen(name), m = strlen(wanted[w]);
            if (n >= m && strcmp(name + n - m, wanted[w]) == 0) take = true;
        }
        if (!take) continue;
        unsigned int classes = 0;
        const char **names = objc_copyClassNamesForImage(name, &classes);
        for (unsigned int c = 0; c < classes; c++) {
            Class cls = objc_getClass(names[c]);
            if (!cls) continue;
            PKHAddMethods(cls, false, &capacity);
            PKHAddMethods(object_getClass(cls), true, &capacity);
        }
        free(names);
    }
    qsort(PKHMethods, PKHMethodCount, sizeof(PKHMethod), PKHMethodCompare);
}

static const PKHMethod *PKHMethodFor(uintptr_t pc) {
    if (!PKHMethodCount) return NULL;
    size_t lo = 0, hi = PKHMethodCount;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (PKHMethods[mid].imp <= pc) lo = mid + 1; else hi = mid;
    }
    if (lo == 0) return NULL;
    const PKHMethod *m = &PKHMethods[lo - 1];
    return pc - m->imp < 0x6000 ? m : NULL;
}

// MARK: - Sampling

static int PKHWalk(uintptr_t *out, int max) {
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(PKHMainThread, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) != KERN_SUCCESS) return 0;
    int n = 0;
    out[n++] = PKHStrip((uintptr_t)arm_thread_state64_get_pc(st));
    out[n++] = PKHStrip((uintptr_t)arm_thread_state64_get_lr(st));
    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
    while (n < max && fp >= PKHStackLow && fp + 16 <= PKHStackHigh && (fp & 7) == 0) {
        uintptr_t next = ((uintptr_t *)fp)[0];
        uintptr_t ret = PKHStrip(((uintptr_t *)fp)[1]);
        if (!ret) break;
        out[n++] = ret;
        if (next <= fp) break;
        fp = next;
    }
    return n;
}

static NSMutableDictionary<NSNumber *, NSString *> *PKHNames;

static NSString *PKHDescribe(uintptr_t pc) {
    if (!pc) return @"-";
    NSString *cached = PKHNames[@(pc)];
    if (cached) return cached;
    NSString *s;
    Dl_info info;
    if (dladdr((void *)pc, &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        base = base ? base + 1 : info.dli_fname;
        s = [NSString stringWithFormat:@"%s+0x%lx", base, (unsigned long)(pc - (uintptr_t)info.dli_fbase)];
        if (info.dli_sname && info.dli_saddr && strcmp(info.dli_sname, "<redacted>") != 0) {
            s = [s stringByAppendingFormat:@" [%s+%lu]", info.dli_sname, (unsigned long)(pc - (uintptr_t)info.dli_saddr)];
        }
    } else {
        s = [NSString stringWithFormat:@"0x%lx", (unsigned long)pc];
    }
    const PKHMethod *m = PKHMethodFor(pc);
    if (m) s = [s stringByAppendingFormat:@" {%c[%s %s]+%lu}", m->meta ? '+' : '-', m->cls, m->sel, (unsigned long)(pc - m->imp)];
    PKHNames[@(pc)] = s;
    return s;
}

static const char *PKHKindName(uintptr_t kind) {
    switch (kind) {
    case PKHKindLayout: return "layoutSublayersOfLayer";
    case PKHKindViewNeedsLayout: return "UIView.setNeedsLayout";
    case PKHKindLayerNeedsLayout: return "CALayer.setNeedsLayout";
    case PKHKindInvalidateIntrinsic: return "invalidateIntrinsicContentSize";
    case PKHKindSetBounds: return "UIView.setBounds";
    case PKHKindSetFrame: return "UIView.setFrame";
    case PKHKindSafeArea: return "safeAreaInsetsDidChange";
    case PKHKindAdjustedInset: return "adjustedContentInsetDidChange";
    case PKHKindContentOffset: return "UIScrollView.setContentOffset";
    case PKHKindContentInset: return "UIScrollView.setContentInset";
    case PKHKindContentSize: return "UIScrollView.setContentSize";
    default: return "?";
    }
}

static NSString *PKHExecutableInfo(void) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    NSMutableString *uuid = [NSMutableString string];
    const uint8_t *cmd = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_UUID) {
            const uint8_t *u = ((const struct uuid_command *)lc)->uuid;
            for (int j = 0; j < 16; j++) [uuid appendFormat:@"%02X", u[j]];
        }
        cmd += lc->cmdsize;
    }
    return [NSString stringWithFormat:@"executable %s base=0x%lx slide=0x%lx uuid=%@", _dyld_get_image_name(0),
            (unsigned long)header, (unsigned long)_dyld_get_image_vmaddr_slide(0), uuid];
}

static void PKHEmit(NSMutableString *report, NSString *line) {
    [report appendString:line];
    [report appendString:@"\n"];
    os_log(PKHLog, "PKH %{public}@", line);
}

static void PKHRecord(void) {
    double detected = PKHNow();
    uintptr_t (*stacks)[PKH_MAX_FRAMES] = calloc(PKH_MAX_SAMPLES, sizeof(*stacks));
    int *depths = calloc(PKH_MAX_SAMPLES, sizeof(int));
    if (!stacks || !depths) return;

    atomic_store(&PKHRecording, 1);
    int samples = 0;
    for (; samples < PKH_MAX_SAMPLES; samples++) {
        if (thread_suspend(PKHMainThread) != KERN_SUCCESS) break;
        depths[samples] = PKHWalk(stacks[samples], PKH_MAX_FRAMES);   // no allocation while suspended
        thread_resume(PKHMainThread);
        usleep(PKH_SAMPLE_USEC);
        if (atomic_load(&PKHBeatPending) == 0) { samples++; break; }   // the main thread turned again
    }
    atomic_store(&PKHRecording, 0);
    usleep(20000);

    PKHNames = [NSMutableDictionary dictionary];
    PKHBuildMethodTable();

    NSMutableString *report = [NSMutableString string];
    PKHEmit(report, [NSString stringWithFormat:@"=== launch hang report v2: stuck detected %.2f s after load, %d samples every %d us, %zu ObjC methods indexed ===",
                     detected - PKHLastBeat, samples, PKH_SAMPLE_USEC, PKHMethodCount]);
    PKHEmit(report, PKHExecutableInfo());
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *flags = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"pki-flags"] encoding:NSUTF8StringEncoding error:nil];
    PKHEmit(report, [NSString stringWithFormat:@"pki-flags: %@", flags.length ? [flags stringByReplacingOccurrencesOfString:@"\n" withString:@","] : @"(none)"]);

    PKHEmit(report, @"--- swizzle counters while recording (kind count receiverClass caller) ---");
    PKHSlot *sorted = calloc(PKH_TABLE, sizeof(PKHSlot));
    int used = 0;
    for (int i = 0; i < PKH_TABLE; i++) if (PKHSlots[i].count) sorted[used++] = PKHSlots[i];
    qsort_b(sorted, used, sizeof(PKHSlot), ^int(const void *a, const void *b) {
        unsigned long ca = ((const PKHSlot *)a)->count, cb = ((const PKHSlot *)b)->count;
        return ca < cb ? 1 : ca > cb ? -1 : 0;
    });
    for (int i = 0; i < used && i < 220; i++) {
        PKHSlot s = sorted[i];
        PKHEmit(report, [NSString stringWithFormat:@"%-30s %8lu %s %@", PKHKindName(s.kind), s.count,
                         class_getName((__bridge Class)(void *)s.key), PKHDescribe(s.caller)]);
    }
    free(sorted);

    PKHEmit(report, [NSString stringWithFormat:@"--- first %d events while recording, in order (kind class value caller) ---", PKHTraceCount]);
    for (int i = 0; i < PKHTraceCount; i++) {
        PKHEvent e = PKHTrace[i];
        PKHEmit(report, [NSString stringWithFormat:@"%4d %-30s %s {%.2f %.2f %.2f %.2f} %@", i, PKHKindName(e.kind),
                         class_getName((__bridge Class)(void *)e.key), e.value.origin.x, e.value.origin.y,
                         e.value.size.width, e.value.size.height, PKHDescribe(e.caller)]);
    }

    // Inclusive frame counts: each distinct pc counted once per sample.
    NSMutableDictionary<NSNumber *, NSNumber *> *inclusive = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *stackCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *stackSample = [NSMutableDictionary dictionary];
    for (int i = 0; i < samples; i++) {
        NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
        NSMutableString *sig = [NSMutableString string];
        for (int f = 0; f < depths[i]; f++) {
            NSNumber *pc = @(stacks[i][f]);
            if (![seen containsObject:pc]) {
                [seen addObject:pc];
                inclusive[pc] = @(inclusive[pc].unsignedLongValue + 1);
            }
            if (f < 40) [sig appendFormat:@"%lx,", (unsigned long)stacks[i][f]];
        }
        stackCounts[sig] = @(stackCounts[sig].unsignedLongValue + 1);
        if (!stackSample[sig]) stackSample[sig] = @(i);
    }
    NSArray<NSNumber *> *pcs = [inclusive keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    PKHEmit(report, @"--- frames by inclusive samples (top 160) ---");
    NSUInteger shown = 0;
    for (NSNumber *pc in pcs) {
        if (shown++ >= 160) break;
        unsigned long c = inclusive[pc].unsignedLongValue;
        PKHEmit(report, [NSString stringWithFormat:@"%6lu %5.1f%% 0x%lx %@", c, samples ? 100.0 * c / samples : 0,
                         pc.unsignedLongValue, PKHDescribe(pc.unsignedLongValue)]);
    }
    NSArray<NSString *> *sigs = [stackCounts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    PKHEmit(report, @"--- distinct stacks (top 6, first 40 frames, leaf first) ---");
    shown = 0;
    for (NSString *sig in sigs) {
        if (shown++ >= 6) break;
        int i = stackSample[sig].intValue;
        PKHEmit(report, [NSString stringWithFormat:@"stack x%lu (depth %d):", stackCounts[sig].unsignedLongValue, depths[i]]);
        for (int f = 0; f < depths[i] && f < 40; f++) {
            PKHEmit(report, [NSString stringWithFormat:@"    %2d 0x%lx %@", f, (unsigned long)stacks[i][f], PKHDescribe(stacks[i][f])]);
        }
    }
    int deepest = 0;
    for (int i = 1; i < samples; i++) if (depths[i] > depths[deepest]) deepest = i;
    if (samples > 0) {
        PKHEmit(report, [NSString stringWithFormat:@"--- deepest sample #%d (depth %d) ---", deepest, depths[deepest]]);
        for (int f = 0; f < depths[deepest]; f++) {
            PKHEmit(report, [NSString stringWithFormat:@"    %3d 0x%lx %@", f, (unsigned long)stacks[deepest][f], PKHDescribe(stacks[deepest][f])]);
        }
    }
    PKHEmit(report, @"=== end of launch hang report ===");

    NSString *path = [docs stringByAppendingPathComponent:@"launch-hang.txt"];
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    os_log(PKHLog, "PKH report written to %{public}@", path);
    free(stacks);
    free(depths);
}

static void *PKHWatch(void *unused) {
    pthread_setname_np("pki.hangprobe");
    double started = PKHNow();
    PKHLastBeat = started;
    while (!atomic_load(&PKHDone)) {
        double now = PKHNow();
        if (atomic_load(&PKHBeatPending) == 0) {
            atomic_store(&PKHBeatPending, 1);
            dispatch_async(dispatch_get_main_queue(), ^{
                PKHLastBeat = PKHNow();
                atomic_store(&PKHBeatPending, 0);
            });
        } else if (now - PKHLastBeat > 1.5) {
            os_log(PKHLog, "PKH main thread stuck for %.2f s (%.2f s after load): recording", now - PKHLastBeat, now - started);
            PKHRecord();
            atomic_store(&PKHDone, 1);
            break;
        }
        if (now - started > 90) {
            os_log(PKHLog, "PKH no hang in the first 90 s");
            break;
        }
        usleep(100000);
    }
    return NULL;
}

__attribute__((constructor)) static void PKHStart(void) {
    PKHLog = os_log_create("nz.zheha.poki.hangprobe", "launch");
    PKHMainThread = mach_thread_self();
    pthread_t main = pthread_self();
    PKHStackHigh = (uintptr_t)pthread_get_stackaddr_np(main);
    PKHStackLow = PKHStackHigh - pthread_get_stacksize_np(main);

    PKHSwizzle([UIView class], @selector(layoutSublayersOfLayer:), (IMP)PKHLayoutSublayers, (IMP *)&PKHOrigLayoutSublayers);
    PKHSwizzle([UIView class], @selector(setNeedsLayout), (IMP)PKHViewNeedsLayout, (IMP *)&PKHOrigViewNeedsLayout);
    PKHSwizzle([CALayer class], @selector(setNeedsLayout), (IMP)PKHLayerNeedsLayout, (IMP *)&PKHOrigLayerNeedsLayout);
    PKHSwizzle([UIView class], @selector(invalidateIntrinsicContentSize), (IMP)PKHInvalidateIntrinsic, (IMP *)&PKHOrigInvalidateIntrinsic);
    PKHSwizzle([UIView class], @selector(setBounds:), (IMP)PKHSetBounds, (IMP *)&PKHOrigSetBounds);
    PKHSwizzle([UIView class], @selector(setFrame:), (IMP)PKHSetFrame, (IMP *)&PKHOrigSetFrame);
    PKHSwizzle([UIView class], @selector(safeAreaInsetsDidChange), (IMP)PKHSafeAreaDidChange, (IMP *)&PKHOrigSafeAreaDidChange);
    PKHSwizzle([UIScrollView class], @selector(adjustedContentInsetDidChange), (IMP)PKHAdjustedInsetDidChange, (IMP *)&PKHOrigAdjustedInsetDidChange);
    PKHSwizzle([UIScrollView class], @selector(setContentOffset:), (IMP)PKHSetContentOffset, (IMP *)&PKHOrigSetContentOffset);
    PKHSwizzle([UIScrollView class], @selector(setContentInset:), (IMP)PKHSetContentInset, (IMP *)&PKHOrigSetContentInset);
    PKHSwizzle([UIScrollView class], @selector(setContentSize:), (IMP)PKHSetContentSize, (IMP *)&PKHOrigSetContentSize);

    pthread_t watcher;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&watcher, &attr, PKHWatch, NULL);
    pthread_attr_destroy(&attr);
    os_log(PKHLog, "PKH armed: main stack 0x%lx-0x%lx", (unsigned long)PKHStackLow, (unsigned long)PKHStackHigh);
}

#endif  // __arm64__
