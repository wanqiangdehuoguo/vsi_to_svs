# ImageScope Positive Pixel Count V9 卡住问题 — 解决方案

## 问题描述

`studio.svs`（870MB，121652×74284）能在 ImageScope V12.4.6.5003 中打开和显示，
但手动框选后运行 `View → Analysis → Positive Pixel Count V9 → Analyze Annotations` 时卡住不动。

## 根因分析

SVS 文件由 vips + tiffset 生成，非 Aperio 扫描仪原生输出。ImageScope 的分析算法
（Positive Pixel Count V9）是硬编码为 Aperio 原生 SVS 格式设计的，对转换文件存在兼容性问题：

| 问题 | 当前文件 | Aperio 原生 SVS |
|------|---------|-----------------|
| Photometric Interpretation | YCbCr（vips 生成） | YCbCr，但 JPEG tile 编码格式不同 |
| JPEG chroma subsampling | vips 默认 | Aperio 特定 subsampling |
| BigTIFF | 是（--bigtiff） | 不需要（文件 < 4GB） |
| Macro / Label image | 缺失 | 有（算法可能依赖） |
| 子 IFD ImageDescription | 空格 `" "` | Aperio 格式描述 |

算法在尝试解码像素时，很可能因格式不兼容而陷入循环。

---

## 方案一（最推荐）：换用 QuPath

QuPath 是免费开源的病理图像分析软件，内置 Positive Pixel Detection 算法，
兼容几乎所有全切片格式。

### 优点

- 直接读取现有 `studio.svs`（通过 OpenSlide），无需重新转换
- 阳性像素检测算法比 ImageScope V9 更现代、更高效
- 支持批量分析、结果导出
- 跨平台（Windows / macOS / Linux）

### 安装

下载地址：https://qupath.github.io/

### 使用步骤

1. 打开 QuPath → `File → Open` → 选择 `/mnt/data1/svs_work/studio.svs`
2. 使用矩形工具框选组织区域
3. `Analyze → Preprocessing → Simple tissue detection`（可选，自动分割组织）
4. `Analyze → Positive pixel detection` → 设置颜色阈值参数
5. 查看结果，导出数据

### 注意

QuPath 读取当前 `studio.svs` 时通过 OpenSlide 解码，会正确处理 YCbCr → RGB 转换，
不受 ImageScope 算法兼容性问题影响。

---

## 方案二：用 LZW / Deflate 压缩重建 SVS（RGB Photometric）

JPEG 压缩产生 YCbCr photometric，这是算法不兼容的根源。
改用 **Deflate 压缩**会产生 **RGB photometric**，ImageScope 的分析引擎能正确解码。

### 操作命令

```bash
cd /mnt/data1/svs_work

VIPS=/home/user/.conda/envs/vips/bin/vips
TS=/home/user/.conda/envs/ipy/bin/tiffset
TI=/home/user/.conda/envs/ipy/bin/tiffinfo

# 1. 用 deflate 压缩重建金字塔（RGB photometric）
$VIPS tiffsave studio_base.tif studio_deflate.svs \
  --tile --tile-width=256 --tile-height=256 \
  --pyramid --compression=deflate --bigtiff

# 2. 修补 Aperio ImageDescription
W=121652; H=74284; TW=256; TH=256
DESC="Aperio Image Library v12.0.15
${W}x${H} [0,0 ${W}x${H}] (${TW}x${TH}) JPEG/RGB Q=80|AppMag = 20|MPP = 0.2738"
$TS -s 270 "$DESC" studio_deflate.svs
$TS -s 305 "Aperio Image Library v12.0.15" studio_deflate.svs

# 3. 验证
$TI studio_deflate.svs 2>&1 | head -30
```

### 注意事项

- Deflate/LZW 压缩的文件比 JPEG 大很多（预估 5–15 GB）
- 确保磁盘空间充足：`df -h /mnt/data1`
- 如果空间不够，可以改用 `--compression=lzw`（类似体积）
- 即使修复了 photometric，**仍不能保证 Positive Pixel Count V9 一定工作**
  （算法还可能依赖 macro/label image 等其他 Aperio 特有结构）

---

## 方案三：快速测试——先选一个极小区域

在做任何重转之前，先排除是否是**区域太大导致的性能问题**。

### 步骤

1. 在 ImageScope 中打开 `studio.svs`
2. 用 Rectangle Tool 框选一个**极小的区域**（约 100×100 像素）
3. 运行 `View → Analysis → Positive Pixel Count V9 → Analyze Annotations`

### 判断

| 结果 | 结论 | 后续 |
|------|------|------|
| 小区域也卡住 | **格式问题** | 用方案一（QuPath）或方案二（重转） |
| 小区域能跑通 | **性能问题**（图片太大） | 用方案一（QuPath，处理大图更高效） |

---

## 总结推荐

```
方案三（快速测试）→ 确认是格式还是性能问题
         ↓
方案一（QuPath） ← 无论哪种情况都推荐
         ↓（如必须用 ImageScope）
方案二（Deflate 重转） ← 不保证一定成功
```
