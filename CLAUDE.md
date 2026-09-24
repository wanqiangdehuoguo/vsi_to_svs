# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **关于路径**：文档与脚本中的路径一律用 `~/`、`${HOME}` 或环境变量表示，不写死绝对路径。文中偶见的 `/mnt/dataN/...` 是作者本机的挂载点示例，**请按自己的环境调整** —— 脚本的所有工具路径与参数都能用环境变量覆盖（见「软件环境」与 `--help`）。
>
> **关于样本名**：`studio` / `FKBP4` / `BRIX1 ARRAY-1` 是切片文件的代号，保留在文中是因为它们是迭代史的一部分（例如「两张片子恰好都是 series 13」这个观察）。

---

## 项目概述

将 CellSens VSI (Olympus) 格式的数字病理切片转换为 Aperio SVS 格式，使 ImageScope 能够打开并进行 **Positive Pixel Count V9** 分析。

这是一个**通用转换管道**，不绑定某一张切片：每次换一个输入，管道本身不变。studio 只是首个打通格式的样本（`studio_final.svs`，2.18 GB，2026-07-13 验证通过 —— 分析可用、颜色正常）；FKBP4 是第二次跑通（`FKBP4_final.svs`，2.98 GB，2026-09-24）。

---

## 快速开始（下次转换新切片）

**前提**：`.vsi` 文件 + 同名配套文件夹 `_<切片名>_/`（内含 `stack1/`、`stack10000/`、`stack10002/frame_t.ets`）。只给 `.vsi` 是转不了的，见「输入数据约定」。

```bash
cd <本仓库根目录>

# 1) 先预演：核对自动识别出的 series 与尺寸
bash vsi_to_svs.sh --input /path/to/new.vsi --dry-run

# 2) 确认无误后正式转换（后台跑必须带 CLEANUP=no）
CLEANUP=no bash vsi_to_svs.sh --input /path/to/new.vsi
```

**不需要手工查 series 和尺寸** —— 脚本用 `showinf` 自动识别主切片（展平后像素数最大的 series）并读出 `FULL_W/FULL_H`。输出落在 `${HOME}/svs_work/<切片名>_final.svs`。

**唯一需要人工确认的**：`--dry-run` 打印出的 series 编号与尺寸是否合理（主切片应是整张图里最大的那个）。不对就用 `--series N` / `--full-width` / `--full-height` 覆盖。

中途看进度：`tail -f ${HOME}/svs_work/convert.log`（Phase 1 无进度行，看输出文件大小增长）。

**转换完成后必须验收**，见「验证」与「FKBP4 实测结果」两节 —— 三项都要过：10 级 IFD 标签、openslide 元数据、三通道颜色一致性。

---

## 当前状态（2026-09-24 更新，务必先读）

1. **studio 那批数据已不在本机 —— 是有意交接，不是丢失。** 用户把 studio 相关的切片文件转交给他人后删除了本地副本；`/mnt/data1/svs_work/` 现已清空（该盘 29 GB，mtime 2025-11-29）。`studio.vsi`、`_studio_/`、`studio_base.tif`、`studio_pyramid.svs`、`studio_final.svs`、`BRIX1 ARRAY-1.svs` 全机均无副本。**不要去「找回」，也不要据此认为项目停滞** —— 这只意味着 studio 不能再作为复现输入；格式知识（下文「核心问题根因」「兼容性要点」）依然完全有效，且已在后续切片上复用。

2. **此后每张片子都是不同来源的数据。** 每换一张都要重新识别 series 与尺寸 —— 脚本已自动识别（见「快速开始」），但 `--dry-run` 核对不能省。
   - **FKBP4（已完成并交付，2026-09-24）**：TMA 组织芯片，约 10×17 芯，IHC/DAB 染色；主切片 series 13 = `20x_BF_01`，120167×74250，MPP 0.2738113。产物 `FKBP4_final.svs` (2.98 GB) 已验收，副本与源数据（`FKBP4.vsi` + `_FKBP4_/`）都在 `/mnt/data3/` —— **该盘现已卸载**，要用先 `sudo mount /mnt/data3`。

