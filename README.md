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

## 安装

### 0. 系统要求

- **Linux**（其他平台未测试）
- **Java 11+** —— Bio-Formats 是 Java 程序
- **conda / mamba**
- **磁盘** —— 单张切片中间产物 + 输出约 5 GB（8.9 Gpixel 的切片）
- **内存** —— Phase 3 逐 IFD 载入，峰值约 1–2 GB

### 1. Bio-Formats（读 VSI 的唯一途径）

到官方下载页取 `bftools.zip`：**<https://www.openmicroscopy.org/bio-formats/downloads/>**
（本项目用的是 **8.1.1**；直链形如
`https://downloads.openmicroscopy.org/bio-formats/<版本>/artifacts/bftools.zip`）

```bash
mkdir -p ~/workspace/software && cd ~/workspace/software
unzip bftools.zip            # 解压出 bftools/ 目录
java -version                # 确认 Java 可用，否则 bfconvert 起不来
```

`bfconvert` 用来转换，`showinf` 用来枚举 series 与探测尺寸 —— 两个都要。

### 2. 三个 conda 环境

分工是**硬性的**，不能随便合并：

| 环境（本项目的默认名） | 关键包 | 干什么 |
|---|---|---|
| `svs-reencode` | `tifffile` `imagecodecs` `numpy` | Phase 3 重编码 —— **`outcolorspace='RGB'` 只在 imagecodecs 里有** |
| `svs-tiff` | `libtiff` `openslide-python` | `tiffset`/`tiffinfo` 补标签 + openslide 验收 |
| `svs-vips` | `libvips` `pyvips` | Phase 2 建金字塔 |

```bash
conda create -n svs-reencode -c conda-forge python=3.12 tifffile imagecodecs numpy -y
conda create -n svs-tiff     -c conda-forge python=3.12 libtiff openslide-python -y
conda create -n svs-vips     -c conda-forge python=3.12 libvips pyvips -y
```

> 本项目开发时锁定的版本：tifffile 2025.12.12 / imagecodecs 2025.3.30 / numpy 1.26.4 /
> libtiff 4.7.1 / openslide-python 1.4.6 / libvips 8.18.4 / pyvips 3.1.1 / Bio-Formats 8.1.1。
> 更新的版本一般也能用。
>
> **已经有一套装了这些包的环境？直接复用**，不必新建 —— 用第 4 步的 `export` 指过去即可。
> 环境名随便取，脚本靠**显式传路径**调用它们，不依赖 `PATH`，也不依赖环境名。

### 3. 获取本项目

```bash
git clone https://github.com/wanqiangdehuoguo/vsi_to_svs.git
cd vsi_to_svs
```

### 4. 告诉脚本工具在哪

脚本内置的默认路径是**作者本机的布局**（`~/workspace/software/bftools/`、
`~/.conda/envs/{ipy,vips}/`、`/opt/mambaforge/envs/rnaseq/`）—— 照第 2 步新建环境的话多半对不上。

把下面这段加进 `~/.bashrc`（或每次调用前 `export`），**按你的实际位置改**：

```bash
export BFCONVERT=~/workspace/software/bftools/bfconvert
export SHOWINF=~/workspace/software/bftools/showinf
export VIPS=~/.conda/envs/svs-vips/bin/vips
export TIFFSET=~/.conda/envs/svs-tiff/bin/tiffset
export TIFFINFO=~/.conda/envs/svs-tiff/bin/tiffinfo
export OPENSLIDE_PY=~/.conda/envs/svs-tiff/bin/python3
export RNASEQ_PY=~/.conda/envs/svs-reencode/bin/python3
```

> `conda create` 把环境建在你的 conda 安装目录下 —— 上面按 `~/.conda/envs/` 写，
> 若你的 conda 在 `/opt/mambaforge` 之类的位置，改成 `/opt/mambaforge/envs/svs-vips/bin/vips` 这样。

完整的环境变量列表见 `bash vsi_to_svs.sh --help`。

### 5. 自检安装

用一个**不存在**的输入跑 dry-run：

```bash
bash vsi_to_svs.sh --input /nonexistent.vsi --dry-run
```

脚本先检查工具、后检查输入，所以：

- 报 **`✗ 工具不存在: ...`** → 那个工具的路径没配对，回去看第 4 步
- 报 **`✗ VSI 文件不存在`** → ✅ **安装成功**，8 个工具全部就位，只是输入是假的

---

## 使用

### 准备输入数据（最容易出错的一步）

CellSens / VS200 ASW 的输出是**两部分**，必须放在同一目录下：

```
/path/to/
├── slide.vsi                      # 外壳，约 2 MB
└── _slide_/                       # 配套文件夹 —— 真正的全片像素在这里
    ├── stack1/frame_t.ets                 # 概览      ~31 MB
    ├── stack10000/frame_t.ets             # 中间层    ~32 MB
    └── stack10002/frame_t.ets             # 主切片    1.5–2 GB
```

- **`.vsi` 只是外壳**，内嵌 label / macro / 缩略图。**只给它转不了** ——
  会报 `Missing expected .ets files`，且只能读到几百像素级的小图。
- **配套文件夹必须与 `.vsi` 同名**：`_<切片名>_` 或 `_<切片名>`。
  名字不符就**改文件夹名**（不要改 `.vsi`）。
