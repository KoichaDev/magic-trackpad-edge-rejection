#include "MultitouchAdapter.h"
#include "RawContactFilter.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

// Reverse-engineered ABI, checked against Subsurface at commit 88eb16b.
// Observation copies contacts. Experimental rejection rewrites an owned raw
// packet and reinjects it through Apple's existing driver filter-client route.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t id, state, finger, hand;
    MTVector normalized;
    float capacitance, pressure, angle, major_axis, minor_axis;
    MTVector absolute;
    float reserved1, reserved2, density;
} MTRawContact;
_Static_assert(sizeof(MTRawContact) == 96, "Unexpected contact ABI");
_Static_assert(offsetof(MTRawContact, normalized) == 32, "Unexpected position offset");
typedef void *MTDevice;
typedef int32_t (*MTCallback)(MTDevice, void *, int32_t, double, int32_t);

static void *framework;
static CFMutableArrayRef (*create_list)(void);
static bool (*is_builtin)(MTDevice);
static int32_t (*get_id)(MTDevice, uint64_t *);
static int32_t (*get_family)(MTDevice, int32_t *);
static io_service_t (*get_service)(MTDevice);
static void (*register_callback)(MTDevice, MTCallback);
static void (*unregister_callback)(MTDevice, MTCallback);
static int32_t (*start_device)(MTDevice, int32_t);
static int32_t (*stop_device)(MTDevice);
static MTDevice selected;
static uint64_t selected_id;
static TEFrameCallback consumer;
static void *consumer_context;
static pthread_mutex_t callback_lock = PTHREAD_MUTEX_INITIALIZER;
static char error_text[256];
typedef void (*MTRawCallback)(MTDevice, void *, int32_t, void *);
static bool (*register_raw)(MTDevice, MTRawCallback, void *);
static void (*unregister_raw)(MTDevice, MTRawCallback);
static int32_t (*inject_frame)(MTDevice, void *, int32_t);
static int32_t (*get_driver_type)(MTDevice, int32_t *);
static TERawFilter raw_filter;
static TEFilterStats filter_stats;
static bool rejection_session;
static uint8_t last_header[4];
static bool raw_capture_enabled;
static TERawRecord raw_capture[TE_RAW_CAPTURE_CAPACITY];
static size_t raw_capture_next, raw_capture_count;
static uint64_t raw_capture_packets;
static bool have_header;

static bool load_symbols(void) {
    if (framework) return true;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        snprintf(error_text, sizeof(error_text), "MultitouchSupport unavailable: %s", dlerror());
        return false;
    }
#define LOAD(variable, name) do { \
    *(void **)(&variable) = dlsym(handle, name); \
    if (!variable) { snprintf(error_text, sizeof(error_text), "Missing private symbol: %s", name); dlclose(handle); return false; } \
} while (0)
    LOAD(create_list, "MTDeviceCreateList");
    LOAD(is_builtin, "MTDeviceIsBuiltIn");
    LOAD(get_id, "MTDeviceGetDeviceID");
    LOAD(get_family, "MTDeviceGetFamilyID");
    LOAD(get_service, "MTDeviceGetService");
    LOAD(register_callback, "MTRegisterContactFrameCallback");
    LOAD(unregister_callback, "MTUnregisterContactFrameCallback");
    LOAD(start_device, "MTDeviceStart");
    LOAD(stop_device, "MTDeviceStop");
    LOAD(register_raw, "MTRegisterFullFrameCallback");
    LOAD(unregister_raw, "MTUnregisterFullFrameCallback");
    LOAD(inject_frame, "MTDeviceInjectFrame");
    LOAD(get_driver_type, "MTDeviceGetDriverType");
#undef LOAD
    // Keep the framework loaded for process lifetime; callbacks use its code.
    framework = handle;
    return true;
}

static void property_string(io_service_t service, CFStringRef key, char *out, size_t size) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value) {
        if (CFGetTypeID(value) == CFStringGetTypeID())
            CFStringGetCString(value, out, size, kCFStringEncodingUTF8);
        CFRelease(value);
    }
}

