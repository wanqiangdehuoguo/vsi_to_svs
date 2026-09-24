#!/usr/bin/env python3
"""
reencode_rgb_jpeg.py — JPEG YCbCr → RGB JPEG SVS 重编码

从 vips 输出的 YCbCr JPEG SVS (正确金字塔结构) 重建为真正的 RGB JPEG SVS。
imagecodecs outcolorspace='RGB' 保证 JPEG 码流与 Photometric 标签一致,
使 ImageScope Positive Pixel Count V9 能正常工作且显示正确。

用法:
  /opt/mambaforge/envs/rnaseq/bin/python3 reencode_rgb_jpeg.py \
      --input  studio_pyramid.svs \
      --output studio_final.svs \
      --quality 80

依赖: tifffile, imagecodecs, numpy (rnaseq conda env)
"""

import argparse
import gc
import os
import subprocess
import sys
import numpy as np
import tifffile
import imagecodecs
from tifffile import RESUNIT


def build_description(ifd_idx, width, height, full_w, full_h, tile_w, tile_h,
                      jpeg_q, mpp, apmag):
    """生成 Aperio ImageDescription, 参考 BRIX1 格式."""
    if ifd_idx == 0:
        return (f"Aperio Image Library v12.0.15\n"
                f"{full_w}x{full_h} [0,0 {full_w}x{full_h}] "
                f"({tile_w}x{tile_h}) JPEG/RGB Q={jpeg_q}"
                f"|AppMag = {apmag}|MPP = {mpp}")
    else:
        return (f"Aperio Image Library v12.0.15\n"
                f"{full_w}x{full_h} [0,0 {full_w}x{full_h}] "
                f"({tile_w}x{tile_h}) -> {width}x{height} JPEG/RGB Q={jpeg_q}"
                f"|AppMag = {apmag}|MPP = {mpp}")


def patch_tags(output_path, num_ifds, pages, full_w, full_h, tile_w, tile_h,
               jpeg_q, mpp, apmag, tiffset_bin):
    """tiffset 后处理: 清除 YCbCrSubSampling, 设置 SubfileType=0, Aperio 标签."""
    print("  [后处理] 清除 YCbCrSubSampling (tag 530)...")
    for i in range(num_ifds):
        subprocess.run([tiffset_bin, '-d', str(i), '-s', '530', '',
                        output_path], capture_output=True, text=True)

    print("  [后处理] 设置 SubfileType=0...")
    for i in range(num_ifds):
        subprocess.run([tiffset_bin, '-d', str(i), '-s', '254', '0',
                        output_path], capture_output=True, text=True)

    print("  [后处理] 修补 ImageDescription + Software...")
    for i in range(num_ifds):
        w = pages[i].imagewidth
        h = pages[i].imagelength
        desc = build_description(i, w, h, full_w, full_h, tile_w, tile_h,
                                 jpeg_q, mpp, apmag)
        subprocess.run([tiffset_bin, '-d', str(i), '-s', '270', desc,
                        output_path], capture_output=True, text=True)
        subprocess.run([tiffset_bin, '-d', str(i), '-s', '305',
                        'Aperio Image Library v12.0.15', output_path],
                       capture_output=True, text=True)
    print("  [后处理] 完成")


def verify(output_path, openslide_py):
    """快速 openslide 验证."""
    print("\n  [验证] openslide...")
    code = f"""
import openslide, numpy as np
osr = openslide.OpenSlide('{output_path}')
print(f"    vendor      : {{osr.properties.get('openslide.vendor')}}")
print(f"    level_count : {{osr.level_count}}")
ok = True
for i in range(min(osr.level_count, 3)):
    d = osr.level_dimensions[i]
    print(f"    level {{i}}     : {{d[0]}}x{{d[1]}}")
img = osr.read_region((0,0), osr.level_count-1, (256,256))
arr = np.array(img)
r, g, b = arr[:,:,0].mean(), arr[:,:,1].mean(), arr[:,:,2].mean()
print(f"    thumb RGB   : R={{r:.0f}} G={{g:.0f}} B={{b:.0f}}")
w0, h0 = osr.level_dimensions[0]
img0 = osr.read_region((w0//2, h0//2), 0, (256,256))
arr0 = np.array(img0)
r0, g0, b0 = arr0[:,:,0].mean(), arr0[:,:,1].mean(), arr0[:,:,2].mean()
print(f"    level0 RGB  : R={{r0:.0f}} G={{g0:.0f}} B={{b0:.0f}}")
"""
    result = subprocess.run([openslide_py, '-c', code],
                            capture_output=True, text=True)
    print(result.stdout)
    if result.returncode != 0:
        print(f"    ERROR: {result.stderr}")
        return False
    return True


