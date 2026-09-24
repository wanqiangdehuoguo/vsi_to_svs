# VSI → SVS：让 ImageScope 的 Positive Pixel Count V9 跑通

把 Olympus（CellSens / VS200 ASW）输出的 `.vsi` 数字病理切片转换成 Aperio `.svs`，
使 ImageScope 能打开、**Positive Pixel Count V9 能正常分析**，且颜色显示正确。

已验证样本：studio（121652×74284）与 FKBP4（120167×74250，TMA 组织芯片）。

---

## 为什么需要这个项目

ImageScope 的 Positive Pixel Count V9 对 SVS 有硬性要求，**三条必须同时满足**：

| 条件 | 说明 |
|------|------|
| 压缩格式 | 仅 JPEG(7) 或 JPEG2000/Kakadu(33005)。Deflate/LZW 一律不支持 |
| PhotometricInterpretation | 必须 RGB(2)，YCbCr(6) 会被算法拒绝 |
| **JPEG 码流与标签一致** | 标签写 RGB，JPEG 数据就必须真用 RGB 色彩空间编码 |

**核心矛盾**：`bfconvert`（Bio-Formats）和 `vips` 输出的都是 **YCbCr JPEG-in-TIFF** ——
因为 JPEG-in-TIFF 标准默认就是 YCbCr，两者都没有开关能改成 RGB。于是绕不过去：

- 只用 `tiffset` 把标签改成 RGB → **分析能过，但显示偏红**（标签说 RGB，码流还是 YCbCr）
- 改用 Deflate 拿到 RGB photometric → **颜色对，但压缩格式不被支持**
- 文件体积膨胀到 9 GB 也救不了

**唯一出路是重编码 JPEG 码流本身** —— 这就是本项目的 Phase 3。

---

## 快速开始

**前提**：`.vsi` 文件 + 同名配套文件夹 `_<切片名>_/`（内含 `stack1/`、`stack10000/`、`stack10002/frame_t.ets`）。
`.vsi` 只是个外壳（内嵌 label/macro/缩略图，约 2 MB），**真正的全片金字塔全在配套文件夹里**，只给 `.vsi` 是转不了的。

```bash
# 1) 预演：核对自动识别出的 series 与尺寸
bash vsi_to_svs.sh --input /path/to/slide.vsi --dry-run

# 2) 正式转换（后台跑务必带 CLEANUP=no，否则结尾的交互确认会挂住）
CLEANUP=no bash vsi_to_svs.sh --input /path/to/slide.vsi
```

输出：`$WORK_DIR/<切片名>_final.svs`（默认 `WORK_DIR=${HOME}/svs_work`）。

**主切片 series 与尺寸都由 `showinf` 自动识别**，不需要手工查。唯一要人工确认的是
`--dry-run` 打印出的 series 编号与宽高是否合理。不对就覆盖：

```bash
bash vsi_to_svs.sh --input slide.vsi --series 13 --full-width 120167 --full-height 74250
```

完整参数见 `bash vsi_to_svs.sh --help`。

---

## 工作原理：四个阶段

每个阶段各自解决一个别的手段解决不了的问题，不能合并：

```
<切片>.vsi ─[Phase 1: bfconvert]→ <切片>_base.tif
                                      │
                                      ▼
                    [Phase 2: vips tiffsave]→ <切片>_pyramid.svs
                                      │
                                      ▼
                    [Phase 3: reencode_rgb_jpeg.py]→ <切片>_final.svs
                                      │
                                      ▼
                              [Phase 4: 验证]
```

| 阶段 | 工具 | 解决什么 |
|------|------|---------|
| 1 | `bfconvert -series <N>` | **只有 Bio-Formats 能读 CellSens `.ets`**。输出单层 BigTIFF |
| 2 | `vips tiffsave --pyramid` | **vips 是唯一能快速生成 10 级 256×256 tile 金字塔的手段** |
| 3 | `reencode_rgb_jpeg.py` | **修正颜色空间**：逐 tile 解码 YCbCr → `imagecodecs.jpeg_encode(outcolorspace='RGB', subsampling='444')` 重编码 → 写新 BigTIFF，再用 `tiffset` 补 Aperio 标签 |
| 4 | `tiffinfo` + `openslide` | 校验 vendor / level_count / Photometric / RGB 均值 |

**关键不变量**：JPEG 码流的色彩空间必须等于 `PhotometricInterpretation` 标签。
破坏它就会掉进「分析过但偏红」或「显示对但分析失败」的二选一。

