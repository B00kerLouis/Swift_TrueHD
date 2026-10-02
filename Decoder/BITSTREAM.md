# Encoder 输出分析与 decoder 实现

所有下列结构已通过当前源码和给定素材的全片输出验证。decoder 的支持范围以当前项目的输出 profile 为边界；不会将尚未实现的其他 TrueHD 语法解释成此 profile。

## 编码流程

1. `NativeMasterReader.open` 识别 MXF IAB/DAMF/ADM 或 PCM WAVE。`TrueHDEncoder` 根据 ADM metadata 选择普通 7.1 或 Atmos。
2. 普通 7.1 输入顺序为 `L R C LFE Lb Rb Ls Rs`，分成三个累积子流：0..1、2..5、6..7。
3. Atmos `AtmosSpatialCoder.prepareElementCache` 对 IAB 解码、空间锚点归并和 headroom/limiter 进行准备。稳定 basis 为八个地面/LFE 元素加 4/6/8 个高度元素；完整对象音轨不直接逐轨写入 TrueHD。
4. 每个 40-sample AU 将元素转换为共享 transport basis。前两项包含中心与环绕折叠；后续子流通过各自独立逆矩阵生成 5.1、7.1 和 immersive 元素。第四层矩阵逐行执行，不能先把 7.1 的逆矩阵应用到共享 PCM，再复用那份结果。
5. 每个 restart AU 的第一块是 8 个原始采样，为后续 FIR 提供种子；第二块为 32 个采样，其后 AU 通常为 40 个采样。FIR 固定阶和 LPC 分析最终都写成量化的 FIR 系数。三本固定 MLP Huffman codebook 和有符号 15-bit offset 由实际码率成本选择，offset 和滤波参数在 AU 之间继承。
6. OAMD 携带固定空间位置；原始对象运动已在 encoder 的 PCM panning 中表达。Evolution 的 HMAC 覆盖整个 AU prefix 与清零认证字段后的 canonical frame。transport rewriter 最后重写 input timing 和 peak rate，并重新认证。

## AU 容器

| 位置 | 长度 | 含义 |
|---|---:|---|
| byte 0..1 | 16 bit BE | 高 4 bit 为 header parity，低 12 bit 为 AU 总长度（16-bit word） |
| byte 2..3 | 16 bit BE | `input_timing`，decoder 缓冲输入调度，不是固定 PCM 播放 PTS |
| byte 4 | 28 或 32 byte，可选 | `F8 72 6F BA` major sync，48 kHz FBA；普通三层或 Atmos 四层 |
| major sync + 16 | 4 bit | 累积子流数（整体 AU byte 20 的高半字节） |
| major sync 最后两字节 | LE16 | MLP checksum16 |
| major sync 之后 | 每层 2 或 4 byte | 子流 directory；低 12 bit 为累计结束位置（word），bit 15 表示 DRC extra word |
| directory 之后 | 变长 | 累积音频子流，均有 parity 与 checksum8 |
| 最后音频子流之后 | 可选变长 | 受保护 Evolution/OAMD wrapper |

AU 总长度最多 8190 byte，48 kHz 下通常代表 40 个采样，最后一帧可裁剪。DRC extra word 的高 9 bit 为有符号 gain code，低 7 bit 为插值时间 code 7 与保留位。decoder 返回 gain code，保持默认无 DRC 的 PCM。

## 子流与预测

每块首先读取 parameter-present 和 restart-present。restart 类型为 `0x31EA`（stereo）、`0x31EB`（six/eight）或 `0x31EC`（immersive）。restart 包括 channel 范围、generator seed、先前 interval 的 PCM lossless checksum、`ch_assign` 和 restart CRC。

Huffman 的还原为：

```text
signed_offset = inherited_offset
if codebook != 0: signed_offset -= 7 * 2^lsb_bits
sign_shift = lsb_bits + (codebook != 0 ? 2 - codebook : -1)
if sign_shift >= 0: signed_offset -= 2^sign_shift
residual = signed_offset + vlc_table_index * 2^lsb_bits + low_bits
prediction = floor(sum(coeff[i] * decoded_history[i]) / 2^filter_shift)
sample = wrap32(residual + prediction)
```

系数、history 和加法的宽度、负数 floor 和 wrap32 均显式处理，不依赖 C++ 对负数移位或超范围有符号窄化的实现行为。原始 transport 在各层之间保留；矩阵计算在独立副本上逐行进行，然后执行 output shift，输出 24-bit PCM，按 `ch_assign` 排列。FBA 7.1 的 speaker IDs 是 side-before-back，WAVE mask 顺序是 back-before-side，必须转换。

