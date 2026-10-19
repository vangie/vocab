#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

/// Called (on a private MultitouchSupport thread) when a three-finger tap is detected.
typedef void (*vmt_tap_handler)(void);

/// Load MultitouchSupport.framework, register a contact-frame callback on every
/// multitouch device and start them. Returns the number of devices started, or -1
/// if the private framework or its symbols could not be loaded.
int vmt_start(vmt_tap_handler handler);

/// Stop all devices started by vmt_start.
void vmt_stop(void);

/// Tuning knobs (defaults: 0.35 s, 0.03 normalised units).
void vmt_set_thresholds(double max_duration, double max_movement);

/// Exposed for unit tests: feed a synthetic frame (n fingers at centroid cx, cy).
/// Returns 1 when this frame completes a three-finger tap.
int vmt_feed_frame(int n, float cx, float cy, double timestamp);
void vmt_reset_state(void);

/// Optional diagnostics: called for frames whose touching-finger count changed.
/// total = contacts reported, active = contacts actually touching, states = per-contact state codes.
typedef void (*vmt_frame_logger)(int total, int active, const int *states, double timestamp);
void vmt_set_frame_logger(vmt_frame_logger logger);

/// Number of frames received since vmt_start (to confirm the callback fires).
long vmt_frame_count(void);

/// Count of contacts in a "touching" state (MakeTouch=3, Touching=4).
int vmt_active_count(const int *states, int n);

#endif
