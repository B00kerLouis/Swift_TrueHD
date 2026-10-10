/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include "TrueHDDecoder.h"
int sthd_c_header_test(void) {
    if (sthd_audio_write_pcm(0, 0, 0, 0, 0) != STHD_INVALID_ARGUMENT)
        return 0;
    if (sthd_decoder_clone(0) != 0) return 0;
    STHDPlaybackLevels levels = {0};
    if (sthd_decoder_playback_levels(0, &levels) != STHD_INVALID_ARGUMENT) return 0;
    STHDLayout layout;
    STHDPlayerOptions options = {0};
    char error[256];
    options.struct_size = sizeof(options);
    options.gain = 0;
    STHDPlayer *player = sthd_player_create(&options, error, sizeof(error));
    if (!player || sthd_abi_version() != STHD_ABI_VERSION)
        return 0;
    STHDFrameMotion motion = {0};
    STHDPCMChecksum checksum = {0};
    if (sthd_player_last_motion(player, &motion) != STHD_NEED_RESTART ||
        sthd_player_pcm_checksum(player, &checksum) != STHD_OK || checksum.total_mismatches ||
        sthd_player_set_strict_pcm_checksum(player, 1) != STHD_OK)
        return 0;
    if (sthd_player_end_of_stream(player) != 0 || sthd_player_end_of_stream(0) != 0)
        return 0;
    sthd_player_cancel(player);
    size_t consumed = 99;
    if (sthd_player_feed(player, 0, 0, &consumed, 0) != STHD_CANCELLED || consumed != 0)
        return 0;
    sthd_player_destroy(player);
    STHDDecoder *decoder = sthd_decoder_create();
    if (!decoder)
        return 0;
    if (sthd_decoder_playback_levels(decoder, &levels) != STHD_NEED_RESTART) return 0;
    STHDDecoder *cloned = sthd_decoder_clone(decoder);
    if (!cloned || sthd_decoder_playback_levels(cloned, &levels) != STHD_NEED_RESTART) return 0;
    sthd_decoder_destroy(cloned);
    if (sthd_decoder_drc_valid(decoder) != 0 || sthd_decoder_drc_valid(0) != 0) {
        sthd_decoder_destroy(decoder);
        return 0;
    }
    if (sthd_decoder_motion(decoder, &motion) != STHD_NEED_RESTART ||
        sthd_decoder_pcm_checksum(decoder, &checksum) != STHD_OK || checksum.checked_layers ||
        sthd_decoder_set_strict_pcm_checksum(decoder, 1) != STHD_OK ||
        sthd_decoder_pcm_checksum(0, &checksum) != STHD_INVALID_ARGUMENT) {
        sthd_decoder_destroy(decoder);
        return 0;
    }
    if (sthd_decoder_end_of_stream(decoder) != 0 || sthd_decoder_end_of_stream(0) != 0)
        return 0;
    sthd_decoder_reset(decoder);
    sthd_decoder_destroy(decoder);
    return sthd_layout_named("9.1.6", &layout) == STHD_OK && layout.channels == 16;
}