3. **路径一律用 `~/` 或环境变量引用，不写死绝对路径。** 脚本的工具路径全部基于 `${HOME}`，`WORK_DIR` 默认 `${HOME}/svs_work`，换机器只需覆盖环境变量而不必改脚本。历史上旧版脚本曾把 `REENCODE_PY` 默认指向一个不存在的 `~/svs_format/`（项目实际在 `~/workspace/svs_format/`），导致裸跑必然 `exit 1` —— 已于 2026-09-24 修正为相对脚本目录解析。

4. **方案 1–4 的脚本已清理，不在仓库中**：`convert.sh`、`auto_build_svs.sh`、`fix_svs.sh`、`fix_svs_aperio.py`、`rebuild_rgb_jpeg_svs.py`、`patch_aperio_tags.sh` 均已删除。它们只在下文的历史记录里保留，供理解「为什么最后是方案 5」——**不要尝试调用它们**。

5. **`docs/positive-pixel-count-issue.md` 是问题排查阶段的历史文档**，其结论（推荐 QuPath、或用 Deflate 重转）已被方案 5 取代（Deflate 路线实测分析失败）。仅在追溯排查思路时参考。

---

## 换切片检查清单（每次换输入都要走一遍）

格式知识是通用的，但**编号和尺寸是每张片子各不相同的**。studio 与 FKBP4 恰好都是 series 13，那是 Olympus VS200 ASW 的排布规律（label 金字塔 + overview 金字塔在前，主切片紧随其后），**不是可以照抄的常数**。

1. **确认配套文件夹存在且同名**：`/path/_<切片名>_/`（或 `_<切片名>`），内含 `stack1/`、`stack10000/`、`stack10002/frame_t.ets`。缺了它 showinf 会报 `Missing expected .ets files`，且只能列出 label/macro 小图（几百像素级）。名字不符就改名配套文件夹，**不要改 `.vsi`**。
2. **`--dry-run` 核对 series 与尺寸**。脚本自动取「展平后像素数最大」的 series，通常就是主切片；核对打印出的编号与宽高是否合理。手工枚举：
   ```bash
   ~/workspace/software/bftools/showinf -nopix <切片>.vsi | grep -E 'Series count|^Series #|Width =|Height ='
   ```
   注意 **bfconvert 用的是「展平后」的编号**（showinf 默认不带 `-noflat`），与 `-noflat` 的编号不同 —— 必须用不带 `-noflat` 的那份列表。主切片的 OME 名常带倍率（如 `20x_BF_01`）。
3. **抽查一处组织，目视确认选对了 series**：从主切片裁一小块渲染出来看，别只看尺寸数字。
   ```bash
   ~/workspace/software/bftools/bfconvert -series <N> -no-sas -crop <x>,<y>,1024,1024 <切片>.vsi /tmp/probe.tif
   ~/.conda/envs/vips/bin/vips copy /tmp/probe.tif /tmp/probe.png   # 然后目视
   ```
   **注意**：组织芯片（TMA）的几何中心往往正好落在组织芯之间的空隙上，会得到一张近乎全白的图 —— 这**不代表选错了**。多点采样几个位置再判断。
4. **`--mpp` / `--apmag`**：多数情况下 0.2738 / 20 可复用，但新扫描仪或不同物镜要改。可从 `.vsi` 元数据读（showinf 输出的 `Physical pixel size` / `Magnification`）。


---

## 目录布局

```
<仓库根>/
├── README.md                      # 面向使用者的说明（先读这个）
├── CLAUDE.md                      # 本文件 —— 详细知识库
├── vsi_to_svs.sh                  # 一键转换工作流（Phase 1–4）—— 主入口
├── reencode_rgb_jpeg.py           # Phase 3 核心：RGB JPEG 重编码（可独立调用）
├── .gitignore                     # 排除 *.svs / *.vsi / *.tif 等产物与 .claude/settings.local.json
└── docs/
    ├── job1.txt / job2.txt / job3.txt   # 最初三次问题记录（项目起点）
    ├── positive-pixel-count-issue.md    # 排查阶段的方案分析（结论已被方案 5 取代）
    └── example-run.md                   # 一次成功运行的完整日志

${HOME}/svs_work/                  # 输出（脚本默认 WORK_DIR，可用 --work-dir 改）
├── <切片名>_final.svs             # 最终产物
├── <切片名>_base.tif              # Phase 1 中间产物（--no-cleanup 保留；重跑 Phase 3 可省 25 min）
├── <切片名>_pyramid.svs           # Phase 2 中间产物
└── convert.log                    # 运行日志
```