- 配套文件夹通常要从扫描仪电脑**整个目录**拷出来，别只拷 `.vsi`。

### 步骤 1：预演（务必先做）

```bash
bash vsi_to_svs.sh --input /path/to/slide.vsi --dry-run
```

脚本会依次：检查工具 → 检查输入与配套文件夹 → 用 `showinf` **自动识别主切片 series**
（展平后像素数最大的那个）→ 按该 series 读出尺寸 → 打印将要执行的命令，**不实际执行**。

**核对打印出的 series 编号与宽高是否合理** —— 主切片应该是整张图里最大的那个。
不对就用 `--series N` 覆盖（见「常用参数」）。

> 想手工核对，可以列一遍所有 series：
> ```bash
> ~/workspace/software/bftools/showinf -nopix /path/to/slide.vsi \
>   | grep -E 'Series count|^Series #|Width =|Height ='
> ```
> 注意 bfconvert 用的是**展平后**的编号（`showinf` 默认不带 `-noflat` 的那份列表）。

### 步骤 2：正式转换

```bash
CLEANUP=no bash vsi_to_svs.sh --input /path/to/slide.vsi
```

耗时参考（8.9 Gpixel，写入 xfs 大盘）：**Phase 1 约 25 分钟，Phase 2 约 1 分钟，Phase 3 约 1 分钟**。

- **后台运行必须带 `CLEANUP=no`** —— 否则脚本结尾的清理确认用 `read -p`，在后台会挂住。
- **看进度**：`tail -f $WORK_DIR/convert.log`。Phase 1 是单层 series，**没有进度行**，
  中途只能盯输出文件大小（TIFF 顺序写入，大小 ≈ 已写 tile 数）；Phase 2/3 有正常进度输出。
- **输出**：`$WORK_DIR/<切片名>_final.svs`（默认 `$WORK_DIR=${HOME}/svs_work`）。

### 步骤 3：验收（三项全过才算成功）

```bash
SVS=$WORK_DIR/slide_final.svs

# ① 10 级 IFD 的标签
~/.conda/envs/svs-tiff/bin/tiffinfo "$SVS" | grep -E \
  'TIFF directory|Compression|Photometric|Subfile Type'
# 期望: 全部 Compression=JPEG(7) + Photometric=RGB color + Subfile Type=0

# ② openslide 元数据
~/.conda/envs/svs-tiff/bin/python3 -c "
import openslide
o = openslide.OpenSlide('$SVS')
print(o.properties.get('openslide.vendor'), o.level_count, o.properties.get('openslide.mpp-x'))"
# 期望: aperio  10  0.2738

# ③ 颜色（判红）—— 在组织区取一块比三通道均值
```

**判红方法**：

- 正常 IHC（DAB 棕色）：`R−G ≈ 10` 左右 —— 棕色本就 R>G>B，**这是正常的，别误判**
- 方案 4 那种病态偏红：R 明显更高，且肉眼可见粉红

⚠️ **验证颜色必须用两条以上独立解码路径**（例如 tifffile 与 vips/libtiff 各读一次同一坐标）。
如果源和产物都由同一个可能出错的解码器读取，两边会「一致地错」，你会得到一个虚假的通过。

### 步骤 4：清理中间产物

```bash
bash vsi_to_svs.sh --input /path/to/slide.vsi --cleanup-only
```

中间产物（`<切片名>_base.tif` + `<切片名>_pyramid.svs`，约 2 GB）用 `--no-cleanup` 保留的好处：
**调 JPEG 质量重跑 Phase 3 只要 1 分钟，而不是重跑 25 分钟的 Phase 1**。

### 常用参数

| 参数 | 用途 |
|---|---|
| `--series N` | 手动指定主切片 series（自动识别不对时） |
| `--full-width N` / `--full-height N` | 手动指定尺寸（探测失败时） |
| `--quality N` | JPEG 质量，默认 80 |
| `--mpp F` / `--apmag N` | 微米/像素与表观放大倍率，默认 0.2738 / 20（换扫描仪或物镜要改） |
| `--work-dir PATH` | 改工作目录（中间产物与输出都跟着走） |
| `--output PATH` | 自定义输出路径 |
| `--resume` / `--no-resume` | 是否复用已存在的中间产物，**默认复用** |
| `--dry-run` | 只打印命令，不执行 |
| `--cleanup-only` | 只清理中间文件 |

**换切片时只有 `--input` 是必填的** —— series 与尺寸都会自动识别。其余参数一般不用动。

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

---

## 目录

```
├── README.md                       # 本文件
├── CLAUDE.md                       # 详细知识库（架构 / 迭代史 / 兼容性清单 / 已知陷阱）
├── vsi_to_svs.sh                   # 主入口：四阶段工作流
├── reencode_rgb_jpeg.py            # Phase 3：RGB JPEG 重编码（可独立调用）
├── LICENSE                         # MIT
└── docs/
    ├── job1.txt / job2.txt / job3.txt    # 最初三次问题记录（项目起点）
    ├── positive-pixel-count-issue.md     # 排查阶段的方案分析（结论已被最终方案取代）
    └── example-run.md                    # 一次成功运行的完整日志
```

**建议再读一下 `CLAUDE.md`** —— 它记录了完整的迭代历史（方案 1–5 各自为什么失败）、
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

[MIT](LICENSE)