def main():
    parser = argparse.ArgumentParser(
        description='YCbCr JPEG SVS → RGB JPEG SVS 重编码')
    parser.add_argument('--input', required=True, help='输入 SVS 文件 (vips YCbCr JPEG)')
    parser.add_argument('--output', required=True, help='输出 SVS 文件 (RGB JPEG)')
    parser.add_argument('--quality', type=int, default=80,
                        help='JPEG 质量 (1-100, 默认 80)')
    parser.add_argument('--full-width', type=int, default=121652,
                        help='全分辨率宽度 (默认 121652)')
    parser.add_argument('--full-height', type=int, default=74284,
                        help='全分辨率高度 (默认 74284)')
    parser.add_argument('--mpp', type=float, default=0.2738,
                        help='Microns per pixel (默认 0.2738)')
    parser.add_argument('--apmag', type=int, default=20,
                        help='Apparent magnification (默认 20)')
    parser.add_argument('--tiffset', default='/home/user/.conda/envs/ipy/bin/tiffset',
                        help='tiffset 路径')
    parser.add_argument('--openslide-py',
                        default='/home/user/.conda/envs/ipy/bin/python3',
                        help='含 openslide 的 Python 路径')
    parser.add_argument('--no-verify', action='store_true',
                        help='跳过 openslide 验证')
    parser.add_argument('--no-patch', action='store_true',
                        help='跳过 tiffset 后处理')
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"错误: 输入文件不存在: {args.input}")
        sys.exit(1)

    # ── 读取源结构 ──
    print(f"[Phase 1] 读取源文件: {args.input}")
    src = tifffile.TiffFile(args.input)
    pages = list(src.pages)
    num_ifds = len(pages)
    print(f"  IFD 数量: {num_ifds}")
    tile_w = pages[0].tilewidth
    tile_h = pages[0].tilelength
    xres = yres = None
    for tag in pages[0].tags.values():
        if tag.name == 'XResolution':
            xres = tag.value[0] / tag.value[1] if hasattr(tag.value, '__len__') else tag.value
        if tag.name == 'YResolution':
            yres = tag.value[0] / tag.value[1] if hasattr(tag.value, '__len__') else tag.value
    if xres is None:
        xres = 36521.6
    if yres is None:
        yres = 36521.3

    for i, p in enumerate(pages):
        print(f"  IFD {i}: {p.imagewidth}x{p.imagelength}")

    # ── 重编码写入 ──
    print(f"\n[Phase 2] 重编码为 RGB JPEG (Q={args.quality}) → {args.output}")
    with tifffile.TiffWriter(args.output, bigtiff=True) as dst:
        for i, page in enumerate(pages):
            w, h = page.imagewidth, page.imagelength
            across = (w + tile_w - 1) // tile_w
            down = (h + tile_h - 1) // tile_h
            print(f"  IFD {i}: {w}x{h} ({across}x{down} tiles)...",
                  end=' ', flush=True)

            img = page.asarray()
            if img.ndim == 2:
                img = np.stack([img, img, img], axis=-1)
            elif img.shape[-1] == 4:
                img = img[:, :, :3]

            desc = build_description(i, w, h, args.full_width, args.full_height,
                                     tile_w, tile_h, args.quality, args.mpp,
                                     args.apmag)

            dst.write(
                img,
                tile=(tile_w, tile_h),
                compression='jpeg',
                compressionargs={
                    'level': args.quality,
                    'outcolorspace': 'RGB',
                    'subsampling': '444',
                    'optimize': True,
                },
                subfiletype=0,
                description=desc,
                software='Aperio Image Library v12.0.15',
                resolution=(xres, yres),
                resolutionunit=RESUNIT.CENTIMETER,
            )
            print("done")
            del img
            gc.collect()

    src.close()
    out_size = os.path.getsize(args.output)
    print(f"  输出: {out_size / 1e9:.2f} GB")

    # ── 后处理 ──
    if not args.no_patch:
        print(f"\n[Phase 3] tiffset 后处理")
        patch_tags(args.output, num_ifds, pages,
                   args.full_width, args.full_height,
                   tile_w, tile_h, args.quality, args.mpp, args.apmag,
                   args.tiffset)

    # ── 验证 ──
    if not args.no_verify:
        verify(args.output, args.openslide_py)

    print(f"\n完成: {args.output}")


if __name__ == '__main__':
    main()