输入数据（`.vsi` + 配套文件夹 `_<切片名>_/`）**位置不固定** —— 每张切片各在别处，用 `--input` 指定，脚本不假设任何固定位置。

`docs/job*.txt` 是 studio 阶段三次提出同一问题的原始记录，保留了当时的 `tree -h` 输出（含 `_??_rpl8_` 目录名、各 stack 大小）。studio 数据已交接他人，这几个文件是仅存的输入形态记录。

---

## 核心问题根因：JPEG 颜色空间不匹配

ImageScope Positive Pixel Count V9 要求 SVS 同时满足三个条件：

| 条件 | 说明 |
|------|------|
| **压缩格式** | 必须是 JPEG (7) 或 JPEG2000/Kakadu (33005)。Deflate/AdobeDeflate(8/32946)/LZW(5) 均不支持 |
| **PhotometricInterpretation** | 必须是 RGB(2)；YCbCr(6) 会被算法拒绝 |
| **JPEG 码流与标签一致** | 标签说 RGB → JPEG 数据必须真用 RGB 色彩空间编码（component ID = R/G/B，而非 Y/CbCr） |

**核心矛盾**: bfconvert 和 vips(JPEG) 都输出 YCbCr JPEG-in-TIFF —— 因为 JPEG-in-TIFF 标准默认 YCbCr，两者都没有开关能改成 RGB。于是：
- 只改标签不改数据 → 分析通过但**显示偏红**（方案 4）；
- 换 Deflate 拿 RGB → 颜色对但**压缩格式不被支持**（方案 2/def 路线）。

只有**重编码 JPEG 码流本身**才能同时满足三条。

---

## 架构：为什么是四阶段

每个阶段各自解决一个别的手段解决不了的问题，不能合并：

```
<切片>.vsi ─[Phase 1: bfconvert]→ <切片>_base.tif ─[Phase 2: vips tiffsave]→ <切片>_pyramid.svs
                                                                                    │
                        [Phase 4: 验证] ←─[Phase 3: reencode_rgb_jpeg.py]──── <切片>_final.svs
```

| 阶段 | 工具 | 耗时 | 解决什么 |
|------|------|------|---------|
| 1 | `bfconvert -series <N>` | ~25 min（/mnt/data4） | **只有 Bio-Formats 能读 CellSens `.ets`**。输出单层 BigTIFF |
| 2 | `vips tiffsave --pyramid` | ~1 min | **vips 是唯一能快速生成 10 级 256×256 tile 金字塔的手段**；bfconvert 的金字塔选项产不出 Aperio 要的结构 |
| 3 | `reencode_rgb_jpeg.py` | ~1 min | **修正颜色空间**。逐 tile 解码 YCbCr → 用 `imagecodecs.jpeg_encode(outcolorspace='RGB', subsampling='444')` 重编码 → `tifffile.TiffWriter` 写新 BigTIFF |
| 4 | `tiffinfo` + `openslide` | 秒级 | 校验 vendor / level_count / Photometric / RGB 均值 |

Phase 1 的耗时主要由**写入磁盘速度**决定，不只看切片大小：studio 当年写在 `/mnt/data1`（29 GB 小盘）上约 2.5 h；FKBP4 写在 `/mnt/data4`（102 TB xfs）上只要 **25.5 分钟**（8.9 Gpixel，1531 s）。这也是把 `WORK_DIR` 默认指向 `/mnt/data4` 的原因之一。

**进度怎么看**：`bfconvert -series <N>` 是展平后的**单层** series，所以它只在结尾打一次 `Converted 1/1 planes (100%)`，中途没有进度行。想看进度就盯输出文件大小（TIFF 顺序写入，大小 ≈ 已写 tile 数）；Phase 2/3 有正常的分层进度输出。

Phase 3 内部还有一层：写完后用 `tiffset` 做后处理，清除 `YCbCrSubSampling`(530)、设 `SubfileType=0`(254)、写 Aperio 格式的 `ImageDescription`(270) 与 `Software`(305)。**`tifffile` 写入时的 `compressionargs` 才是关键**，`tiffset` 只是补标签。

### 关键不变量

