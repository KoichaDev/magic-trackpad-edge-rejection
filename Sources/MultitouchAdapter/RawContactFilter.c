#include "RawContactFilter.h"
#include <math.h>
#include <string.h>

static int signed13(unsigned value) { return value & 4096 ? (int)value - 8192 : (int)value; }

bool te_filter_packet(TERawFilter *f, const uint8_t *in, size_t size,
                      uint8_t *out, size_t capacity, size_t *out_size) {
    if (!f || !in || !out || !out_size || !size || size > capacity) return false;
    if (in[0] != 0x31) { memcpy(out, in, size); *out_size = size; return true; }
    if (size < 4 || (size - 4) % 9 || (size - 4) / 9 > 16
        || f->max_x <= f->min_x || f->max_y <= f->min_y) return false;
    const double margins[] = {f->left, f->right, f->top, f->bottom};
    for (int i = 0; i < 4; i++) if (!isfinite(margins[i]) || margins[i] < 0 || margins[i] > .45) return false;
    uint16_t seen = 0, admitted = 0;
    size_t written = 4;
    unsigned active_center = 0;
    memcpy(out, in, 4);
    // Validate the entire frame before changing persistent state.
    for (size_t pos = 4; pos < size; pos += 9) {
        uint16_t bit = (uint16_t)(1u << (in[pos + 8] & 15));
        if (seen & bit) return false;
        seen |= bit;
    }
    for (size_t pos = 4; pos < size; pos += 9) {
        const uint8_t *c = in + pos;
        uint16_t bit = (uint16_t)(1u << (c[8] & 15));
        unsigned state = c[3] >> 5;
        // Apple's V7 decoder scales signed raw coordinates by two and offsets
        // Y by 5000; the device's Sensor Surface Descriptor supplies bounds.
        int px = 2 * signed13(c[0] | ((c[1] & 31u) << 8));
        int py = 5000 + 2 * signed13((c[1] >> 5) | (c[2] << 3) | ((c[3] & 3u) << 11));
        double x = (double)(px - f->min_x) / (f->max_x - f->min_x);
        double y = (double)(py - f->min_y) / (f->max_y - f->min_y);
        bool center = x >= f->left && x <= 1 - f->right && y >= f->bottom && y <= 1 - f->top;
        // An already admitted liftoff must reach the native recognizer even if
        // its final coordinate falls over the boundary. New edge paths vanish.
        bool ending = state == 5 || state == 6 || state == 7;
        if (!center && !(ending && (f->admitted & bit))) { f->removed_contacts++; continue; }
        memcpy(out + written, c, 9);
        if (state == 4 && !(f->admitted & bit)) {
            out[written + 3] = (c[3] & 31u) | (3u << 5);
            f->reentries++;
        }
        if (state == 3 || state == 4) active_center++;
        if (!ending) admitted |= bit;
        written += 9;
    }
    uint8_t physical = in[1] & 3;
    uint8_t rising = physical & ~f->physical_buttons;
    if (active_center) f->accepted_buttons |= rising;
    else if (rising) f->blocked_clicks++;
    f->accepted_buttons &= physical; // Never swallow a real button release.
    f->physical_buttons = physical;
    // V7 bit 2 is force-stage indication, not part of its timestamp. Rejected
    // edge force must not turn into a native force click.
    out[1] = (out[1] & ~7u) | f->accepted_buttons | ((active_center || f->accepted_buttons) ? (in[1] & 4u) : 0);
    f->admitted = admitted;
    *out_size = written;
    return true;
}
