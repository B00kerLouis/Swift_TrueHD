# TrueHD Decoder

该项目新增两个独立 Xcode Target：`decoder_framework`（`libtruehdd.framework` 静态 Framework）和 `decoder_cli`（`truehdd`）。所有解码、校验、空间渲染、设备探测和 CLI 实现仅使用 C/C++，不链接 Swift encoder、FFmpeg 或外部解码器。原有源文件、测试、README 和已有 Scheme 保持本次工作开始时的内容。

本 decoder 支持当前项目生成的 48 kHz TrueHD FBA elementary stream：普通 2/6/8 层和 Atmos 2/6/8/12、14、16 层。MXF 是 encoder 输入；decoder 输入是 encoder 输出的 `.mlp`。目前不包含 MXF/MKV demux、通用商业 TrueHD/MLP 全格式解码、移动 OAMD、IIR、噪声矩阵、bypass LSB 或动态 DRC 播放处理；不支持的语法明确报错。

## macOS / Xcode

```sh
xcodebuild -project Swift_TrueHD.xcodeproj -scheme decoder_cli \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath Build/DecoderDerived build
```

打开同一个 `.xcodeproj` 即可选择 `decoder_cli` 或 `decoder_framework` Scheme。两个 Target 均独立于 `libtruehda` 和 `turehda`，CLI 仅依赖 decoder Framework 和系统音频库。验证工具链为 Xcode 26.3，decoder 的 macOS deployment target 为 11.0；Release 产物为 arm64/x86_64 通用二进制。

```sh
Build/Products/Release/truehdd -i INPUT.mlp -o OUTPUT.wav --layout 7.1.4
Build/Products/Release/truehdd -i INPUT.mlp --verify-only
Build/Products/Release/truehdd -i INPUT.mlp -o ELEMENTS.wav --presentation elements
Build/Products/Release/truehdd --device-info
```

完整布局：`2.0`、`5.1`、`7.1`、`5.1.2`、`5.1.4`、`7.1.2`、`7.1.4`、`7.1.6`、`9.1.6`。5.1 系列也接受 `5.1(back)`、`5.1.2(back)`、`5.1.4(back)`，用于实际以 BL/BR 标记环绕对的设备。默认 `--layout auto` 读取默认设备的实际扬声器标签；不根据通道数量猜测高度或扬声器位置。若驱动只有 Unknown/Discrete 标签，应显式指定布局。`--speaker-order FL,FR,...` 可以指定与所选布局相同的一组扬声器的实际物理顺序。可选 `--gain-db -6` 为渲染求和保留余量，CLI 报告量化到 24-bit 时的削波采样数。

`--presentation 2|6|8|elements` 提取相应呈现的原始 24-bit PCM，与布局渲染、声道重排和增益选项互斥。DRC gain code 由 Framework 返回，默认保留无 DRC 的无损 PCM。

输出为 48 kHz / 24-bit WAVE，超过 RIFF 长度范围自动使用 RF64。每个输出附带 `.channels.json`，记录准确的声道顺序；元素提取还记录 OAMD 坐标。WAVE 标准没有可移植的 Top Middle / Front Wide 位定义，含这些声道的输出使用零 channel mask，必须依照 sidecar 配置播放器，不能按一般的 16-channel WAVE 默认顺序解释。设备顺序与 WAVE mask 顺序不一致时同样使用 sidecar。

CLI 支持 `--format s24le` 输出无头 packed PCM，支持 `--play` 使用独立的 native backend 实际播放。CoreAudio、WASAPI/Windows Spatial Audio、PipeWire 分别处理系统协商和调度；普通 Windows PCM 不进入 Spatial pipeline。详见 [原生音频架构](AUDIO_ARCHITECTURE.md)。

## Windows / Linux / C++ builder

需要 C++17 编译器和 C 编译器。CMake 仅管理新增 decoder，不编译 encoder，也不改变 macOS 的 Xcode 架构。

```sh
cmake -S . -B Build/DecoderPortable -DCMAKE_BUILD_TYPE=Release
cmake --build Build/DecoderPortable --config Release
ctest --test-dir Build/DecoderPortable -C Release --output-on-failure
```