改动本仓库任何代码时，必须守住：**JPEG 码流的色彩空间 == `PhotometricInterpretation` 标签**。破坏它就会出现「分析过但偏红」或「显示对但分析失败」的二选一。验证方法见 Phase 4 的 RGB 均值检查（正常应接近 `R≈241 G≈241 B≈240`，明显 R 偏高即偏红）。

---

## 迭代历史（结论：方案 5 是唯一可用方案）

| # | 方案 | 做法 | 结果 | 失败原因 |
|---|------|------|------|---------|
| 1 | `convert.sh` (07-08) | bfconvert 直转 + tiffset 补 Aperio 标签 | 进程被 kill | 未完成 |
| 2 | `auto_build_svs.sh` (07-08) | bfconvert + vips JPEG 金字塔 → `studio.svs` (871 MB) | 显示正常，**分析失败** | Photometric=YCbCr(6) |
| 3 | `fix_svs.sh` (07-10) | 修 `ImageDescription` 裁剪区域、清子 IFD 的 ImageJ 元数据 | 同方案 2 | 没碰 Photometric |
| 4 | `fix_svs_aperio.py` (07-10) | **就地**把标签 YCbCr→RGB、`SubfileType` 1→0 → `studio_fixed.svs` (875 MB) | **分析可用 ✅，显示偏红 ❌** | 标签说 RGB，码流仍是 YCbCr |
| def | Deflate 路线 | vips `--compression=deflate` 拿 RGB photometric (9.1 GB) | **分析失败** | 压缩格式不被 V9 支持 |
| **5** | **`rebuild_rgb_jpeg_svs.py` → `reencode_rgb_jpeg.py` (07-13)** | **真 RGB JPEG 重编码** | **`studio_final.svs` (2.18 GB) 分析 ✅ 显示 ✅** | — |

**教训**: 方案 4 是关键的诊断分水岭 —— 它证明了「分析失败」和「偏红」是两个独立的成因，分别由 Photometric 标签和 JPEG 码流色彩空间控制。不要再用 `tiffset` 改标签来"修"颜色。

---

## 各产物对照表

| 文件 | 大小 | 压缩 | Photometric | JPEG 码流 | 分析 | 显示 |
|------|------|------|-------------|----------|------|------|
| `BRIX1 ARRAY-1.svs`（参考） | 692 MB | JP2K | RGB | — | ✅ | ✅ |
| `studio.svs` | 871 MB | JPEG | YCbCr | YCbCr | ❌ | ✅ |
| `studio_fixed.svs` | 875 MB | JPEG | RGB(假) | YCbCr | ✅ | ❌ 偏红 |
| `studio_deflate_patched.svs` | 9.1 GB | Deflate | RGB | — | ❌ | ✅ |
| **`studio_final.svs`** | **2.18 GB** | **JPEG** | **RGB** | **RGB(真)** | **✅** | **✅** |

上表是 studio 阶段各方案的实测结果，全部产物已随 studio 数据交接他人，本机无副本 —— 表格保留作为**格式判定依据**：看一张 SVS 落在哪一列，就知道它会「分析失败」还是「偏红」。

`BRIX1 ARRAY-1.svs` 曾是唯一可用的 Aperio 原生参照样本（JP2K、含 macro/label image），历史上用于对齐标签格式；现已不在本机。

### FKBP4 实测结果（2026-09-24，管道第二次跑通）

`${HOME}/svs_work/FKBP4_final.svs`，2.98 GB，全程 27 分钟：

| 检查项 | 结果 |
|---|---|
| 10 级 IFD 全部 | `Compression=JPEG` + `Photometric=RGB` + `SubfileType=0` + `ImageDescription` 以 `Aperio Image Library` 开头 ✅ |
| openslide | `vendor=aperio`、`level_count=10`、`mpp=0.2738`、`objective=20` ✅ |
| 金字塔 | 120167×74250 → 60083×37125 → … → 234×145（10 级，tile 256×256）✅ |
| 颜色 | 三条独立解码路径（tifffile / vips+libtiff / openslide）在同一坐标均得 `R=227 G=216 B=209`，与源**逐位一致** —— 无色彩偏移 ✅ |

