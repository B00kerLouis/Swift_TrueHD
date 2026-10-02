# Decoder 验证记录 — 2026-10-02

## 结论

已完成两个给定 MXF 的全片 encode→decode。比较目标为原 encoder 的熵编码前元素 PCM，包括 compatibility transport、逐层逆矩阵、output shift 和 ch_assign；全部 2/6/8/16 层逐字节一致。参考 PCM 由本次开始时未修改的 Swift encoder 源码单独生成，不通过新 decoder 推导。参考程序仅在忽略目录 `Build/DecoderValidation` 中作为 encoder 侧测试工具存在，不进入任何 decoder Target。

| 输入 / profile | 输入采样数 | AU 数 | 输出字节 | 四层 PCM 比对 |
|---|---:|---:|---:|---|
| QWER_TBH_IAB / 16 elements | 11,036,000 | 275,900 | 242,719,220 | 2/6/8/16 全部一致 |
| Dolby_NaturesFury_IMF_IAB / 16 elements | 5,200,000 | 130,000 | 103,030,720 | 2/6/8/16 全部一致 |
| Dolby_NaturesFury_IMF_IAB / 12 elements | 5,200,000 | 130,000 | 87,137,970 | 2/6/8/12 全部一致 |
| Dolby_NaturesFury_IMF_IAB / 14 elements | 5,200,000 | 130,000 | 95,433,300 | 2/6/8/14 全部一致 |

以上均为 48 kHz、20-bit coded elements，经码流 output shift 恢复 24-bit PCM。TBH 为 229.916667 秒，NaturesFury 为 108.333333 秒。

NaturesFury-16 的 2/6/8 层另通过 FFmpeg 的独立 TrueHD decoder 验证，逐字节相等。FFmpeg 只作为测试 oracle，decoder 产品没有依赖它。

## 布局与安全测试

全部四条全片码流逐 AU 渲染九种布局：2.0、5.1、7.1、5.1.2、5.1.4、7.1.2、7.1.4、7.1.6、9.1.6，检查有限数值、声道数、每通道 RMS、峰值和削波。在 unity gain 下这四部测试输出九种布局的削波数均为零。

- C 编译器直接包含公开 C header，并创建/释放 decoder。
- 每个空间元素独立脉冲，验证目标布局能量守恒、LFE 隔离、锚点路由和高度折叠。
- 独立 front-wide 坐标脉冲精确送 FWL；reverse physical channel order 精确反转输出。
- 5.1 地面布局中的 side/rear PCM 按对应 surround 折叠；验证 Side 与 Back 两种平台环绕标签，含常见 WASAPI 0x3f mask。
- 普通 7.1 没有 immersive 层时，高度不制造额外音频。
- 合成 7.1 素材包含逐通道脉冲、不同频率正弦和固定种子满幅随机 PCM。12,345 个输入采样得到 309 个 AU，末 AU 裁剪 15 个采样；解码出的完整 7.1 PCM 与原 WAVE 完全一致。
- 对每条全片流的首 AU 进行所有单 bit 翻转，均被拒绝；另测试 2,000 个固定种子随机异常输入、缺少 major sync、输出容量不足、重复 speaker labels 和非法 frame size。
- 失败 AU 不改变 decoder 状态，不改变输出 frame；正确下一 AU 可继续解码。
- ASan/UBSan 覆盖单元测试、合成流及完整 NaturesFury-12 四层参考比对与九布局渲染，无报告。
- CLI SIGINT 取消清理输出和 sidecar；已有输出内容保持不变；原始呈现提取逐字节一致。

CLI 实际输出了 `NaturesFury-7.1.wav`、`NaturesFury-9.1.6.wav`、`TBH-9.1.6.wav`、`NaturesFury-5.1-back.wav` 和 `synthetic-decoded.wav`。ffprobe 对两个 9.1.6 WAVE 确认 16 channels、48 kHz、24 bit，采样数分别为 5,200,000 和 11,036,000。`NaturesFury-5.1-back.wav` 另确认 6 channels、5.1 back-channel mask 和完整采样数。大于 4 GB 的 RF64 自动切换代码已实现，本次素材输出没有达到 4 GB，未以真实大文件测试该分支。

Front Wide：当前 encoder 固定 basis 没有前宽元素；因此两部 16-element 素材的 9.1.6 前宽声道在 24-bit 文件中为零。测试验证接口能够渲染真实前宽位置，并未宣称从此码流恢复了已丢弃的 IAB 位置。九布局渲染是独立算法，未与 Dolby 官方 renderer 比较。

## 构建结果