耗时参考（8.9 Gpixel，写入 xfs 大盘）：Phase 1 ~25 min，Phase 2 ~1 min，Phase 3 ~1 min。

---

## 环境依赖

| 组件 | 用途 | 说明 |
|------|------|------|
| Bio-Formats 8.1.1（`bfconvert`、`showinf`） | 读 VSI、枚举 series | [bftools 下载](https://www.openmicroscopy.org/bio-formats/downloads/) |
| conda env: `rnaseq` | tifffile, imagecodecs, numpy | **RGB JPEG 重编码**（`outcolorspace='RGB'` 只在 imagecodecs 里） |
| conda env: `ipy` | openslide-python, libtiff | `tiffset`/`tiffinfo` 标签修补与验证 |
| conda env: `vips` | libvips, pyvips | 金字塔构建 |

环境分工是**硬性的** —— `imagecodecs` 只在 rnaseq 里，`openslide` 只在 ipy 里。
`reencode_rgb_jpeg.py` 用 rnaseq 的 python 跑，但内部 `subprocess` 调用 ipy 的 `tiffset`
和 python 做验证，靠 `--tiffset` / `--openslide-py` 参数显式传路径，不依赖 `PATH`。

**所有路径都可以用环境变量覆盖**，换成你自己的环境即可：

```bash
BFCONVERT=... SHOWINF=... VIPS=... TIFFSET=... TIFFINFO=... \
OPENSLIDE_PY=... RNASEQ_PY=... WORK_DIR=... \
  bash vsi_to_svs.sh --input slide.vsi
```

---

## 转换完成后必须验证

三项全过才算成功：

```bash
SVS=/path/to/slide_final.svs

# ① 10 级 IFD 的标签
~/.conda/envs/ipy/bin/tiffinfo "$SVS" | grep -E \
  'TIFF directory|Compression|Photometric|Subfile Type'
# 期望: 全部 Compression=JPEG(7) + Photometric=RGB color + Subfile Type=0

# ② openslide 元数据
~/.conda/envs/ipy/bin/python3 -c "
import openslide
o = openslide.OpenSlide('$SVS')
print(o.properties.get('openslide.vendor'), o.level_count, o.properties.get('openslide.mpp-x'))"
# 期望: aperio  10  0.2738

# ③ 颜色一致性（判红）
```

**判红方法**：在组织区取一块比三通道均值。

- 正常 IHC（DAB 棕色）：`R−G ≈ 10` 左右 —— 棕色本就 R>G>B，**这是正常的，别误判**
- 方案 4 那种病态偏红：R 明显更高，且肉眼可见粉红

⚠️ **验证颜色必须用两条以上独立解码路径**（例如 tifffile 与 vips/libtiff 各读一次同一坐标）。
如果源和产物都由同一个可能出错的解码器读取，两边会「一致地错」，你会得到一个虚假的通过。

---

## 目录

```
├── README.md                       # 本文件
├── CLAUDE.md                       # 详细知识库（架构 / 迭代史 / 兼容性清单 / 已知陷阱）
├── vsi_to_svs.sh                   # 主入口：四阶段工作流
├── reencode_rgb_jpeg.py            # Phase 3：RGB JPEG 重编码（可独立调用）
└── docs/
    ├── job1.txt / job2.txt / job3.txt    # 最初三次问题记录（项目起点）
    ├── positive-pixel-count-issue.md     # 排查阶段的方案分析（结论已被最终方案取代）
    └── example-run.md                    # 一次成功运行的完整日志
```

**建议先读 `CLAUDE.md`** —— 它记录了完整的迭代历史（方案 1–5 各自为什么失败）、
ImageScope 兼容性完整清单、以及踩过的坑（`du` 与 `ls` 大小不一致、TMA 中心恰是空洞等）。

---

## 已知限制

- **`reencode_rgb_jpeg.py` 的 argparse 默认尺寸硬编码为某个样本的值**。裸调它而不传
  `--full-width/--full-height` 会把错误尺寸写进 Aperio ImageDescription，导致分析失败。
  **请通过 `vsi_to_svs.sh` 调用**（它会自动探测并透传），或显式传参。
- **输出 tile 固定 256×256** —— 已验证可用的配置，也是 Aperio 惯例。源 tile 是 512 也没关系，
  bfconvert 会重切。
- 单张切片中间产物 + 输出约 5 GB，`WORK_DIR` 请指向大盘。
- Phase 1 是单层 series，**没有进度输出**；想看进度盯输出文件大小。
- 只支持 Olympus 的 VSI。其他厂商格式需另找 Bio-Formats reader。

---

## 许可

未指定。
