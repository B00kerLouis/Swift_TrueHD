# 独立 Decoder 的 FFmpeg 接入与修复记录

日期：2026-10-06。范围为 Decoder 和独立 FFmpeg 适配层。按项目范围，48 kHz
FBA profile 与现有渲染/播放架构保留；本轮接通移动 OAMD 和 PCM 校验报告。Encoder 的
实现和既有用户改动保留；许可采用 Encoder 研究许可与 Decoder LGPL 的拆分。

## 已完成

| 项目 | 实现与结果 |
|---|---|
| 独立 codec 接入 | `Integrations/FFmpeg/libtruehdddec.c` 注册 `libtruehdd`，使用 `AV_CODEC_ID_TRUEHD`，保留原 `mlpdec.c` |
| 构建注册 | 外部库探测、codec/Makefile 注册、版本、Changelog、文档、FATE 定义和可重复安装脚本 |
| Xcode 兼容 | 原 `decoder_framework -> decoder_cli` 图、macOS 11+、arm64/x86_64 保留；适配层只在 FFmpeg 内编译 |
| 随机访问 checksum | reset 后不核验无法取得的前一区间 PCM checksum；当前 restart CRC 及后续区间检查继续执行 |
| major-sync 解析 | 依据扩展标志和数量计算实际头长度；验证 channel arrangement、modifier、presentation/format flags 与 element count |
| PCM 交付 | 右对齐 24-bit PCM 转换成满幅 S32；`ff_get_buffer` 分配输出，保留准确 core layout，elements 使用 unspecified layout |
| 时间与生命周期 | packet PTS、实际样本 duration、最终裁剪、flush/preroll、损坏包恢复、错误码、帧及元数据所有权 |
| 元数据 | copied frame dictionary 交付 presentation、DRC 有效性/code、OAMD 有效性/坐标/逐采样 motion；不新增 FFmpeg 公共 ABI |
| 可分发测试 | 四条原创合成音频和一条 timed OAMD 变体、16 个 FATE case；无需 Encoder 运行时即可运行测试 |
| 深入错误路径 | 修复外层完整性检查的 libFuzzer mutator，结合 AU 序列、状态事务和 PCM 边界检查 |
| 许可与发行 | LGPL Decoder/适配层、独立下游 Encoder 研究许可；文件头、安装与 CI 产物同步 |

## 随机访问中的继承元数据

`Sources/DecoderFramework/Decoder.cpp` 在 reset 后接受有效中途 major-sync AU。
完整音频流与每个 major sync 处重新开始的解码得到相同 PCM。

Major sync 不一定重发 OAMD 或 DRC 更新，因此它们不能由通道数或默认 unity
值代替。元素 PCM 继续输出，`positions_valid=0`，直到 OAMD 到达。
`sthd_decoder_drc_valid` 返回逐 presentation 的已接收 DRC 标志；它是 Decoder
1.2.0 的新增 C 函数，保留既有 Frame 布局和 ABI v3。失败不改变有效性状态。
FFmpeg 元数据以有效性标记表示缺失，未取得的坐标/gain-code tag 不输出。
项目内位置视图和渲染仍要求有效坐标。

位置及代码：`Sources/DecoderFramework/Decoder.cpp` 的 `restart`、`major_sync`、
`sthd_decoder_drc_valid`；公开约定见 `include/TrueHDDecoder.h` 和
[PLAY_API.md](PLAY_API.md)。

## 1.2 适配层的先前本机验证

- Xcode 26.3：decoder_cli Release 和 decoder_framework Debug 构建成功，两种
  产品均保留 arm64/x86_64；没有改变 Xcode 工程或 Encoder target 设置。
- Apple Clang 17 CMake Release：CTest 5/5，包含真实压缩的 7.1、12/14/16 元素
  fixture；通过损坏输入、头部组合、事务、随机访问和九布局测试。
- FFmpeg revision `2da55bf59a68801a8157ab141a487196ce3416a8`：最小构建启用独立
  `libtruehdd`，所有 15 个 PCM FATE 结果与 Swift 编码前参考哈希一致。
- 该 FFmpeg 配置 `make fate`：317/317 通过。补充了上游官方 1,301-byte MOV
  边界样本，未修改其测试或参考结果；不是所有 FFmpeg codec 的完整配置。