| 平台 / 工具 | 验证结果 | 未执行项 |
|---|---|---|
| macOS / Xcode 26.3 | decoder_cli Release、decoder_framework Debug、原 encoder all Release 成功；两个 decoder 产物均包含 arm64/x86_64 | 多通道实体扬声器实播 |
| macOS / CMake + Apple Clang | Framework、CLI、C/C++ 测试构建；CTest 和 ASan/UBSan 通过 | — |
| Windows x86_64 / MinGW GCC 16.2.0 | Framework、Unicode CLI、测试 executable 交叉编译成功；CLI 无 libgcc/libstdc++ DLL 依赖 | Windows 原生运行、WASAPI 设备、MSVC 实机编译 |
| Linux x86_64-musl / Zig 0.16.0 Clang | CMake Framework/CLI/测试 ELF 交叉编译成功；另编译 ALSA adapter 分支 | Linux 原生运行、GCC 实机、ALSA 设备 |

macOS `otool -L` 仅显示 C++/系统运行库与 CoreAudio/AudioToolbox，没有 Swift Framework、encoder Framework 或第三方 decoder。设备探测在当前 macOS 实际运行，默认设备的两个 channel labels 为 Unknown；自动模式正确拒绝猜测布局，显式布局正常使用。

本次新代码构建没有自有源码警告。Linux 交叉验证初次遇到系统 ar/ranlib 不认识 ELF，随后为交叉构建选用 Zig ar/ranlib 并重建通过。交叉工具源码头文件的 nullability/ALSA 扩展告警不属于 decoder；最终项目源码构建记录无相关告警。

原先 29 个源文件、测试和 README/VALIDATION 文件的 SHA-256 均与本次开始时的快照一致。已有六个未提交修改文件属于开始前的工作区内容，未覆盖或重写。现有 Xcode 工程仅增加配置对象、group/product 引用和两个 Target（47 行新增、零行删除）；已有 Scheme 保持原样。

## 产物与复现

本机证据位于 `Build/DecoderValidation/`：

- `*-validation.json`：四层 PCM 比对标志和九布局统计；`referencePresentations=15` 表示四层均比较。
- `NaturesFury-ffmpeg-validation.json`：独立 FFmpeg 比对，`referencePresentations=7` 表示 2/6/8 层。
- `*-oracle.*.pcm`：编码前参考；`*.mlp`：实际原生 encode 输出。
- `*-sanitized.json`、`cli-validation.json`、`*-build.log`、`xcode-targets.json`：安全、文件操作与构建证据。
- `hashes.json`：素材、码流及参考 PCM SHA-256；`original-files.json`：任务开始时原有文件哈希。

可对已有 elementary stream 重跑：

```sh
Build/DecoderValidation/CMake/decoder_tests --stream \
  Build/DecoderValidation/TBH-16.mlp Build/DecoderValidation/TBH-oracle
Build/DecoderValidation/CMake/decoder_tests --stream \
  Build/DecoderValidation/NaturesFury-16.mlp Build/DecoderValidation/NaturesFury-oracle
Build/DecoderValidation/CMake/truehdd -i Build/DecoderValidation/TBH-16.mlp --verify-only
```

独立 decoder 参考生成：

```sh
ffmpeg -v error -downmix stereo -i INPUT.mlp -c:a pcm_s24le -f s24le REF.2.pcm
ffmpeg -v error -downmix '5.1(side)' -i INPUT.mlp -c:a pcm_s24le -f s24le REF.6.pcm
ffmpeg -v error -i INPUT.mlp -c:a pcm_s24le -f s24le REF.8.pcm
Build/DecoderValidation/CMake/decoder_tests --stream INPUT.mlp REF
```

码流 SHA-256：

| 文件 | SHA-256 |
|---|---|
| TBH-16.mlp | `b5ae3466204cb2438690c98d4e518657ea021251b5e41a17740589a31479b144` |
| NaturesFury-16.mlp | `8083743708c69657a94e073ab2ce7d35cb5f059838cf0eb77364ff25f89fff21` |
| NaturesFury-12.mlp | `23936d4a9606807956ba1d9ecfa33897fff6048f097b3b9fa7a53c9fb3d14165` |
| NaturesFury-14.mlp | `6634534cf9604c3ae8210c69871b64bef6ec926e2cad2d6131b80aa1a33cc800` |


## Native audio / PCM export follow-up

本次按跨平台报告新增 C ABI v2 的 bed/object views、native output planning、CoreAudio / WASAPI / Windows Spatial Audio / PipeWire playback 与 bounded FIFO。原 encoder 源码保持原始快照。