Windows 可使用 MSVC 或 MinGW；CLI 使用 Unicode 命令行与路径，设备布局来自 WASAPI shared mix format 的实际 channel mask。MinGW CLI 静态链接编译器运行库。Windows 的 standard WAVE mask 无法表示完整的 Top Middle / Front Wide，因此这类离散多通道接口应由宿主传入实际 `STHDLayout`，或通过 CLI 显式指定。

Linux 在找到 `libpipewire-0.3` 开发包时优先编译 PipeWire capability/playback；默认 sink 的实际 profile 和 positions 决定布局。无 PipeWire 时仍可离线 decode/render，旧 ALSA 查询可作为兼容查询路径。未知或离散通道需要显式布局，实时 player 需要 PipeWire。可用 `-DSTHD_NATIVE_DEVICE=OFF` 构建完全不依赖平台音频 API 的核心。

不使用 CMake 时，将 `Sources/DecoderFramework` 的七个 `.cpp` 编译为库，公开 `include/TrueHDDecoder.h`，再链接 `Sources/DecoderCLI/main.cpp`。macOS 链接 CoreAudio/AudioToolbox；Windows 链接 ole32/uuid，MinGW Unicode 入口需要 `-municode`；Linux 的 ALSA 探测需定义 `STHD_HAVE_ALSA=1` 并链接 asound；PipeWire 实时路径定义 `STHD_HAVE_PIPEWIRE=1` 并使用 pkg-config 的 `libpipewire-0.3` 编译/链接参数。C++ 代码需启用异常，异常不会穿过公开 C ABI。

## C ABI

```c
#include "TrueHDDecoder.h"
STHDDecoder *decoder = sthd_decoder_create();
STHDFrame frame;
STHDLayout output;
float pcm[STHD_MAX_SAMPLES * STHD_MAX_CHANNELS];
if (decoder && sthd_layout_named("7.1.4", &output) == STHD_OK) {
    /* au_bytes is one complete access unit, including its 4-byte header. */
    if (sthd_decode_access_unit(decoder, au_bytes, au_size, &frame) == STHD_OK) {
        if (sthd_render(&frame, &output, 1.0f, pcm, sizeof(pcm) / sizeof(pcm[0])) == STHD_OK) {
            /* Deliver frame.samples * output.channels floats to the device. */
        }
    }
}
sthd_decoder_destroy(decoder);
```

一个 decoder 对应一条流，调用者串行访问该实例。首个 AU 必须带 major sync；输入错误不提交新的解码状态、不修改输出 frame。Framework 每次处理一个最多 8190-byte AU 和 40 个采样，不加载整部素材。渲染 float PCM 允许超过 ±1；宿主决定量化、限幅和音量。CLI 拒绝覆盖已有输出和 sidecar，普通失败及 SIGINT/SIGTERM 取消会清理本次创建的未完成输出。

## 已验证范围

两个提供的 MXF 都完成全片 encode→decode：TBH 为 11,036,000 个采样，NaturesFury 为 5,200,000 个采样。全部 2/6/8/16 层 PCM 与原 encoder 在熵编码前的参考逐字节一致；NaturesFury 的 2/6/8 层还与 FFmpeg 独立解码一致。另验证全片 12/14 元素、九种布局、脉冲/LFE/前宽/重排、末帧裁剪、损坏流和 ASan/UBSan。

原 encoder 会将 IAB 对象降维到固定空间锚点。解码器无损恢复的是码流中的编码元素；原始 IAB 全部轨道、对象运动和编码前被丢弃的信息无法从这些元素恢复。本 renderer 是独立的等功率房间坐标渲染实现，未验证与 Dolby 官方 renderer 的逐采样一致性。固定锚点没有前宽位置时，9.1.6 的 Front Wide 会为零，不能将此误称为恢复了原始前宽对象；接口对实际前宽位置的路由已用独立脉冲测试验证。

详见 [码流分析](BITSTREAM.md) 和 [测试记录](VALIDATION.md)。

GitHub Actions workflow 为 `.github/workflows/native-build.yml`：macOS 通过 Xcode 构建 encoder 和 decoder；Windows/MSVC 与 Linux/GCC 构建 decoder，并使用 macOS 原 encoder 生成的 fixture 做跨平台 PCM 比对。Linux 另测试所有布局的实际 PipeWire 虚拟 sink 播放。