static bool describe(MTDevice device, TEDevice *out) {
    memset(out, 0, sizeof(*out));
    if (get_id(device, &out->id) != 0 || get_family(device, &out->family) != 0) return false;
    out->built_in = is_builtin(device);
    io_service_t service = get_service(device); // Borrowed; do not release it.
    if (service) {
        property_string(service, CFSTR("Product"), out->product, sizeof(out->product));
        property_string(service, CFSTR("Transport"), out->transport, sizeof(out->transport));
    }
    // Fail closed on unknown identity. Never silently select the default device.
    // MTDeviceIsAlive remained false for an enumerated, connected device on
    // macOS 15.7.5 (observed). Use registry membership rather than this private flag.
    out->eligible = !out->built_in
        && (out->family == 128 || out->family == 129 || out->family == 130)
        && strstr(out->product, "Magic Trackpad") != NULL
        && strcmp(out->transport, "Bluetooth") == 0;
    return true;
}

int32_t te_list_devices(TEDevice *devices, int32_t capacity) {
    error_text[0] = 0;
    if (!load_symbols()) return -1;
    CFMutableArrayRef list = create_list();
    if (!list) { snprintf(error_text, sizeof(error_text), "Cannot enumerate multitouch devices"); return -1; }
    int32_t count = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        TEDevice info;
        MTDevice device = (MTDevice)CFArrayGetValueAtIndex(list, i);
        if (device && describe(device, &info)) {
            if (count < capacity && devices) devices[count] = info;
            count++;
        }
    }
    CFRelease(list);
    return count;
}

static int32_t receive_frame(MTDevice device, void *data, int32_t count, double timestamp, int32_t frame) {
    pthread_mutex_lock(&callback_lock);
    if (device == selected && consumer) {
        TEContact contacts[32];
        bool valid = count >= 0 && count <= 32 && (count == 0 || data != NULL) && isfinite(timestamp);
        MTRawContact *raw = data;
        for (int32_t i = 0; valid && i < count; i++) {
            float x = raw[i].normalized.position.x, y = raw[i].normalized.position.y;
            valid = isfinite(x) && isfinite(y) && x >= 0 && x <= 1 && y >= 0 && y <= 1
                && raw[i].state >= 0 && raw[i].state <= 7;
            contacts[i] = (TEContact){raw[i].id, raw[i].state, x, y,
                raw[i].pressure, raw[i].major_axis, raw[i].minor_axis};
        }
        // Negative count is an explicit ABI/validation failure, never a touch frame.
        consumer(valid ? contacts : NULL, valid ? count : -1, timestamp, frame, consumer_context);
    }
    pthread_mutex_unlock(&callback_lock);
    return 0; // Observation callback result, not a request to suppress a touch.
}

void te_raw_capture_enable(bool enabled) {
    pthread_mutex_lock(&callback_lock);
    raw_capture_enabled = enabled;
    raw_capture_next = raw_capture_count = 0; raw_capture_packets = 0;
    pthread_mutex_unlock(&callback_lock);
}

size_t te_raw_capture_read(TERawRecord *out, size_t capacity) {
    pthread_mutex_lock(&callback_lock);
    size_t n = raw_capture_count < capacity ? raw_capture_count : capacity;
    size_t start = (raw_capture_next + TE_RAW_CAPTURE_CAPACITY - raw_capture_count) % TE_RAW_CAPTURE_CAPACITY;
    for (size_t i = 0; out && i < n; i++) out[i] = raw_capture[(start + (raw_capture_count - n) + i) % TE_RAW_CAPTURE_CAPACITY];
    pthread_mutex_unlock(&callback_lock);
    return n;
}

static void receive_raw(MTDevice device, void *bytes, int32_t size, void *context) {
    (void)context;
    pthread_mutex_lock(&callback_lock);
    if (device == selected && rejection_session) {
        uint8_t output[4096];
        size_t output_size = 0;
        filter_stats.packets++;
        bool valid = size > 0 && size <= (int32_t)sizeof(output) && bytes;
        if (raw_capture_enabled && valid && size >= 4 && ((const uint8_t *)bytes)[0] == 0x31 && (size - 4) % 9 == 0) {
            const uint8_t *in = bytes;
            raw_capture_packets++;
            for (size_t pos = 4; pos + 9 <= (size_t)size; pos += 9) {
                TERawRecord *slot = &raw_capture[raw_capture_next];
                slot->packet = raw_capture_packets;
                memcpy(slot->header, in, 4);
                memcpy(slot->contact, in + pos, 9);
                raw_capture_next = (raw_capture_next + 1) % TE_RAW_CAPTURE_CAPACITY;
                if (raw_capture_count < TE_RAW_CAPTURE_CAPACITY) raw_capture_count++;
            }
        }
        if (valid && filter_stats.enabled) {
            valid = te_filter_packet(&raw_filter, bytes, (size_t)size, output, sizeof(output), &output_size);
            if (!valid) { filter_stats.error = -1; filter_stats.enabled = false; }
        }
        if (size > 0 && size <= (int32_t)sizeof(output) && bytes) {
            // On validation failure, immediately forward the original and keep
            // forwarding unchanged until the session controller closes us.
            if (!filter_stats.enabled) { memcpy(output, bytes, (size_t)size); output_size = (size_t)size; }
            if (output_size >= 4 && output[0] == 0x31) { memcpy(last_header, output, 4); have_header = true; }
            int32_t status = inject_frame(device, output, (int32_t)output_size);
            if (status) { filter_stats.error = status; filter_stats.enabled = false; }
        } else { filter_stats.error = -2; filter_stats.enabled = false; }
    }
    pthread_mutex_unlock(&callback_lock);
}