Atmos canonical `ch_assign` 为 `[2,10,7,8,3,0,4,5,9,11,12,13,14,15,6,1]`，12/14 元素使用小于元素总数的子集。OAMD 已经按该 permutation 的解码输出顺序排列，因此 renderer 使用实际解码出的 `positions[output_index]`，不能硬编码“第 8 个就是某个高度扬声器”。

## 校验与有界解析

decoder 校验 AU 长度和 header parity、directory 范围、major-sync CRC、每层 restart CRC、每层 parity/checksum8、先前 restart interval 的 PCM checksum、四层一致的末帧裁剪、Evolution wrapper 长度/parity、OAMD 元素长度和语法，以及 EMDF primary HMAC-SHA256。最终不完整 interval 没有下一次 restart PCM checksum；它仍有子流 CRC/parity 和有界解析。

任何失败都不提交解码状态。状态为固定数组；元数据与 HMAC 的临时存储上限由一个 AU 限定。开始解码必须有 major sync；显式 reset 表示切换流，未提供 seek/resync 扫描器。

## 扬声器渲染

| 布局 | 通道数 | 默认文件/API 顺序 |
|---|---:|---|
| 2.0 | 2 | FL FR |
| 5.1 | 6 | FL FR FC LFE SL SR |
| 7.1 | 8 | FL FR FC LFE BL BR SL SR |
| 5.1.2 | 8 | FL FR FC LFE SL SR TML TMR |
| 5.1.4 | 10 | FL FR FC LFE SL SR TFL TFR TBL TBR |
| 7.1.2 | 10 | FL FR FC LFE BL BR SL SR TML TMR |
| 7.1.4 | 12 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR |
| 7.1.6 | 14 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR TML TMR |
| 9.1.6 | 16 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR TML TMR FWL FWR |

Atmos 的 2.0/5.1/7.1 使用码流的相应兼容呈现；plain 7.1 的 stereo/5.1 渲染从完整 bed 下混，原始呈现提取仍不变。高度布局使用 immersive 元素及 OAMD 房间坐标，在相邻左右位置、前侧后平面、地面与高度平面之间做 cos/sin 等功率插值。LFE 只送 LFE；5.1 地面布局将 rear/side 对应折叠到 surround；.2 高度布局将高度的前后位置折叠到 Top Middle。床声道流可渲染地面，高度保持零。

9.1.6 的 front-wide 在侧与前平面之间。固定 encoder basis 缺少该位置，给定两部输出的 wide 能量只有浮点零点残差，24-bit WAVE 中为零；不能凭空恢复原始 IAB 位置。任意实际 front-wide 坐标经 C API 渲染时会送到真正的 FWL/FWR，脉冲验证覆盖此路径。

## 方案选择记录

| 候选 | 评估 |
|---|---|
| A：FFmpeg 子进程 | 引入运行时 executable，缺少第四层空间元素解码，不满足独立 decoder 要求 |
| B：嵌入通用 libavcodec | 可复用成熟兼容呈现，但仍不能覆盖本项目 FBA 第四层矩阵/OAMD，依赖范围大 |
| C：完整通用 TrueHD/MLP decoder | 范围包含多采样率、IIR、noise、其他 OAMD；超出该项目当前 profile，验证证据不足 |
| D：连接既有 Swift encoder/Apple decoder API | 违反 decoder 的纯 C/C++ 与跨平台边界，Apple API 也不提供所需完整元素访问 |
| E：从当前 encoder 反向实现独立 C++ 核心、C ABI 与 renderer | 有全部语法和可生成 PCM oracle；有界 I/O、Xcode/CMake 独立构建，选择此方案 |

渲染另比较了固定通道复制、补零、通道数猜测、方向向量 VBAP 与房间坐标等功率网格。选择最后一项以匹配此 encoder 的 Cartesian basis；显式按标签路由和能量守恒，保留源锚点位置。没有冒称通用 Dolby renderer 的等价实现。

主要依据是本地 Swift encoder 和实际输出；固定 MLP 字段及基础算法另与 [FFmpeg 官方实现](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mlpdec.c) 核对。扬声器命名参考 [Dolby 布局指南](https://www.dolby.com/siteassets/technologies/dolby-atmos/atmos-installation-guidelines-121318_r3.1.pdf)，ALSA 标签核对 [ALSA 官方源码](https://github.com/alsa-project/alsa-lib/blob/master/include/pcm.h)。没有将第三方 codec 源码导入 decoder。
