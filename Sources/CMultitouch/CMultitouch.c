#include "CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stddef.h>

// Layout of the private MultitouchSupport contact record (stable since 10.5).
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, foo3, foo4;
    MTReadout normalized;
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTReadout mm;
    int zero2[2];
    float unk2;
} MTFinger;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTFinger *, int, double, int);

static CFMutableArrayRef (*pCreateList)(void);
static void (*pRegister)(MTDeviceRef, MTContactCallback);
static void (*pUnregister)(MTDeviceRef, MTContactCallback);
static void (*pStart)(MTDeviceRef, int);
static void (*pStop)(MTDeviceRef);

static vmt_tap_handler gHandler;
static CFMutableArrayRef gDevices;
static double gMaxDuration = 0.35;
static double gMaxMovement = 0.03;

// Gesture state.
static int touching, maxFingers;
static double startTime;
static float startX, startY, maxMove;

void vmt_set_thresholds(double max_duration, double max_movement) {
    gMaxDuration = max_duration;
    gMaxMovement = max_movement;
}

void vmt_reset_state(void) { touching = 0; maxFingers = 0; maxMove = 0; }

int vmt_feed_frame(int n, float cx, float cy, double ts) {
    if (n > 0) {
        if (!touching) {
            touching = 1; maxFingers = n; startTime = ts;
            startX = cx; startY = cy; maxMove = 0;
        } else if (n > maxFingers) {
            // More fingers landed: re-anchor the centroid.
            maxFingers = n; startX = cx; startY = cy;
        } else if (n == maxFingers) {
            float d = hypotf(cx - startX, cy - startY);
            if (d > maxMove) maxMove = d;
        }
        return 0;
    }
    if (!touching) return 0;
    touching = 0;
    double dur = ts - startTime;
    return (maxFingers == 3 && dur < gMaxDuration && maxMove < gMaxMovement) ? 1 : 0;
}

static vmt_frame_logger gLogger;
static long gFrames;
static int gLastActive = -1, gLastTotal = -1;

void vmt_set_frame_logger(vmt_frame_logger logger) { gLogger = logger; }
long vmt_frame_count(void) { return gFrames; }

int vmt_active_count(const int *states, int n) {
    int a = 0;
    for (int i = 0; i < n; i++) if (states[i] == 3 || states[i] == 4) a++;
    return a;
}

// MultitouchSupport keeps reporting contacts while they lift off (BreakTouch, Linger,
// OutOfRange) and may never send an empty frame, so count only touching contacts.
static int contactCallback(MTDeviceRef dev, MTFinger *f, int n, double ts, int frame) {
    (void)dev; (void)frame;
    gFrames++;
    int states[16]; int m = n < 16 ? n : 16;
    float cx = 0, cy = 0; int active = 0;
    for (int i = 0; i < m; i++) {
        states[i] = f[i].state;
        if (f[i].state == 3 || f[i].state == 4) {
            cx += f[i].normalized.pos.x; cy += f[i].normalized.pos.y; active++;
        }
    }
    if (active > 0) { cx /= active; cy /= active; }
    if (gLogger && (active != gLastActive || n != gLastTotal)) gLogger(n, active, states, ts);
    gLastActive = active; gLastTotal = n;
    if (vmt_feed_frame(active, cx, cy, ts) && gHandler) gHandler();
    return 0;
}

static int loadSymbols(void) {
    if (pCreateList) return 1;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) return 0;
    pCreateList = dlsym(h, "MTDeviceCreateList");
    pRegister = dlsym(h, "MTRegisterContactFrameCallback");
    pUnregister = dlsym(h, "MTUnregisterContactFrameCallback");
    pStart = dlsym(h, "MTDeviceStart");
    pStop = dlsym(h, "MTDeviceStop");
    return pCreateList && pRegister && pStart;
}

int vmt_start(vmt_tap_handler handler) {
    if (!loadSymbols()) return -1;
    vmt_stop();
    gHandler = handler;
    vmt_reset_state();
    gFrames = 0;
    gDevices = pCreateList();
    if (!gDevices) return 0;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pRegister(d, contactCallback);
        pStart(d, 0);
    }
    return (int)count;
}

void vmt_stop(void) {
    if (!gDevices) return;
    CFIndex count = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        if (pUnregister) pUnregister(d, contactCallback);
        if (pStop) pStop(d);
    }
    CFRelease(gDevices);
    gDevices = NULL;
    gHandler = NULL;
}