static bool start_session(uint64_t device_id, TEFrameCallback callback, void *context, bool reject,
    double left, double right, double top, double bottom) {
    te_stop();
    error_text[0] = 0;
    if (!load_symbols() || !callback) return false;
    CFMutableArrayRef list = create_list();
    if (!list) { snprintf(error_text, sizeof(error_text), "Cannot enumerate multitouch devices"); return false; }
    MTDevice target = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        MTDevice device = (MTDevice)CFArrayGetValueAtIndex(list, i);
        TEDevice info;
        if (describe(device, &info) && info.id == device_id && info.eligible) {
            target = device;
            CFRetain(target);
            break;
        }
    }
    CFRelease(list);
    if (!target) { snprintf(error_text, sizeof(error_text), "Selected Bluetooth Magic Trackpad is unavailable or ineligible"); return false; }
    TERawFilter configuration = {.left=left, .right=right, .top=top, .bottom=bottom};
    if (reject) {
        char os[64] = {0}; size_t os_size = sizeof(os);
        int32_t type = 0; TEDevice identity;
        io_service_t service = get_service(target);
        CFTypeRef desc = IORegistryEntryCreateCFProperty(service, CFSTR("Sensor Surface Descriptor"), kCFAllocatorDefault, 0);
        CFTypeRef parser = IORegistryEntryCreateCFProperty(service, CFSTR("parser-type"), kCFAllocatorDefault, 0);
        int32_t parser_type = 0;
        if (parser && CFGetTypeID(parser) == CFNumberGetTypeID()) CFNumberGetValue(parser, kCFNumberSInt32Type, &parser_type);
        const char *reason = NULL;
        // Any macOS 15.x is accepted; the descriptor, parser and packet
        // checks below still have to pass, and te_filter_packet fails closed.
        if (sysctlbyname("kern.osproductversion", os, &os_size, NULL, 0) != 0 || strncmp(os, "15.", 3) != 0)
            reason = "Unsupported macOS version: native rejection supports macOS 15.x only";
        else if (!describe(target, &identity) || identity.family != 129
                 || get_driver_type(target, &type) != 0 || type != 4 || parser_type != 1000)
            reason = "Unsupported trackpad: native rejection needs a Bluetooth Magic Trackpad (family 129, Compact V7)";
        else if (!desc || CFGetTypeID(desc) != CFDataGetTypeID() || CFDataGetLength(desc) != 16)
            reason = "Unsupported trackpad: sensor surface descriptor has an unexpected format";
        if (!reason) {
            const uint8_t *d = CFDataGetBytePtr(desc);
            configuration.min_x = (int16_t)(d[8] | (d[9] << 8));
            configuration.min_y = (int16_t)(d[10] | (d[11] << 8));
            configuration.max_x = (int16_t)(d[12] | (d[13] << 8));
            configuration.max_y = (int16_t)(d[14] | (d[15] << 8));
            if (configuration.max_x <= configuration.min_x || configuration.max_y <= configuration.min_y)
                reason = "Unsupported trackpad: sensor surface descriptor has invalid bounds";
        }
        if (desc) CFRelease(desc); if (parser) CFRelease(parser);
        uint8_t empty[4] = {0x31,0,0,0}, result[4]; size_t result_size;
        if (!reason && !te_filter_packet(&configuration, empty, 4, result, 4, &result_size))
            reason = "Native rejection settings were rejected by the packet filter";
        if (reason) {
            CFRelease(target);
            snprintf(error_text, sizeof(error_text), "%s", reason);
            return false;
        }
    }
    pthread_mutex_lock(&callback_lock);
    selected = target;
    selected_id = device_id;
    consumer = callback;
    consumer_context = context;
    raw_filter = configuration;
    filter_stats = (TEFilterStats){.enabled=reject};
    rejection_session = reject; have_header = false;
    pthread_mutex_unlock(&callback_lock);
    register_callback(target, receive_frame);
    if (reject && !register_raw(target, receive_raw, NULL)) {
        snprintf(error_text, sizeof(error_text), "Cannot register native raw-frame callback"); te_stop(); return false;
    }
    // Bit 30 makes IOServiceOpen use client type 'FLTR'. Bit 31 does NOT.
    int32_t status = start_device(target, reject ? 0x40000000 : 0);
    if (status != 0) {
        snprintf(error_text, sizeof(error_text), "MTDeviceStart failed: %d", status);
        te_stop();
        return false;
    }
    if (reject) {
        // Confirm that the driver actually created a filter client. Successful
        // MTDeviceStart alone also occurs for ordinary observation clients.
        io_iterator_t children = IO_OBJECT_NULL;
        bool verified = false;
        char prefix[64]; snprintf(prefix, sizeof(prefix), "pid %d,", getpid());
        if (IORegistryEntryGetChildIterator(get_service(target), kIOServicePlane, &children) == KERN_SUCCESS) {
            io_registry_entry_t child;
            while ((child = IOIteratorNext(children))) {
                char creator[256] = {0}; property_string(child, CFSTR("IOUserClientCreator"), creator, sizeof(creator));
                CFTypeRef value = IORegistryEntryCreateCFProperty(child, CFSTR("FilterEnabled"), kCFAllocatorDefault, 0);
                if (strncmp(creator, prefix, strlen(prefix)) == 0 && value && CFEqual(value, kCFBooleanTrue)) verified = true;
                if (value) CFRelease(value); IOObjectRelease(child);
            }
            IOObjectRelease(children);
        }
        if (!verified) {
            snprintf(error_text, sizeof(error_text), "Driver did not confirm FilterEnabled for this process; refusing rejection");
            te_stop(); return false;
        }
    }
    return true;
}