- 15 个 API case：逐样本 S32/PCM、两个独立实例、任意初始 PTS、flush、最终
  sample count/duration、OAMD 延迟及恢复、DRC 有效性、metadata off、损坏包/
  缺失 presentation 错误、preroll 和保留帧在 close 后的寿命均通过。
- 对 Decoder core 和适配 C 文件启用 ASan/UBSan，同样 15 个 API case 与编码前
  packed PCM 逐样本比对通过；Decoder sanitizer CTest 5/5。
- LLVM 23 libFuzzer 最终 47,521 次运行，coverage counter 1,767，未报告
  ASan/UBSan 错误。此为有界 smoke 验证，不声称穷尽所有损坏状态。
- 适配 C 文件及 API 测试以 `-Wall -Wextra -Werror` 编译通过。
- 安装脚本在干净的固定上游 checkout 应用及重复运行通过；不覆盖不同的已有
  adapter 文件。`mlpdec.c` 内容不变。

证据保留在忽略目录 `Build/FFmpegAdapter/`：`fate-all-final.log`、
`adapter-checks.log`、`api-sanitized.log`、`fuzz-final.log`、Xcode final build logs
及 CMake `Testing/Temporary/LastTest.log`。合成码流、参考来源和 SHA/MD5 在
[fixtures/references.json](../Integrations/FFmpeg/fixtures/references.json)。

## 后续边界

本轮没有创建或提交 FFmpeg PR。注册补丁针对固定上游 revision；提交时应更新到
当时 master、检查上下文并依照上游评审修改。macOS/Linux adapter CI 和 Linux
fuzz smoke 已加入项目 workflow；本机未执行 Windows/Linux 的新 CI job。

采样率 profile 保持 48 kHz，renderer/native playback 已接入逐采样 motion。程序级记录保留在
[VALIDATION.md](VALIDATION.md)。接入和复现步骤见
[Integrations/FFmpeg](../Integrations/FFmpeg/README.md)。

官方规则与基础接口：[开发规范](https://ffmpeg.org/developer.html)、
[FATE](https://ffmpeg.org/fate.html)、
[FFCodec](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/codec_internal.h)。

### Decoder 1.3 follow-up

适配层现在传递 sample-aligned OAMD motion，通过有界 float32 LE/base64 dictionary
保留精确轨迹，并标注量化的坐标快照。PCM checksum 默认 warning + corrupt-frame flag，
`AV_EF_EXPLODE` 选择事务性拒绝。Pkg-config 最低版本 1.3.0；C ABI v3 frame 不变。
新增 timed fixture，16 API cases 与 16 PCM FATE 通过，给定外部 MLP 的全文件 elements
PCM 与直接 CLI 的 MD5 一致。Xcode 构建与 encoder 源文件保持兼容。

当前完整外部文件的 adapter API 验证也通过：130,000 AUs、5,200,000 samples、
1,049 个 major sync，覆盖 PCM、PTS、trim、逐采样 motion dictionary、随机访问、
保留帧寿命和错误处理；96 个 mismatch 的 AVFrame corrupt 标记与 C API 证据一致。
严格 FFmpeg `-xerror -err_detect explode` 在 AU 372 正确终止。

### Decoder 1.4 official matrix follow-up

已接通 DME primitive/extended matrix、shift、dither、bypass、delta interpolation、
quantization、FIR/IIR state 和相关 guard/DRC/ramp 字段。Pkg-config 最低版本现为 1.4.0，
C ABI v3 Frame 不变。FFmpeg 复制 incoming target metadata，startup/seek 的未知 ramp
起点不标为有效坐标。矩阵字段、差异和完整程序验证见
[MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md)。没有修改或整合 mlpdec。

### Decoder 1.4.1 termination follow-up

Windows DEE 5.2.1 的完整流使用 `D234 E000` 零裁剪结束标记。Decoder 将 EOS
与采样裁剪分别跟踪，保留最后 40 个有效采样；reset 清除 EOS，标记之后的数据
事务性拒绝。Pkg-config 最低版本为 1.4.1。16 个 fixture API case、16 个 PCM
FATE 和该完整官方流的 PCM/API 对照通过，未修改 mlpdec。
