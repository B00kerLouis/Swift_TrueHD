# SPDX-License-Identifier: LGPL-2.1-or-later
# Independent libtruehdd decoder: synthetic input and pre-entropy PCM references.
FATE_LIBTRUEHDD-$(call ALLYES, TRUEHD_DEMUXER LIBTRUEHDD_DECODER PCM_S24LE_ENCODER PCM_S24LE_MUXER FILE_PROTOCOL PIPE_PROTOCOL MD5_PROTOCOL) += \
    fate-libtruehdd-71-2 \
    fate-libtruehdd-71-6 \
    fate-libtruehdd-71-8 \
    fate-libtruehdd-12-2 \
    fate-libtruehdd-12-6 \
    fate-libtruehdd-12-8 \
    fate-libtruehdd-12-elements \
    fate-libtruehdd-14-2 \
    fate-libtruehdd-14-6 \
    fate-libtruehdd-14-8 \
    fate-libtruehdd-14-elements \
    fate-libtruehdd-16-2 \
    fate-libtruehdd-16-6 \
    fate-libtruehdd-16-8 \
    fate-libtruehdd-16-elements \
    fate-libtruehdd-timed-16-elements

fate-libtruehdd-71-2: CMD = md5pipe -f truehd -c:a libtruehdd -presentation stereo -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-71.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-71-2: CMP = oneline
fate-libtruehdd-71-2: REF = 94076c3f5f26dc9ba0270458e91121f9

fate-libtruehdd-71-6: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 5.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-71.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-71-6: CMP = oneline
fate-libtruehdd-71-6: REF = fa6126b122b83359b4c423c9ab974111

fate-libtruehdd-71-8: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 7.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-71.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-71-8: CMP = oneline
fate-libtruehdd-71-8: REF = bfabbb04f206c73b3df14790d638865f

fate-libtruehdd-12-2: CMD = md5pipe -f truehd -c:a libtruehdd -presentation stereo -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-12.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-12-2: CMP = oneline
fate-libtruehdd-12-2: REF = c3af7a4077e6c31b801f305f049ac013

fate-libtruehdd-12-6: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 5.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-12.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-12-6: CMP = oneline
fate-libtruehdd-12-6: REF = 634339d1133a91068e7556011b2c2fbe

fate-libtruehdd-12-8: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 7.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-12.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-12-8: CMP = oneline
fate-libtruehdd-12-8: REF = 0268a2c72b6ed487a7386279e89beee4

fate-libtruehdd-12-elements: CMD = md5pipe -f truehd -c:a libtruehdd -presentation elements -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-12.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-12-elements: CMP = oneline
fate-libtruehdd-12-elements: REF = 8fc84e56f97907d3ec6f9f7211092c2a

fate-libtruehdd-14-2: CMD = md5pipe -f truehd -c:a libtruehdd -presentation stereo -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-14.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-14-2: CMP = oneline
fate-libtruehdd-14-2: REF = 2b8652334fdf9787aa9fce06ef431b10

fate-libtruehdd-14-6: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 5.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-14.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-14-6: CMP = oneline
fate-libtruehdd-14-6: REF = 86d8cdb456a3555061e5a8ae470cee2d

fate-libtruehdd-14-8: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 7.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-14.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-14-8: CMP = oneline
fate-libtruehdd-14-8: REF = 4639477f2853f8602d15b4c07ccf9ada

fate-libtruehdd-14-elements: CMD = md5pipe -f truehd -c:a libtruehdd -presentation elements -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-14.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-14-elements: CMP = oneline
fate-libtruehdd-14-elements: REF = 128e3a63ffb507758e886199cfce2a4c

fate-libtruehdd-16-2: CMD = md5pipe -f truehd -c:a libtruehdd -presentation stereo -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-16.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-16-2: CMP = oneline
fate-libtruehdd-16-2: REF = 1a6b8737e86f3e165d56af54f990112d

fate-libtruehdd-16-6: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 5.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-16.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-16-6: CMP = oneline
fate-libtruehdd-16-6: REF = bf887163ae473f70b2c88e3b29710430

fate-libtruehdd-16-8: CMD = md5pipe -f truehd -c:a libtruehdd -presentation 7.1 -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-16.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-16-8: CMP = oneline
fate-libtruehdd-16-8: REF = f35c213b732e26e564fcd079a0c233b0

fate-libtruehdd-16-elements: CMD = md5pipe -f truehd -c:a libtruehdd -presentation elements -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/synthetic-16.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-16-elements: CMP = oneline
fate-libtruehdd-16-elements: REF = 63cc096e3fa58b0e29f04d9acd017bcc

fate-libtruehdd-timed-16-elements: CMD = md5pipe -f truehd -c:a libtruehdd -presentation elements -guess_layout_max 0 -i $(TARGET_SAMPLES)/libtruehdd/timed-16.mlp -c:a pcm_s24le -f s24le
fate-libtruehdd-timed-16-elements: CMP = oneline
fate-libtruehdd-timed-16-elements: REF = 63cc096e3fa58b0e29f04d9acd017bcc

FATE_SAMPLES_FFMPEG += $(FATE_LIBTRUEHDD-yes)
fate-libtruehdd: $(FATE_LIBTRUEHDD-yes)