bool te_start(uint64_t id, TEFrameCallback callback, void *context) {
    return start_session(id, callback, context, false, .1, .1, .1, .1);
}
bool te_start_rejection(uint64_t id, TEFrameCallback callback, void *context,
    double left, double right, double top, double bottom) {
    return start_session(id, callback, context, true, left, right, top, bottom);
}
void te_set_margins(double left, double right, double top, double bottom) {
    pthread_mutex_lock(&callback_lock);
    raw_filter.left=left; raw_filter.right=right; raw_filter.top=top; raw_filter.bottom=bottom;
    pthread_mutex_unlock(&callback_lock);
}
TEFilterStats te_filter_stats(void) {
    pthread_mutex_lock(&callback_lock);
    TEFilterStats result=filter_stats;
    result.removed_contacts=raw_filter.removed_contacts;
    result.reentries=raw_filter.reentries;
    result.blocked_clicks=raw_filter.blocked_clicks;
    pthread_mutex_unlock(&callback_lock);
    return result;
}

void te_stop(void) {
    pthread_mutex_lock(&callback_lock);
    MTDevice old = selected;
    bool was_rejecting = rejection_session;
    if (old && was_rejecting && have_header && filter_stats.enabled) {
        uint8_t release[4]; memcpy(release, last_header, 4); release[1] &= ~7u;
        // Clear only this trackpad's native contacts/buttons before giving its
        // original stream back. The native driver routes this to normal clients.
        inject_frame(old, release, 4);
    }
    selected = NULL;
    selected_id = 0;
    consumer = NULL;
    consumer_context = NULL;
    rejection_session = false; filter_stats.enabled = false;
    pthread_mutex_unlock(&callback_lock);
    // Clearing under the callback lock drains an in-flight callback before its
    // Swift context can be released. Late callbacks see no consumer.
    if (old) {
        if (was_rejecting) unregister_raw(old, receive_raw);
        unregister_callback(old, receive_frame);
        stop_device(old);
        CFRelease(old);
    }
}

bool te_is_alive(void) {
    if (!selected) return false;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &iterator) != KERN_SUCCESS)
        return false;
    bool found = false;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
        int64_t id = 0;
        if (value && CFGetTypeID(value) == CFNumberGetTypeID()
            && CFNumberGetValue(value, kCFNumberSInt64Type, &id) && (uint64_t)id == selected_id)
            found = true;
        if (value) CFRelease(value);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return found;
}
const char *te_last_error(void) { return error_text; }
size_t te_contact_abi_size(void) { return sizeof(MTRawContact); }