**判红方法**：在组织区取一块比三通道均值。studio 是 `R=241 G=241 B=240`（几乎相等）；FKBP4 是 `R=227 G=216 B=209`（R−G≈11）。**R−G 在 10 上下是 DAB 棕色染色的正常表现**（棕色本就 R>G>B），别误判；方案 4 那种病态偏红数值明显更大且肉眼可见粉红。

**教训**：验证颜色不能只用一条解码路径 —— 如果源和产物都由同一个可能出错的解码器读取，两边会「一致地错」。**至少用两条独立路径交叉验证**（本项目用 tifffile 与 vips/libtiff）。

---

## 软件环境

### 工具路径（均已核查存在）

| 工具 | 版本 | 路径 |
|------|------|------|
| bfconvert (Bio-Formats) | 8.1.1 | `~/workspace/software/bftools/bfconvert` |
| showinf (Bio-Formats) | 8.1.1 | `~/workspace/software/bftools/showinf` |
| bioformats_package.jar | 8.1.1 | `~/workspace/software/bftools/bioformats_package.jar` |

`showinf` 用于枚举 series、探测尺寸、读切片元数据（MPP / 倍率），是「换切片检查清单」的主力工具。

### Conda 环境

| 环境 | 路径 | 关键包 | 用途 |
|------|------|--------|------|
| **rnaseq** | `/opt/mambaforge/envs/rnaseq` | tifffile 2025.12.12, imagecodecs, numpy | **RGB JPEG 重编码**（`outcolorspace='RGB'`） |
| **ipy** | `~/.conda/envs/ipy` | openslide-python 1.4.6, libtiff 4.7.1 | `tiffset`/`tiffinfo` 标签修补与验证 |
| **vips** | `~/.conda/envs/vips` | libvips 8.18.4, pyvips 3.1.1 | 金字塔构建 |

> 环境分工是硬性的：`imagecodecs` 只在 **rnaseq** 里，`openslide` 只在 **ipy** 里。`reencode_rgb_jpeg.py` 用 rnaseq 的 python 跑，但它内部 `subprocess` 调用 ipy 的 `tiffset` 和 python 做验证 —— 脚本里用 `--tiffset` / `--openslide-py` 参数显式传递这两个路径，不要指望 `PATH`。

---

## 常用命令

### 一键转换

```bash
# 全自动：series 与尺寸都由 showinf 识别，无需手填
bash vsi_to_svs.sh --input /path/new.vsi --dry-run            # 先预演核对
CLEANUP=no bash vsi_to_svs.sh --input /path/new.vsi           # 正式跑（后台必须带 CLEANUP=no）

bash vsi_to_svs.sh --input a.vsi --series 13                 # 手动指定 series
bash vsi_to_svs.sh --input a.vsi --full-width 120167 --full-height 74250   # 手动指定尺寸
bash vsi_to_svs.sh --input a.vsi --output b.svs              # 自定义输出路径
bash vsi_to_svs.sh --input a.vsi --work-dir /path/to/work    # 改工作目录（中间产物名随之派生）
bash vsi_to_svs.sh --input a.vsi --cleanup-only              # 仅清理中间文件（交互式确认）
bash vsi_to_svs.sh --help
```

脚本行为要点（**2026-09-24 起的新默认值**）：
- **`--series` 默认自动识别**：取 showinf 展平列表中像素数最大的 series 作为主切片。识别结果会打印出来，`--dry-run` 可先核对。
- **`FULL_W/FULL_H` 默认自动探测**：按选定的 series 从 VSI 现读。探测失败会**报错退出**，不会回退到写死的值（旧版会静默沿用 studio 的尺寸 —— 那是个会毁掉分析的坑）。
- `WORK_DIR=${HOME}/svs_work`；中间产物与输出按输入名派生 → `<切片名>_base.tif` / `_pyramid.svs` / `_final.svs`，多张切片互不覆盖。
- `REENCODE_PY` 相对脚本目录解析（`${SCRIPT_DIR}/reencode_rgb_jpeg.py`），不再依赖 `~/svs_format/`。
- `--resume`（默认 `RESUME=yes`）：中间产物存在即跳过，**Phase 1 可复用缓存的 `<切片>_base.tif`**，这是最重要的提速手段。
- `--no-cleanup` 保留中间文件；`CLEANUP=no` 同时跳过结尾的 `read -p` 确认 —— **后台运行必须带**，否则会挂住。
- 环境变量可覆盖全部工具路径与参数：`BFCONVERT SHOWINF VIPS TIFFSET TIFFINFO OPENSLIDE_PY RNASEQ_PY REENCODE_PY WORK_DIR INPUT_VSI OUTPUT_SVS FULL_W FULL_H MPP APMAG SERIES`。

