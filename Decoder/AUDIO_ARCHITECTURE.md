# Native audio architecture

本次按用户提供的跨平台报告，将解码、presentation、renderer 与 native backend 分开。`Decoder.cpp` 不读取设备、不改变平台下的解码 PCM；`Renderer.cpp` 仅负责布局；`AudioOutput.cpp` 提供平台无关的 presentation view、路由策略和 bounded producer/consumer queue；`NativeAudio.cpp` 与 `PipeWireAudio.cpp` 管理系统 API、格式协商及实际播放。实现仍全部为 C/C++17，Xcode 的两个 decoder Target 与 encoder 独立。

## Presentation 语义

`sthd_presentation` 返回借用原 frame 的 view，避免复制全片或重新解释元素为扬声器。普通呈现有 2/6/8 个 bed channels、无 objects。当前 encoder 的 immersive profile 将 decoded element 0 声明为 LFE bed，其余 11/13/15 个元素是带 OAMD 位置的 positional feeds。`STHDAudioObject.id` 是码流元素 index；原始 IAB 对象 ID、轨道及运动信息在 encoder 的空间归并后已无法完整恢复。

因此 16 elements、7.1.4 的 12 speakers 与 9.1.6 的 16 speakers 是三种不同概念。文件布局由 renderer 生成；对象 view 保留源元素与坐标直到 native Spatial Audio backend。

## 路由和系统差异

| 平台 | 普通 channel PCM | Immersive | 格式协商 |
|---|---|---|---|
| macOS | CoreAudio DefaultOutput AudioUnit | 本地 renderer 到实际设备标签的 PCM | 客户端 F32/48 kHz，AudioUnit 处理设备格式转换，显式物理 slot map |
| Windows | WASAPI shared event-driven PCM | 优先 positional Spatial Audio objects；资源不足时使用 native static positions | PCM float 48 kHz + 系统 SRC；Spatial 要求支持 mono F32/48 kHz |
| Linux | PipeWire stream | 本地 renderer 到 sink 的实际 `audio.position` | F32/48 kHz stream，PipeWire 转换 sink 格式；关闭隐式 remix |

普通 TrueHD 默认不进入 Windows Spatial pipeline。对于 immersive，优先检查 `GetMaxDynamicObjectCount` 和 `GetNativeStaticObjectTypeMask`：必须能保留全部 positional feeds，不能分配几个对象后丢弃其余信号。Native static objects 缺少 Top Middle / Front Wide，不能将其声道数误标为 7.1.6 或 9.1.6；静态模式按实际支持的布局渲染完整元素。

当 Spatial Audio 不可用时，Windows immersive 的 WASAPI fallback 需显式 `--allow-pcm-fallback`，或显式 `--layout` 表达本地 speaker render 选择。WASAPI endpoint 若实际提供同等数量的无标签 discrete channels，可在用户明确指定布局后保留物理顺序和 zero channel mask；不能根据 16 个输出自动猜为 9.1.6。

Windows object coordinates 转换为 listener-relative `(x, z, -y)`。源坐标是归一化房间坐标，默认每轴单位为 1 meter；宿主可以通过 plan 的 `room_half_width_m`、`room_half_depth_m`、`room_height_m` 提供实际尺度。轴方向和单位核对 [Microsoft SetPosition 文档](https://learn.microsoft.com/en-us/windows/win32/api/spatialaudioclient/nf-spatialaudioclient-ispatialaudioobject-setposition)。当前码流的固定 basis 无时间变化；对象位置变化仍显式返回 unsupported，而不丢弃 ramp/timing。

PipeWire backend 从 registry 查 default metadata、sink 当前 format/profile 和 position，区别活动 profile channels 与硬件物理总输出。只有单一 sink 且缺少 default metadata 时才使用这个不歧义的 sink；多个设备不随意选第一个。未知/AUX/Discrete label 保持 unknown。参见 [PipeWire raw audio format](https://docs.pipewire.org/structspa__audio__info__raw.html) 与 [stream API](https://docs.pipewire.org/group__pw__stream.html)。ALSA 的旧 layout 查询在无 PipeWire 构建中保留；新增实时 Linux player 需要 PipeWire。

## 普通 7.1 下混修正

原项目 plain encoder 的前三层是累积声道子集，第一层没有包含全部中心、侧与后环绕的 downmix。解码仍恢复所有原始层；渲染普通 7.1 到 stereo/5.1 时改从完整 7.1 bed 做显式下混：中心和 surround 使用 -3 dB 系数，5.1 将对应 side/rear 合并，stereo 不混入 LFE。高度布局不虚构高度信号；plain 7.1 到 5.1.2/5.1.4 的地面下混与 5.1 保持相同电平，高度扩展不改变 bed 增益。`--presentation` 原始提取行为不变。

Atmos 的 2/6/8 兼容呈现具有 encoder 提供的完整逆矩阵，继续使用这些 bit-accurate presentations。下混、空间渲染与输出量化可能产生额外峰值，文件输出报告 clipped samples；播放增益由用户明确控制，不自动修改无损解码结果。

## 实时约束和错误

每个 player 有 16,384-frame SPSC ring，最多 16 channels（1 MiB）。Decoder/renderer 在 producer 运行；CoreAudio/PipeWire callbacks 只读 FIFO、拷贝或补静音，不分配、不解码、不做文件 I/O。Windows 所有 COM audio 对象在同一个 MTA render thread 创建和使用。开播前预缓冲 2,048 frames；短节目在 drain 时启动；停止先终止 native callback/thread，再销毁 FIFO。

write 与 drain 有 timeout，CoreAudio 监听默认设备和布局变化；drain 包含 converter、device、stream latency 和 buffer/safety offset。输出设备变化或协商失败报错，不能偷偷改到另一个 channel layout。通过 `sthd_audio_stats` 可观测 submitted/consumed frames、underruns；`sthd_audio_error` 提供 native 错误。Frame 最后实际采样数用于播放，不能把 40-sample padding 当成节目音频。

## 方案选择

评估了五个方案：仅扩展 capability query、在实时 callback 内解码、统一第三方 audio wrapper、依赖外部 player/codec、独立 presentation 与 bounded native backends。选择第五项，既保持 C/C++ 与原生 API 边界，也能用 C/C++ unit tests、真实 CoreAudio 和隔离的 PipeWire sink 验证调度。Windows 的传统/Spatial 双路径保留，避免统一接口掩盖输出语义。

## 使用

```sh
truehdd -i INPUT.mlp --play --layout 7.1
truehdd -i INPUT.mlp --play                      # actual labels or Spatial capability
truehdd -i INPUT.mlp --play --allow-pcm-fallback # Windows immersive fallback
truehdd -i INPUT.mlp -o OUTPUT.s24le.pcm --layout 7.1.4 --format s24le
truehdd --device-info
```

音频引擎的系统音量、DSP、量化或 Spatial/HRTF 渲染不属于 decoder 的逐字节 PCM 保证。当前 renderer 未声称与 Dolby 官方 renderer 逐采样等价，decoder 仍只支持本项目固定-basis 48 kHz profile。
