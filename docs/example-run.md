# 一次成功运行的完整日志

样本：**FKBP4**（Olympus VS200 ASW 输出的 TMA 组织芯片，主切片 120167×74250，IHC/DAB 染色）
全程 **27 分钟**（15:58:06 → 16:25:20），产出 2.98 GB 的 `FKBP4_final.svs`。

值得注意的几处：

- **Phase 1 没有进度输出**，只在结尾打一次 `Converted 1/1 planes (100%)` —— 因为 `-series 13` 是展平后的单层 series。中途想看进度只能盯输出文件大小。
- **`--no-cleanup` 保留了中间产物**，所以 Phase 3 若需调质量重跑，只要 1 分钟而不是 25 分钟。
- **Phase 3 内部报 `输出: 2.97 GB`，脚本末尾却报 `6.8G`** —— 这不是矛盾：前者是 `os.path.getsize` 的表观大小，后者是 `du` 的块占用（XFS speculative preallocation，实际分配 7.27 GB）。真实文件长度以表观大小为准。
- **验证阶段的三通道均值**（`R=239 G=239 B=237`）与源逐位一致，证明 RGB 重编码没有引入色彩偏移。

```text

╔══════════════════════════════════════════╗
║  VSI → SVS 转换工作流                    ║
╚══════════════════════════════════════════╝

  输入:  /mnt/data3/FKBP4.vsi
  输出:  /mnt/data4/sym/svs_work/FKBP4_final.svs
  中间:  /mnt/data4/sym/svs_work/FKBP4_base.tif
         /mnt/data4/sym/svs_work/FKBP4_pyramid.svs
  质量:  80
  Series: 13
  恢复:  yes | 清理: no

[15:58:06] 检查工具...
[15:58:06] ✓ 所有工具就绪
[15:58:07] 检查输入...
[15:58:07] ✓ 输入验证通过: /mnt/data3/FKBP4.vsi (2.4M)
[15:58:07] 探测 series 13 尺寸 (showinf)...
[15:58:10] ✓ series 13: 120167x74250
  若尺寸不对, 用 --full-width/--full-height 覆盖
[15:58:10] Phase 1/4: bfconvert VSI → BigTIFF
  预计耗时: ~2.5 小时
  命令: /home/sym/workspace/software/bftools/bfconvert -bigtiff -tilex 256 -tiley 256 -compression JPEG -quality 0.8 -series 13 -no-sas -overwrite "/mnt/data3/FKBP4.vsi" "/mnt/data4/sym/svs_work/FKBP4_base.tif"
/mnt/data3/FKBP4.vsi
CellSensReader initializing /mnt/data3/FKBP4.vsi
[CellSens VSI] -> /mnt/data4/sym/svs_work/FKBP4_base.tif [Tagged Image File Format]
Tile size = 256 x 256
	Converted 1/1 planes (100%)
[done]
1530.91s elapsed (80.0+1530257.0ms per plane, 569ms overhead)
[16:23:42] ✓ bfconvert 完成: 940M
[16:23:42] Phase 2/4: vips 构建 JPEG 金字塔
  预计耗时: ~2 分钟
  命令: /home/sym/.conda/envs/vips/bin/vips tiffsave "/mnt/data4/sym/svs_work/FKBP4_base.tif" "/mnt/data4/sym/svs_work/FKBP4_pyramid.svs" --tile --tile-width=256 --tile-height=256 --pyramid --compression=jpeg --Q=80 --bigtiff
[16:24:24] ✓ vips 金字塔完成: 1.2G
[16:24:24] Phase 3/4: RGB JPEG 重编码
  预计耗时: ~10-15 分钟
  命令: /opt/mambaforge/envs/rnaseq/bin/python3 "/home/sym/workspace/svs_format/reencode_rgb_jpeg.py" --input "/mnt/data4/sym/svs_work/FKBP4_pyramid.svs" --output "/mnt/data4/sym/svs_work/FKBP4_final.svs" --quality 80 --full-width 120167 --full-height 74250 --mpp 0.2738 --apmag 20 --tiffset "/home/sym/.conda/envs/ipy/bin/tiffset" --openslide-py "/home/sym/.conda/envs/ipy/bin/python3"
[Phase 1] 读取源文件: /mnt/data4/sym/svs_work/FKBP4_pyramid.svs
  IFD 数量: 10
  IFD 0: 120167x74250
  IFD 1: 60083x37125
  IFD 2: 30041x18562
  IFD 3: 15020x9281
  IFD 4: 7510x4640
  IFD 5: 3755x2320
  IFD 6: 1877x1160
  IFD 7: 938x580
  IFD 8: 469x290
  IFD 9: 234x145

[Phase 2] 重编码为 RGB JPEG (Q=80) → /mnt/data4/sym/svs_work/FKBP4_final.svs
  IFD 0: 120167x74250 (470x291 tiles)... done
  IFD 1: 60083x37125 (235x146 tiles)... done
  IFD 2: 30041x18562 (118x73 tiles)... done
  IFD 3: 15020x9281 (59x37 tiles)... done
  IFD 4: 7510x4640 (30x19 tiles)... done
  IFD 5: 3755x2320 (15x10 tiles)... done
  IFD 6: 1877x1160 (8x5 tiles)... done
  IFD 7: 938x580 (4x3 tiles)... done
  IFD 8: 469x290 (2x2 tiles)... done
  IFD 9: 234x145 (1x1 tiles)... done
  输出: 2.97 GB

[Phase 3] tiffset 后处理
  [后处理] 清除 YCbCrSubSampling (tag 530)...
  [后处理] 设置 SubfileType=0...
  [后处理] 修补 ImageDescription + Software...
  [后处理] 完成

  [验证] openslide...
    vendor      : aperio
    level_count : 10
    level 0     : 120167x74250
    level 1     : 60083x37125
    level 2     : 30041x18562
    thumb RGB   : R=121 G=119 B=117
    level0 RGB  : R=239 G=239 B=237


完成: /mnt/data4/sym/svs_work/FKBP4_final.svs
[16:25:20] ✓ RGB JPEG 重编码完成: 6.8G
[16:25:20] Phase 4/4: 验证

═══════════════════════════════════════════
  tiffinfo 关键标签
═══════════════════════════════════════════
=== TIFF directory 0 ===
  Subfile Type: (0 = 0x0)
  Compression Scheme: JPEG
  Photometric Interpretation: RGB color
  ImageDescription: Aperio Image Library v12.0.15
  Software: Aperio Image Library v12.0.15
=== TIFF directory 1 ===
  Subfile Type: (0 = 0x0)
  Compression Scheme: JPEG
  Photometric Interpretation: RGB color
  ImageDescription: Aperio Image Library v12.0.15
  Software: Aperio Image Library v12.0.15
=== TIFF directory 2 ===
  Subfile Type: (0 = 0x0)
  Compression Scheme: JPEG
  Photometric Interpretation: RGB color
  ImageDescription: Aperio Image Library v12.0.15
  Software: Aperio Image Library v12.0.15
=== TIFF directory 3 ===
  Subfile Type: (0 = 0x0)
  Compression Scheme: JPEG
  Photometric Interpretation: RGB color
  ImageDescription: Aperio Image Library v12.0.15
  Software: Aperio Image Library v12.0.15
=== TIFF directory 4 ===
  Subfile Type: (0 = 0x0)
  Compression Scheme: JPEG
  Photometric Interpretation: RGB color
  ImageDescription: Aperio Image Library v12.0.15
  Software: Aperio Image Library v12.0.15

═══════════════════════════════════════════
  openslide 验证
═══════════════════════════════════════════
vendor     : aperio
level_count: 10
  level 0: (120167, 74250)
  level 1: (60083, 37125)
  level 2: (30041, 18562)
mpp-x      : 0.27379999999999999
mpp-y      : 0.27379999999999999
thumb RGB  : R=121 G=119 B=117
level0 RGB : R=239 G=239 B=237

═══════════════════════════════════════════
  最终输出: /mnt/data4/sym/svs_work/FKBP4_final.svs (6.8G)
═══════════════════════════════════════════

═══════════════════════════════════════════
  转换成功完成!
  输出: /mnt/data4/sym/svs_work/FKBP4_final.svs
═══════════════════════════════════════════
```
