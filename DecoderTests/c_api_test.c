/* SPDX-License-Identifier: AGPL-3.0-only */
#include "TrueHDDecoder.h"
int sthd_c_header_test(void) {
    STHDLayout layout;
    STHDDecoder *decoder = sthd_decoder_create();
    if (!decoder)
        return 0;
    sthd_decoder_reset(decoder);
    sthd_decoder_destroy(decoder);
    return sthd_layout_named("9.1.6", &layout) == STHD_OK && layout.channels == 16;
}