### 单独重跑 Phase 3（调质量 / 重编码时最常用）

```bash
/opt/mambaforge/envs/rnaseq/bin/python3 reencode_rgb_jpeg.py \
    --input  ${HOME}/svs_work/FKBP4_pyramid.svs \
    --output ${HOME}/svs_work/FKBP4_final.svs \
    --quality 80 --full-width 120167 --full-height 74250 --mpp 0.2738 --apmag 20
```

支持 `--quality`（默认 80）、`--full-width/--full-height`、`--mpp`、`--apmag`、`--no-patch`、`--no-verify`。

⚠️ **该脚本的 argparse 默认值仍硬编码为 studio**（`--full-width 121652 --full-height 74284`）。**裸调它而不传尺寸，会把 studio 的尺寸写进 Aperio ImageDescription，导致分析失败。** 通过 `vsi_to_svs.sh` 调用时才会自动探测并传对（它把从当前 VSI 探测到的值透传下来）。

### 验证

```bash
SVS=${HOME}/svs_work/FKBP4_final.svs

~/.conda/envs/ipy/bin/tiffinfo "$SVS" | grep -E \
  'TIFF directory|Compression|Photometric|Subfile Type|ImageDescription|Software'
# 期望: 全部 10 级 IFD 都是 Compression=JPEG(7) + Photometric=RGB color + Subfile Type=0

~/.conda/envs/ipy/bin/python3 -c "
import openslide, numpy as np
osr = openslide.OpenSlide('$SVS')
print('vendor', osr.properties.get('openslide.vendor'), '| levels', osr.level_count)
for i in range(osr.level_count):
    print('  level', i, osr.level_dimensions[i])
arr = np.array(osr.read_region((0,0), osr.level_count-1, (256,256)))
print('缩略图 RGB: R=%.0f G=%.0f B=%.0f' % tuple(arr[:,:,:3].reshape(-1,3).mean(axis=0)))"
```

**判读**：三通道均值应接近（studio 是 `R=241 G=241 B=240`）。**R 明显偏高 = 偏红 = 又踩了方案 4 的坑**；`Photometric` 里出现 `YCbCr` = 分析会失败。两者都是硬失败信号。

### 原始转换命令（脚本内部实际执行）

```bash
SLIDE=FKBP4                              # 换成你的切片名
VSI=/mnt/data3/$SLIDE.vsi
WORK=${HOME}/svs_work

# Phase 1 —— --series 用 showinf 枚举后的「展平」编号
~/workspace/software/bftools/bfconvert -bigtiff -tilex 256 -tiley 256 \
  -compression JPEG -quality 0.8 -series 13 -no-sas -overwrite \
  "$VSI" "$WORK/${SLIDE}_base.tif"

# Phase 2
~/.conda/envs/vips/bin/vips tiffsave "$WORK/${SLIDE}_base.tif" "$WORK/${SLIDE}_pyramid.svs" \
  --tile --tile-width=256 --tile-height=256 --pyramid \
  --compression=jpeg --Q=80 --bigtiff
```

---

## ImageScope SVS 兼容性要点（完整清单）

1. **压缩格式**: 仅 JPEG (7) 或 JPEG2000/Kakadu (33005)
2. **PhotometricInterpretation**: 必须 RGB(2)
3. **JPEG 码流一致性**: Photometric=RGB 时，JPEG 必须用 RGB 色彩空间编码
4. **SubfileType**: 所有 IFD 设为 0
5. **ImageDescription**: 以 `Aperio Image Library` 开头，含完整尺寸与压缩参数
6. **Pyramid**: 多级 IFD，tile 256×256（studio 为 10 级 121652×74284 → 237×145；FKBP4 为 120167×74250 → 470×291）

---

## 输入数据约定（VSI 结构）

**已知两个样本的对照**（说明「哪些是通用规律、哪些是每张各异」）：

