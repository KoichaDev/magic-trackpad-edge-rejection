#ifndef MULTITOUCH_ADAPTER_H
#define MULTITOUCH_ADAPTER_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "RawContactFilter.h"

typedef struct {
    uint64_t id;
    int32_t family;
    bool built_in;
    bool eligible;
    char product[128];
    char transport[32];
} TEDevice;

typedef struct {
    int32_t id;
    int32_t state;
    float x, y, pressure, major_axis, minor_axis;
} TEContact;

// One observation session per process. Calls to start/stop/enumerate are serialized
// by the caller. Callback data is valid only until the callback returns.
typedef void (*TEFrameCallback)(const TEContact *, int32_t, double, int32_t, void *);
int32_t te_list_devices(TEDevice *devices, int32_t capacity);
bool te_start(uint64_t device_id, TEFrameCallback callback, void *context);
typedef struct {
    uint64_t packets, removed_contacts, reentries, blocked_clicks;
    int32_t error;
    bool enabled;
} TEFilterStats;
// Experimental native raw filter, restricted to the validated V7 device/OS.
bool te_start_rejection(uint64_t device_id, TEFrameCallback callback, void *context,
    double left, double right, double top, double bottom);
void te_set_margins(double left, double right, double top, double bottom);
// Reject center contacts whose raw major-axis byte is >= limit (1-255). 0 disables.
// Takes effect immediately and applies to later sessions.
void te_set_palm_limit(uint8_t limit);
TEFilterStats te_filter_stats(void);
// Opt-in diagnostic capture of the undecoded 9-byte contact records of each
// original (pre-filter) V7 packet, for finding size/pressure fields. Off by
// default and only fills during a rejection session. The ring keeps the newest
// TE_RAW_CAPTURE_CAPACITY records.
#define TE_RAW_CAPTURE_CAPACITY 16384
typedef struct {
    uint64_t packet;      // 1-based packet number within the session
    uint8_t header[4];    // report id, button/flags, and the two remaining header bytes
    uint8_t contact[9];   // the raw contact record, unmodified
} TERawRecord;
void te_raw_capture_enable(bool enabled);
size_t te_raw_capture_read(TERawRecord *out, size_t capacity); // oldest first
void te_stop(void);
bool te_is_alive(void);
const char *te_last_error(void);
size_t te_contact_abi_size(void);
#endif
