/* SPDX-License-Identifier: AGPL-3.0-only */
#include "TrueHDDecoder.h"
int sthd_c_header_test(void) {
    STHDLayout layout;
    STHDPlayerOptions options = {0};
    char error[256];
    options.struct_size = sizeof(options);
    options.gain = 0;
    STHDPlayer *player = sthd_player_create(&options, error, sizeof(error));
    if (!player || sthd_abi_version() != STHD_ABI_VERSION)
        return 0;
    sthd_player_cancel(player);
    size_t consumed = 99;
    if (sthd_player_feed(player, 0, 0, &consumed, 0) != STHD_CANCELLED || consumed != 0)
        return 0;
    sthd_player_destroy(player);
    STHDDecoder *decoder = sthd_decoder_create();
    if (!decoder)
        return 0;
    sthd_decoder_reset(decoder);
    sthd_decoder_destroy(decoder);
    return sthd_layout_named("9.1.6", &layout) == STHD_OK && layout.channels == 16;
}