本机 CoreAudio 1-second silent playback 提交并消费 48,000 frames，underruns=0；真实 synthetic 7.1 decode playback 消费精确 12,345 frames（含正确 final trim），underruns=0。新增 policy tests 验证普通 Windows PCM 保持 WASAPI、immersive 全部 positional feeds / native static positions、显式 PCM fallback、Unknown/Discrete layout 和不兼容声道拒绝。Windows 的 native API 已用 MinGW 编译；PipeWire 1.0.5 headers 已完成 Linux target 编译验证。

PCM 输出目录为本机 `Build/DecodePCM/2026-10-02`，有 58 个 full-program 输出：两部素材九种主布局及三种 Back-label 变体的 WAVE/s24le PCM、2/6/8/16 的原始呈现、NaturesFury 12/14 elements。24 对布局 PCM/WAVE 逐字节一致，十份原始呈现提取与原 encoder PCM oracle 一致。`README.md` 和 `outputs.json` 记录绝对路径、格式、尺寸及布局侧车文件。这些大型媒体保留在本机外置盘，源码和 workflow 通过 GitHub 提交。

Workflow `.github/workflows/native-build.yml` 构建 macOS encoder/decoder、Windows MSVC decoder 和 Linux GCC/PipeWire decoder；macOS 原 encoder 生成小型 fixture，三平台验证相同 PCM。Linux 集成测试启动隔离 PipeWire/WirePlumber server 和带正确 positions 的 virtual sink，验证全部布局的格式协商、实际 FIFO consumption 和 drain。Actions 的具体成功状态和 run URL 由实际执行结果报告，不以本机交叉编译代替。

物理多通道扬声器与 Windows Spatial Sound/耳机 HRTF 仍需对应设备实播。CI virtual sink 可验证 native API 调度和声道协商，不等同于硬件声学验证。


## Encoded streaming player / DLL / SO follow-up

C ABI v3 adds a real-time encoded-input player with arbitrary chunk framing, exact consumed-byte progress, one retained pending PCM frame on backpressure, retryable finish, cancellation and copied last-frame/statistics APIs. CLI `play` and binary stdin use the same player. Windows/Linux build shared DLL/SO and export C ABI only.

Local CoreAudio complete-program tests used gain zero to verify actual scheduling without audible output:

| Stream | Accepted bytes | Decoded AUs | Decoded / submitted / consumed frames | Zero-timeout retries | Underruns |
|---|---:|---:|---:|---:|---:|
| NaturesFury-16 | 103,030,720 | 130,000 | 5,200,000 / 5,200,000 / 5,200,000 | 64,649 | 0 |
| TBH-16 | 242,719,220 | 275,900 | 11,036,000 / 11,036,000 / 11,036,000 | 136,651 | 0 |

Fragment sizes include 1, 3, 7, 65,536, 5 and 8,191 bytes, so AU boundaries are not supplied by the test caller. Zero-timeout retries close without duplicate decode/enqueue; final counters match exact programme sample count. The synthetic fixture verifies 12,345-frame final trim, last frame timeline, idempotent finish, input refusal after finish, and active/cross-thread cancellation. Partial headers/payloads, invalid lengths, empty streams and ABI options size are tested before opening a device. Local native player tests also pass ASan/UBSan.

Local MinGW build produces `truehdd.dll` and confirms all `sthd_player_*` exported symbols. Linux target builds an ELF shared `libtruehdd.so` with versioned SONAME. Actions package DLL/import library or SO and header, link/run C ABI tests against the shared products, and play encoded fragments through each labelled PipeWire sink. Physical Windows Spatial Sound playback remains a hardware validation boundary.


## Auto mapping regression — 2026-10-03

Auto now reads endpoint metadata for all supported configurations, preserving physical slot order. Shared validation covers all nine primary families, back-label variants, reversed maps and absent/duplicate/incompatible positions. CoreAudio SDK tag/bitmap expansion tests verify both MPEG 7.1 and bitmap/WAVE 7.1 rear/side ordering. Windows uses the mix mask or the endpoint PhysicalSpeakers property and never converts an absent mask to stereo by channel count. PipeWire integration adds reversed 7.1/7.1.4/9.1.6 and rejects 16 AUX positions.

The actual local device reported Unknown channel labels but an explicit preferred stereo-channel pair L=1/R=2 for its two active slots. That OS declaration establishes this device's route; it is not a default layout for other terminals. The user's exact QWER_TBH_A.mlp playback path was tested with `--play --layout auto`, default gain, and no manual layout: 275,900 AUs, 11,036,000 decoded and consumed frames, underruns=0, complete 229.916667-second programme. Multi-channel terminal maps are independently read from their OS metadata and are not inferred from this local test.