| 项 | studio | FKBP4（已完成） |
|---|---|---|
| 扫描仪 | CellSens / Olympus | **OLYMPUS VS200 ASW v4.1.1** |
| `.vsi` 大小 | 2.3 MB（外壳） | 2.4 MB（外壳） |
| 配套文件夹 | `_studio_/` | `_FKBP4_/` |
| 像素总量 | ~1.6 GB | 1.9 GB |
| 主切片尺寸 | 121652 × 74284 | **120167 × 74250** |
| MPP / AppMag | 0.2738 / 20 | 0.2738113 / 20 |
| 主切片 series（展平） | 13 | **13** |
| 源 tile | 256 | **512** |
| 组织类型 | — | TMA 芯片，~10×17 芯，IHC/DAB |

**通用规律**：

- **`.vsi` 只是外壳**，内嵌 label / macro / 缩略图（几百 KB～2 MB）；真正的全片金字塔全在配套文件夹。**只拿 `.vsi` 转不了** —— showinf 会报 `Missing expected .ets files in <路径>/_<切片名>_`，且只能列出 label/macro 那几个小 series（几百像素级），看到 `Series count` 很小、尺寸全是几百就是这种情况。
- **配套文件夹必须与 `.vsi` 同名**：`_<切片名>_` 或 `_<切片名>`。studio 原始名为 `_??_rpl8_`（含非法字符），曾需重命名。`check_input` 两种形式都接受。
- 目录结构：`stack1/frame_t.ets`(概览 ~31 MB)、`stack10000/`(中间层 ~32–35 MB)、`stack10002/frame_t.ets`(主切片 1.5–2 GB)。
- **源 tile 尺寸不影响输出**：bfconvert 按 `-tilex/-tiley 256` 重切。FKBP4 源是 512，输出仍是 256。
- 输出 tile 固定 **256×256** —— 已验证可用的配置，也是 Aperio 惯例，**不要改**。

**每张各异的**：`--series` 编号、`FULL_W/FULL_H`、`MPP/AppMag`。studio 与 FKBP4 恰好都是 series 13，那是 VS200 ASW 的排布规律（label 金字塔 + overview 金字塔在前，主切片紧随其后），**不是可以照抄的常数**。前两者脚本已自动识别（`--dry-run` 核对），`MPP/AppMag` 若换了扫描仪或物镜需手动指定 —— 按「换切片检查清单」走一遍。

---

## 已知陷阱

- **别用 `tiffset` 改 Photometric 来修颜色** —— 方案 4 的死路，只会得到偏红。颜色问题只能在 Phase 3 用 `outcolorspace='RGB'` 解决。
- **别用 Deflate/LZW 绕开 JPEG** —— 压缩格式被 V9 拒绝，且体积膨胀到 5–15 GB。
- **别裸调 `reencode_rgb_jpeg.py`** —— 它的 argparse 默认尺寸是 studio 的，会把错误尺寸写进 Aperio 元数据。要么走 `vsi_to_svs.sh`，要么显式传 `--full-width/--full-height`。
- **别照抄上一张切片的 `--series`** —— 见「换切片检查清单」。
- **磁盘**：`/mnt/data4` 现有 32 TB 可用。FKBP4 实测 `_base.tif` 985 MB + `_pyramid.svs` 1.20 GB + `_final.svs` 2.98 GB ≈ **5.2 GB**（比 studio 的 3.8 GB 大 —— 体积取决于组织密度与染色，**别按 studio 的数字预留空间**）。输入所在盘（如 `/mnt/data3`，仅 29 GB）不要拿来当 `WORK_DIR`。
- **`du` 与 `ls` 报的大小对不上是正常的**：FKBP4 的 `_final.svs` 表观 2.98 GB，`du` 却报 6.8G（实际分配 7.27 GB，2.44×）。这是 XFS 的 speculative preallocation，**不是数据损坏** —— `ls` / `os.path.getsize` 的表观大小才是真实文件长度。介意浪费空间就 `cp` 一份重写（副本的分配会正常化）。
- **非交互执行**：脚本结尾的清理确认用 `read -p`，在后台会挂住；用 `CLEANUP=no` 规避。
- **`--dry-run` 仍会跑 `check_tools`、`check_input`、series 识别和尺寸探测**，所以输入缺失时 dry-run 也会失败 —— 这是有意的，能提前暴露问题。
