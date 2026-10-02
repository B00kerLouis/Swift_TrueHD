// SPDX-License-Identifier: AGPL-3.0-only
#include "AudioBackend.hpp"
#if defined(STHD_HAVE_PIPEWIRE) && !defined(STHD_DISABLE_NATIVE_DEVICE)
#include <cstring>
#include <pipewire/extensions/metadata.h>
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/json.h>
namespace sthd_audio {
static uint32_t channel(STHDSpeaker s) {
    static const uint32_t positions[] = {
        SPA_AUDIO_CHANNEL_FL,  SPA_AUDIO_CHANNEL_FR,  SPA_AUDIO_CHANNEL_FC,  SPA_AUDIO_CHANNEL_LFE,
        SPA_AUDIO_CHANNEL_RL,  SPA_AUDIO_CHANNEL_RR,  SPA_AUDIO_CHANNEL_SL,  SPA_AUDIO_CHANNEL_SR,
        SPA_AUDIO_CHANNEL_TFL, SPA_AUDIO_CHANNEL_TFR, SPA_AUDIO_CHANNEL_TRL, SPA_AUDIO_CHANNEL_TRR,
        SPA_AUDIO_CHANNEL_TSL, SPA_AUDIO_CHANNEL_TSR, SPA_AUDIO_CHANNEL_FLW, SPA_AUDIO_CHANNEL_FRW};
    return unsigned(s) < 16 ? positions[unsigned(s)] : SPA_AUDIO_CHANNEL_UNKNOWN;
}
static bool layout(const spa_audio_info_raw &format, STHDLayout &l) {
    if (format.channels < 2 || format.channels > 16 || (format.flags & SPA_AUDIO_FLAG_UNPOSITIONED))
        return false;
    unsigned seen = 0;
    l = STHDLayout{};
    for (unsigned c = 0; c < format.channels; ++c) {
        bool found = false;
        for (unsigned s = 0; s < 16; ++s)
            if (channel(STHDSpeaker(s)) == format.position[c]) {
                if (seen & (1U << s))
                    return false;
                seen |= 1U << s;
                l.speakers[l.channels++] = STHDSpeaker(s);
                found = true;
                break;
            }
        if (!found)
            return false;
    }
    const char *names[] = {"2.0",   "5.1",   "7.1",   "5.1.2",     "5.1.4",       "7.1.2",
                           "7.1.4", "7.1.6", "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
    for (auto name : names) {
        STHDLayout v{};
        sthd_layout_named(name, &v);
        unsigned m = 0;
        for (unsigned i = 0; i < v.channels; ++i)
            m |= 1U << unsigned(v.speakers[i]);
        if (m == seen)
            return true;
    }
    return false;
}
static void initialize() {
    static const bool initialized = []() {
        pw_init(nullptr, nullptr);
        return true;
    }();
    (void)initialized;
}
struct Query {
    struct Node {
        Query *q;
        uint32_t id;
        pw_node *proxy = nullptr;
        spa_hook hook{};
        spa_audio_info_raw format{};
        unsigned quality = 0;
        char name[256]{};
    };
    pw_thread_loop *loop = nullptr;
    pw_context *context = nullptr;
    pw_core *core = nullptr;
    pw_registry *registry = nullptr;
    spa_hook core_hook{}, registry_hook{}, metadata_hook{};
    pw_metadata *metadata = nullptr;
    std::vector<std::unique_ptr<Node>> nodes;
    char preferred[256]{};
    std::atomic<int> done{-1};
    std::atomic<bool> failed{false};
    char error[256]{};
    ~Query() {
        if (loop)
            pw_thread_loop_stop(loop);
        for (auto &n : nodes)
            if (n->proxy)
                pw_proxy_destroy(reinterpret_cast<pw_proxy *>(n->proxy));
        if (metadata)
            pw_proxy_destroy(reinterpret_cast<pw_proxy *>(metadata));
        if (registry)
            pw_proxy_destroy(reinterpret_cast<pw_proxy *>(registry));
        if (core)
            pw_core_disconnect(core);
        if (context)
            pw_context_destroy(context);
        if (loop)
            pw_thread_loop_destroy(loop);
    }
    static void core_done(void *d, uint32_t id, int sequence) {
        if (id == PW_ID_CORE)
            static_cast<Query *>(d)->done.store(sequence);
    }
    static void core_error(void *d, uint32_t id, int, int result, const char *message) {
        // An idle node may have no active Format parameter. Such a node-local
        // enumeration error does not mean the server connection is unusable.
        if (id != PW_ID_CORE)
            return;
        auto &q = *static_cast<Query *>(d);
        std::snprintf(q.error, sizeof(q.error), "core error %d: %s", result,
                      message ? message : "");
        q.failed.store(true);
    }
    static void node_param(void *d, int, uint32_t id, uint32_t, uint32_t, const spa_pod *pod) {
        auto &n = *static_cast<Node *>(d);
        spa_audio_info_raw f{};
        if (!pod || spa_format_audio_raw_parse(pod, &f) < 0)
            return;
        unsigned quality = id == SPA_PARAM_Format ? 3U : 1U;
        if (f.channels && quality >= n.quality) {
            n.format = f;
            n.quality = quality;
        }
    }
    static void node_info(void *d, const pw_node_info *info) {
        auto &n = *static_cast<Node *>(d);
        if (!info->props)
            return;
        const char *positions = spa_dict_lookup(info->props, "audio.position");
        if (!positions)
            return;
        spa_json top{}, array{};
        spa_json_init(&top, positions, std::strlen(positions));
        if (spa_json_enter_array(&top, &array) <= 0)
            return;
        spa_audio_info_raw f{};
        char label[32];
        while (spa_json_get_string(&array, label, sizeof(label)) > 0) {
            if (f.channels >= 16)
                return;
            bool found = false;
            for (unsigned s = 0; s < 16; ++s) {
                const char *spa_names[] = {"FL",  "FR",  "FC",  "LFE", "RL",  "RR",  "SL",  "SR",
                                           "TFL", "TFR", "TRL", "TRR", "TSL", "TSR", "FLW", "FRW"};
                if (!std::strcmp(label, spa_names[s])) {
                    f.position[f.channels++] = channel(STHDSpeaker(s));
                    found = true;
                    break;
                }
            }
            if (!found) {
                f.flags |= SPA_AUDIO_FLAG_UNPOSITIONED;
                ++f.channels;
            }
        }
        if (f.channels && n.quality < 2) {
            n.format = f;
            n.quality = 2;
        }
    }
    static int property(void *d, uint32_t, const char *key, const char *, const char *value) {
        auto &q = *static_cast<Query *>(d);
        if (!key || std::strcmp(key, "default.audio.sink"))
            return 0;
        q.preferred[0] = 0;
        if (!value)
            return 0;
        spa_json top{}, object{};
        spa_json_init(&top, value, std::strlen(value));
        if (spa_json_enter_object(&top, &object) <= 0)
            return 0;
        char k[64], v[256];
        while (spa_json_get_string(&object, k, sizeof(k)) > 0 &&
               spa_json_get_string(&object, v, sizeof(v)) > 0)
            if (!std::strcmp(k, "name")) {
                std::snprintf(q.preferred, sizeof(q.preferred), "%s", v);
                break;
            }
        return 0;
    }
    static void global(void *d, uint32_t id, uint32_t, const char *type, uint32_t,
                       const spa_dict *props) {
        auto &q = *static_cast<Query *>(d);
        if (!props)
            return;
        try {
            if (!std::strcmp(type, PW_TYPE_INTERFACE_Metadata) && !q.metadata) {
                const char *name = spa_dict_lookup(props, "metadata.name");
                if (name && !std::strcmp(name, "default")) {
                    q.metadata = static_cast<pw_metadata *>(
                        pw_registry_bind(q.registry, id, type, PW_VERSION_METADATA, 0));
                    if (q.metadata) {
                        static const pw_metadata_events ev = []() {
                            pw_metadata_events e{};
                            e.version = PW_VERSION_METADATA_EVENTS;
                            e.property = property;
                            return e;
                        }();
                        pw_metadata_add_listener(q.metadata, &q.metadata_hook, &ev, &q);
                    }
                }
            } else if (!std::strcmp(type, PW_TYPE_INTERFACE_Node)) {
                const char *media = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
                if (!media || std::strcmp(media, "Audio/Sink") || q.nodes.size() >= 64)
                    return;
                auto n = std::make_unique<Node>();
                n->q = &q;
                n->id = id;
                const char *name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
                std::snprintf(n->name, sizeof(n->name), "%s", name ? name : "");
                n->proxy = static_cast<pw_node *>(
                    pw_registry_bind(q.registry, id, type, PW_VERSION_NODE, 0));
                if (!n->proxy)
                    return;
                static const pw_node_events ev = []() {
                    pw_node_events e{};
                    e.version = PW_VERSION_NODE_EVENTS;
                    e.info = node_info;
                    e.param = node_param;
                    return e;
                }();
                pw_node_add_listener(n->proxy, &n->hook, &ev, n.get());
                pw_node_enum_params(n->proxy, 0, SPA_PARAM_EnumFormat, 0, UINT32_MAX, nullptr);
                pw_node_enum_params(n->proxy, 1, SPA_PARAM_Format, 0, UINT32_MAX, nullptr);
                q.nodes.push_back(std::move(n));
            }
        } catch (...) {
            q.failed.store(true);
        }
    }
    bool open() {
        initialize();
        loop = pw_thread_loop_new("truehd-capabilities", nullptr);
        if (!loop)
            return false;
        context = pw_context_new(pw_thread_loop_get_loop(loop), nullptr, 0);
        if (!context)
            return false;
        core = pw_context_connect(context, nullptr, 0);
        if (!core)
            return false;
        static const pw_core_events ce = []() {
            pw_core_events e{};
            e.version = PW_VERSION_CORE_EVENTS;
            e.done = core_done;
            e.error = core_error;
            return e;
        }();
        pw_core_add_listener(core, &core_hook, &ce, this);
        registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
        if (!registry)
            return false;
        static const pw_registry_events re = []() {
            pw_registry_events e{};
            e.version = PW_VERSION_REGISTRY_EVENTS;
            e.global = global;
            return e;
        }();
        pw_registry_add_listener(registry, &registry_hook, &re, this);
        if (pw_thread_loop_start(loop) < 0)
            return false;
        for (unsigned round = 0; round < 3; ++round) {
            pw_thread_loop_lock(loop);
            int seq = pw_core_sync(core, PW_ID_CORE, 0);
            pw_thread_loop_unlock(loop);
            auto end = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (done.load() != seq && !failed.load()) {
                if (std::chrono::steady_clock::now() >= end)
                    return false;
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if (failed.load())
                return false;
        }
        return true;
    }
};
STHDStatus pipewire_capabilities(STHDAudioCapabilities &c) {
    Query q;
    if (!q.open()) {
        std::snprintf(c.endpoint, sizeof(c.endpoint), "PipeWire discovery failed: %s",
                      q.error[0] ? q.error : "server connect/sync unavailable");
        return STHD_DEVICE_UNAVAILABLE;
    }
    pw_thread_loop_lock(q.loop);
    Query::Node *selected = nullptr;
    for (auto &n : q.nodes)
        if (q.preferred[0] && !std::strcmp(n->name, q.preferred))
            selected = n.get();
    // A sole sink is unambiguous when no default metadata is published. Never
    // select an arbitrary device among multiple professional/discrete outputs.
    if (!selected && !q.preferred[0] && q.nodes.size() == 1)
        selected = q.nodes[0].get();
    if (selected) {
        c.pcm_backend = STHD_AUDIO_PIPEWIRE;
        c.pcm_available = 1;
        c.native_device_id = selected->id;
        c.pcm_channels = selected->format.channels;
        c.pcm_sample_rate = selected->format.rate;
        c.pcm_layout_valid = layout(selected->format, c.pcm_layout);
        std::snprintf(c.endpoint, sizeof(c.endpoint), "%s", selected->name);
    }
    if (!selected)
        std::snprintf(c.endpoint, sizeof(c.endpoint),
                      "No matching default PipeWire sink (nodes=%zu, default=%s)", q.nodes.size(),
                      q.preferred);
    pw_thread_loop_unlock(q.loop);
    return selected ? STHD_OK : STHD_DEVICE_UNAVAILABLE;
}
struct PipeWireDriver final : Driver {
    pw_thread_loop *loop = nullptr;
    pw_stream *stream = nullptr;
    std::atomic<bool> paused{false}, drained{false};
    PipeWireDriver(Ring &r, const STHDAudioPlan &p) : Driver(r, p) {}
    ~PipeWireDriver() {
        if (loop)
            pw_thread_loop_stop(loop);
        if (stream)
            pw_stream_destroy(stream);
        if (loop)
            pw_thread_loop_destroy(loop);
    }
    static void state(void *d, pw_stream_state, pw_stream_state s, const char *) {
        auto &v = *static_cast<PipeWireDriver *>(d);
        if (s == PW_STREAM_STATE_ERROR)
            v.ring.failure.store(STHD_AUDIO_FAILURE);
        if (s == PW_STREAM_STATE_PAUSED)
            v.paused.store(true);
    }
    static void format(void *d, uint32_t id, const spa_pod *pod) {
        auto &v = *static_cast<PipeWireDriver *>(d);
        if (id != SPA_PARAM_Format || !pod)
            return;
        spa_audio_info_raw info{};
        if (spa_format_audio_raw_parse(pod, &info) < 0 || info.rate != 48000 ||
            info.channels != v.ring.channels || info.format != SPA_AUDIO_FORMAT_F32) {
            v.ring.failure.store(STHD_UNSUPPORTED_OUTPUT);
            return;
        }
        for (unsigned i = 0; i < info.channels; ++i)
            if (info.position[i] != channel(v.plan.layout.speakers[i]))
                v.ring.failure.store(STHD_UNSUPPORTED_OUTPUT);
    }
    static void drained_event(void *d) { static_cast<PipeWireDriver *>(d)->drained.store(true); }
    static void process(void *d) {
        auto &v = *static_cast<PipeWireDriver *>(d);
        pw_buffer *b = pw_stream_dequeue_buffer(v.stream);
        if (!b)
            return;
        spa_buffer *buffer = b->buffer;
        if (buffer->n_datas != 1 || !buffer->datas[0].data || !buffer->datas[0].chunk) {
            v.ring.failure.store(STHD_AUDIO_FAILURE);
            pw_stream_queue_buffer(v.stream, b);
            return;
        }
        auto &data = buffer->datas[0];
        unsigned stride = v.ring.channels * sizeof(float);
        unsigned frames =
            unsigned(std::min<uint64_t>(b->requested ? b->requested : 1024, data.maxsize / stride));
        unsigned n = v.ring.pop(static_cast<float *>(data.data), frames);
        if (!v.ring.draining.load()) {
            std::fill_n(static_cast<float *>(data.data) + size_t(n) * v.ring.channels,
                        size_t(frames - n) * v.ring.channels, 0.f);
            if (n < frames)
                v.ring.underruns.fetch_add(1);
            n = frames;
        }
        data.chunk->offset = 0;
        data.chunk->stride = int32_t(stride);
        data.chunk->size = n * stride;
        b->size = n;
        pw_stream_queue_buffer(v.stream, b);
    }
    STHDStatus open() override {
        STHDAudioCapabilities current{};
        if (pipewire_capabilities(current) != STHD_OK ||
            current.native_device_id != plan.native_device_id ||
            current.pcm_channels != ring.channels) {
            std::snprintf(error, sizeof(error), "selected PipeWire sink changed");
            return STHD_DEVICE_UNAVAILABLE;
        }
        if (current.pcm_layout_valid)
            for (unsigned i = 0; i < ring.channels; ++i)
                if (current.pcm_layout.speakers[i] != plan.layout.speakers[i])
                    return STHD_UNSUPPORTED_OUTPUT;
        initialize();
        loop = pw_thread_loop_new("truehd-output", nullptr);
        if (!loop)
            return STHD_AUDIO_FAILURE;
        static const pw_stream_events events = []() {
            pw_stream_events e{};
            e.version = PW_VERSION_STREAM_EVENTS;
            e.state_changed = state;
            e.param_changed = format;
            e.process = process;
            e.drained = drained_event;
            return e;
        }();
        auto *props =
            pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Playback",
                              PW_KEY_MEDIA_ROLE, "Music", PW_KEY_TARGET_OBJECT, plan.endpoint,
                              "stream.dont-remix", "true", "node.dont-reconnect", "true", nullptr);
        stream =
            pw_stream_new_simple(pw_thread_loop_get_loop(loop), "TrueHD PCM", props, &events, this);
        if (!stream)
            return STHD_AUDIO_FAILURE;
        uint8_t storage[2048];
        spa_pod_builder builder{};
        spa_pod_builder_init(&builder, storage, sizeof(storage));
        spa_audio_info_raw info{};
        info.format = SPA_AUDIO_FORMAT_F32;
        info.rate = 48000;
        info.channels = ring.channels;
        for (unsigned i = 0; i < ring.channels; ++i)
            info.position[i] = channel(plan.layout.speakers[i]);
        const spa_pod *param = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info);
        auto flags = pw_stream_flags(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
                                     PW_STREAM_FLAG_RT_PROCESS | PW_STREAM_FLAG_INACTIVE);
        if (pw_stream_connect(stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, flags, &param, 1) < 0 ||
            pw_thread_loop_start(loop) < 0)
            return STHD_AUDIO_FAILURE;
        auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!paused.load()) {
            if (ring.failure.load() != STHD_OK)
                return ring.failure.load();
            if (std::chrono::steady_clock::now() >= end) {
                std::snprintf(error, sizeof(error), "PipeWire did not link the selected sink");
                return STHD_TIMEOUT;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return STHD_OK;
    }
    STHDStatus start() override {
        pw_thread_loop_lock(loop);
        int result = pw_stream_set_active(stream, true);
        pw_thread_loop_unlock(loop);
        return result < 0 ? STHD_AUDIO_FAILURE : STHD_OK;
    }
    STHDStatus finish(uint32_t timeout) override {
        auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
        if (!wait_empty(ring, timeout))
            return ring.failure.load() != STHD_OK ? ring.failure.load() : STHD_TIMEOUT;
        pw_thread_loop_lock(loop);
        int result = pw_stream_flush(stream, true);
        pw_thread_loop_unlock(loop);
        if (result < 0)
            return STHD_AUDIO_FAILURE;
        while (!drained.load()) {
            if (ring.stopping.load())
                return STHD_CANCELLED;
            if (ring.failure.load() != STHD_OK)
                return ring.failure.load();
            if (std::chrono::steady_clock::now() >= end)
                return STHD_TIMEOUT;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return STHD_OK;
    }
};
std::unique_ptr<Driver> make_pipewire(Ring &r, const STHDAudioPlan &p) {
    return std::make_unique<PipeWireDriver>(r, p);
}
} // namespace sthd_audio
#endif
