#ifndef RAW_CONTACT_FILTER_H
#define RAW_CONTACT_FILTER_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

typedef struct {
    double left, right, top, bottom;
    int16_t min_x, min_y, max_x, max_y;
    uint16_t admitted;
    uint8_t physical_buttons, accepted_buttons;
    uint64_t removed_contacts, reentries, blocked_clicks;
} TERawFilter;

// Compact V7 (0x31): four-byte header followed by nine-byte contacts.
// Output always contains a complete frame, including an empty contact frame.
// Non-contact reports pass unchanged. Invalid touch reports return false.
bool te_filter_packet(TERawFilter *filter, const uint8_t *input, size_t size,
                      uint8_t *output, size_t capacity, size_t *output_size);
#endif
