#!/bin/bash
# ============================================================================
# vsi_to_svs.sh — CellSens VSI → Aperio SVS 完整转换工作流
#
# 用法:
#   bash vsi_to_svs.sh                                    # 使用默认参数
#   bash vsi_to_svs.sh --input my_slide.vsi --output my_slide.svs
#   bash vsi_to_svs.sh --cleanup                           # 仅清理中间文件
#   bash vsi_to_svs.sh --resume                            # 跳过已完成的步骤
#
# 工作流:
#   Phase 1: bfconvert VSI → BigTIFF  (~2.5h)
#   Phase 2: vips 构建 JPEG 金字塔   (~2 min)
#   Phase 3: RGB JPEG 重编码         (~10-15 min)
#   Phase 4: 验证 + 清理
# ============================================================================

set -e

# ── 默认配置 ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/mnt/data4/user/svs_work}"
INPUT_VSI="${INPUT_VSI:-}"
OUTPUT_SVS="${OUTPUT_SVS:-}"
JPEG_QUALITY="${JPEG_QUALITY:-80}"
SERIES="${SERIES:-}"
BF_SERIES="${BF_SERIES:-${SERIES}}"
RESUME="${RESUME:-yes}"
CLEANUP="${CLEANUP:-yes}"
DRY_RUN="${DRY_RUN:-no}"

# 中间文件 / 输出: 由 derive_paths() 按输入文件名派生 (多张切片互不覆盖)
SLIDE_NAME=""
BASE_TIFF=""
PYRAMID_SVS=""

# 图像参数: FULL_W/FULL_H 留空则从 VSI 自动探测 (见 detect_dims)
# 注意: 这两个值会写进 Aperio ImageDescription 的裁剪区域字段,
#       用错(例如沿用上一张切片的硬编码值)会导致 ImageScope 分析失败
FULL_W="${FULL_W:-}"
FULL_H="${FULL_H:-}"
MPP="${MPP:-0.2738}"
APMAG="${APMAG:-20}"
TILE_W=256
TILE_H=256

# ── 工具路径 ──────────────────────────────────────
BFCONVERT="${BFCONVERT:-${HOME}/workspace/software/bftools/bfconvert}"
SHOWINF="${SHOWINF:-${HOME}/workspace/software/bftools/showinf}"
VIPS="${VIPS:-${HOME}/.conda/envs/vips/bin/vips}"
TIFFSET="${TIFFSET:-${HOME}/.conda/envs/ipy/bin/tiffset}"
TIFFINFO="${TIFFINFO:-${HOME}/.conda/envs/ipy/bin/tiffinfo}"
OPENSLIDE_PY="${OPENSLIDE_PY:-${HOME}/.conda/envs/ipy/bin/python3}"
RNASEQ_PY="${RNASEQ_PY:-/opt/mambaforge/envs/rnaseq/bin/python3}"
REENCODE_PY="${REENCODE_PY:-${SCRIPT_DIR}/reencode_rgb_jpeg.py}"

# ── 颜色输出 ──────────────────────────────────────
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
bold()   { echo -e "\033[1m$*\033[0m"; }


usage() {
    cat <<EOF
$(bold "vsi_to_svs.sh") — CellSens VSI → Aperio SVS 转换工作流

$(bold "用法:")
  bash vsi_to_svs.sh [选项]

$(bold "选项:")
  --input PATH        输入 VSI 文件          (必填)
  --output PATH       输出 SVS 文件          (默认: <工作目录>/<切片名>_final.svs)
  --quality N         JPEG 质量 1-100        (默认: ${JPEG_QUALITY})
  --series N          主切片 series 编号      (默认: 自动识别像素数最大的 series)
  --full-width N      全分辨率宽度           (默认: 从 VSI 自动探测)
  --full-height N     全分辨率高度           (默认: 从 VSI 自动探测)
  --mpp F             微米/像素 (MPP)        (默认: ${MPP})
  --apmag N           表观放大倍率 (AppMag)   (默认: ${APMAG})
  --work-dir PATH     工作目录               (默认: ${WORK_DIR})
  --resume            跳过已存在的中间产物
  --no-resume         强制从头运行
  --no-cleanup        保留中间文件
  --cleanup-only      仅清理中间文件, 不运行转换
  --dry-run           打印将要执行的命令, 不实际执行
  --help              显示此帮助

$(bold "环境变量:")
  BFCONVERT, SHOWINF, VIPS, TIFFSET, TIFFINFO, OPENSLIDE_PY, RNASEQ_PY, REENCODE_PY
  WORK_DIR, INPUT_VSI, OUTPUT_SVS, FULL_W, FULL_H, MPP, APMAG, SERIES

$(bold "注意:")
  主切片 series 与 FULL_W/FULL_H 默认都由 showinf 从当前 VSI 现读, 不会沿用
  上一张切片的值。FULL_W/FULL_H 会被写进 Aperio ImageDescription 的裁剪区域
  字段, 必须与主切片实际尺寸一致, 否则 ImageScope 分析会失败。
  每次换新切片建议先跑 --dry-run 核对识别结果。

$(bold "示例:")
  bash vsi_to_svs.sh --input /path/new.vsi                 # 全自动, 直接转换
  CLEANUP=no bash vsi_to_svs.sh --input /path/new.vsi      # 后台跑时用这个
  bash vsi_to_svs.sh --input a.vsi --series 13             # 手动指定 series
  bash vsi_to_svs.sh --input a.vsi --dry-run               # 先核对再跑
  bash vsi_to_svs.sh --input a.vsi --cleanup-only          # 只清理中间文件
EOF
    exit 0
}


log()    { echo "[$(date '+%H:%M:%S')] $*"; }
success(){ green "[$(date '+%H:%M:%S')] ✓ $*"; }
warn()   { yellow "[$(date '+%H:%M:%S')] ⚠ $*"; }
fail()   { red "[$(date '+%H:%M:%S')] ✗ $*"; exit 1; }


# ── 路径派生 ─────────────────────────────────────
# 中间产物与默认输出名跟随输入切片名, 避免多张切片互相覆盖
# (旧版硬编码为 studio_base.tif / studio_pyramid.svs)
require_input() {
    [ -n "$INPUT_VSI" ] || fail "必须用 --input 指定输入 VSI 文件 (例: --input /mnt/data3/FKBP4.vsi)"
}

derive_paths() {
    SLIDE_NAME="$(basename "${INPUT_VSI%.vsi}")"
    BASE_TIFF="${WORK_DIR}/${SLIDE_NAME}_base.tif"
    PYRAMID_SVS="${WORK_DIR}/${SLIDE_NAME}_pyramid.svs"
    [ -z "$OUTPUT_SVS" ] && OUTPUT_SVS="${WORK_DIR}/${SLIDE_NAME}_final.svs"
    return 0
}


# ── 主切片 series 自动识别 ───────────────────────
# 展平后像素数最大的 series 即主切片 —— label / macro / 缩略图都远小于它。
# 注意必须用「展平后」的编号 (showinf 不带 -noflat), 那才是 bfconvert 用的编号。
probe_main_series() {
    "$SHOWINF" -nopix "$INPUT_VSI" 2>/dev/null | awk '
        $1 == "Series" { split($2, a, "#"); cur = a[2] }
        cur != "" && $1 == "Width"  { w[cur] = $3 }
        cur != "" && $1 == "Height" { h[cur] = $3 }
        END {
            best = ""; bestpx = 0
            for (s in w)
                if (w[s] * h[s] > bestpx) { bestpx = w[s] * h[s]; best = s }
            if (best != "") print best, w[best], h[best]
        }
    '
}

resolve_series() {
    if [ -n "$BF_SERIES" ]; then
        log "主切片 series (显式指定): ${BF_SERIES}"
        return 0
    fi

    log "自动识别主切片 series (showinf)..."
    local hit=""
    hit=$(probe_main_series) || hit=""

    if [ -z "$hit" ]; then
        if [ "$DRY_RUN" = "yes" ]; then
            warn "dry-run: 无法识别 series, 实际运行时会重试"
            BF_SERIES="?"
            return 0
        fi
        fail "无法识别主切片 series。请显式指定: --series <N>"
    fi

    BF_SERIES="${hit%% *}"
    local wh="${hit#* }"
    success "主切片 series ${BF_SERIES} (${wh% *}x${wh#* })"
    yellow "  若不对, 用 --series <N> 覆盖"
}


# ── 主切片尺寸探测 ───────────────────────────────
# FULL_W/FULL_H 会写进 Aperio ImageDescription 的裁剪区域字段。用错值
# (例如沿用上一张切片的硬编码尺寸) 会让 ImageScope 分析失败 —— 这正是
# 方案 3 当年要修的那个 bug。所以默认从 VSI 现读, 不留写死的值。
probe_dims() {
    # 展平后的 Series #N 块, 编号与 bfconvert 的 -series 一致
    "$SHOWINF" -nopix "$INPUT_VSI" 2>/dev/null | awk -v want="$BF_SERIES" '
        $1 == "Series" { split($2, a, "#"); inblk = (a[2] == want) }
        inblk && $1 == "Width"  { w = $3 }
        inblk && $1 == "Height" { h = $3 }
        END { if (w != "" && h != "") print w, h }
    '
}

detect_dims() {
    if [ -n "$FULL_W" ] && [ -n "$FULL_H" ]; then
        log "图像尺寸 (显式指定): ${FULL_W}x${FULL_H}"
        return 0
    fi

    log "探测 series ${BF_SERIES} 尺寸 (showinf)..."
    local dims=""
    dims=$(probe_dims) || dims=""

    if [ -z "$dims" ]; then
        if [ "$DRY_RUN" = "yes" ]; then
            warn "dry-run: 尺寸探测失败, 实际运行时会重试"
            return 0
        fi
        fail "无法探测 series ${BF_SERIES} 尺寸。请显式指定: --full-width <W> --full-height <H>"
    fi

    FULL_W="${dims%% *}"
    FULL_H="${dims##* }"
    success "series ${BF_SERIES}: ${FULL_W}x${FULL_H}"
    yellow "  若尺寸不对, 用 --full-width/--full-height 覆盖"
}


check_tools() {
    log "检查工具..."
    for tool in "$BFCONVERT" "$SHOWINF" "$VIPS" "$TIFFSET" "$TIFFINFO"; do
        if [ ! -x "$tool" ]; then
            fail "工具不存在: $tool"
        fi
    done
    for py in "$OPENSLIDE_PY" "$RNASEQ_PY"; do
        if [ ! -x "$py" ]; then
            fail "Python 不存在: $py"
        fi
    done
    if [ ! -f "$REENCODE_PY" ]; then
        fail "重编码脚本不存在: $REENCODE_PY"
    fi
    success "所有工具就绪"
}


check_input() {
    log "检查输入..."
    local vsi_name="${INPUT_VSI##*/}"
    vsi_name="${vsi_name%.vsi}"
    local companion_dir="${INPUT_VSI%/*}/_${vsi_name}_"
    # CellSens 配套文件夹可能是 _<name> 或 _<name>_
    if [ ! -d "$companion_dir" ]; then
        companion_dir="${INPUT_VSI%/*}/_${vsi_name}"
    fi

    if [ ! -f "$INPUT_VSI" ]; then
        fail "VSI 文件不存在: $INPUT_VSI"
    fi
    if [ ! -d "$companion_dir" ]; then
        fail "配套文件夹不存在: $companion_dir (应为 _${vsi_name}/)"
    fi
    success "输入验证通过: $INPUT_VSI ($(du -sh "$INPUT_VSI" | cut -f1))"
}


# ── Phase 1: bfconvert VSI → BigTIFF ──────────────
phase1_bfconvert() {
    log "Phase 1/4: bfconvert VSI → BigTIFF"

    if [ "$RESUME" = "yes" ] && [ -f "$BASE_TIFF" ]; then
        local sz=$(du -sh "$BASE_TIFF" | cut -f1)
        success "跳过 (已存在): $BASE_TIFF ($sz)"
        return 0
    fi

    local bf_quality=$(python3 -c "print($JPEG_QUALITY/100)")

    yellow "  预计耗时: ~2.5 小时"
    echo "  命令: $BFCONVERT -bigtiff -tilex $TILE_W -tiley $TILE_H -compression JPEG -quality $bf_quality -series $BF_SERIES -no-sas -overwrite \"$INPUT_VSI\" \"$BASE_TIFF\""

    if [ "$DRY_RUN" = "yes" ]; then return 0; fi

    $BFCONVERT -bigtiff -tilex "$TILE_W" -tiley "$TILE_H" \
        -compression JPEG -quality "$bf_quality" \
        -series "$BF_SERIES" -no-sas -overwrite \
        "$INPUT_VSI" "$BASE_TIFF"
    success "bfconvert 完成: $(du -sh "$BASE_TIFF" | cut -f1)"
}


# ── Phase 2: vips 构建 JPEG 金字塔 ────────────────
phase2_vips_pyramid() {
    log "Phase 2/4: vips 构建 JPEG 金字塔"

    if [ "$RESUME" = "yes" ] && [ -f "$PYRAMID_SVS" ]; then
        local sz=$(du -sh "$PYRAMID_SVS" | cut -f1)
        success "跳过 (已存在): $PYRAMID_SVS ($sz)"
        return 0
    fi

    if [ ! -f "$BASE_TIFF" ]; then
        if [ "$DRY_RUN" = "yes" ]; then
            warn "dry-run: $BASE_TIFF 不存在 (将由 Phase 1 生成)"
        else
            fail "输入文件不存在: $BASE_TIFF (请先运行 Phase 1)"
        fi
    fi

    yellow "  预计耗时: ~2 分钟"
    echo "  命令: $VIPS tiffsave \"$BASE_TIFF\" \"$PYRAMID_SVS\" --tile --tile-width=$TILE_W --tile-height=$TILE_H --pyramid --compression=jpeg --Q=$JPEG_QUALITY --bigtiff"

    if [ "$DRY_RUN" = "yes" ]; then return 0; fi

    $VIPS tiffsave "$BASE_TIFF" "$PYRAMID_SVS" \
        --tile --tile-width="$TILE_W" --tile-height="$TILE_H" \
        --pyramid --compression=jpeg --Q="$JPEG_QUALITY" --bigtiff
    success "vips 金字塔完成: $(du -sh "$PYRAMID_SVS" | cut -f1)"
}


# ── Phase 3: RGB JPEG 重编码 ──────────────────────
phase3_reencode() {
    log "Phase 3/4: RGB JPEG 重编码"

    if [ "$RESUME" = "yes" ] && [ -f "$OUTPUT_SVS" ]; then
        local sz=$(du -sh "$OUTPUT_SVS" | cut -f1)
        success "跳过 (已存在): $OUTPUT_SVS ($sz)"
        return 0
    fi

    if [ ! -f "$PYRAMID_SVS" ]; then
        if [ "$DRY_RUN" = "yes" ]; then
            warn "dry-run: $PYRAMID_SVS 不存在 (将由 Phase 2 生成)"
        else
            fail "输入文件不存在: $PYRAMID_SVS (请先运行 Phase 2)"
        fi
    fi

    yellow "  预计耗时: ~10-15 分钟"
    echo "  命令: $RNASEQ_PY \"$REENCODE_PY\" --input \"$PYRAMID_SVS\" --output \"$OUTPUT_SVS\" --quality $JPEG_QUALITY --full-width $FULL_W --full-height $FULL_H --mpp $MPP --apmag $APMAG --tiffset \"$TIFFSET\" --openslide-py \"$OPENSLIDE_PY\""

    if [ "$DRY_RUN" = "yes" ]; then return 0; fi

    $RNASEQ_PY "$REENCODE_PY" \
        --input "$PYRAMID_SVS" \
        --output "$OUTPUT_SVS" \
        --quality "$JPEG_QUALITY" \
        --full-width "$FULL_W" \
        --full-height "$FULL_H" \
        --mpp "$MPP" \
        --apmag "$APMAG" \
        --tiffset "$TIFFSET" \
        --openslide-py "$OPENSLIDE_PY"
    success "RGB JPEG 重编码完成: $(du -sh "$OUTPUT_SVS" | cut -f1)"
}


# ── Phase 4: 验证 ─────────────────────────────────
phase4_verify() {
    log "Phase 4/4: 验证"

    if [ ! -f "$OUTPUT_SVS" ]; then
        if [ "$DRY_RUN" = "yes" ]; then
            warn "dry-run: $OUTPUT_SVS 不存在 (将由 Phase 3 生成)"
            return 0
        else
            fail "输出文件不存在: $OUTPUT_SVS"
        fi
    fi

    if [ "$DRY_RUN" = "yes" ]; then return 0; fi

    echo ""
    bold "═══════════════════════════════════════════"
    bold "  tiffinfo 关键标签"
    bold "═══════════════════════════════════════════"
    $TIFFINFO "$OUTPUT_SVS" 2>&1 | grep -E \
        "TIFF directory|Compression|Photometric|Subfile Type|ImageDescription|Software" | head -30

    echo ""
    bold "═══════════════════════════════════════════"
    bold "  openslide 验证"
    bold "═══════════════════════════════════════════"
    $OPENSLIDE_PY -c "
import openslide, numpy as np
osr = openslide.OpenSlide('$OUTPUT_SVS')
print(f'vendor     : {osr.properties.get(\"openslide.vendor\")}')
print(f'level_count: {osr.level_count}')
for i in range(min(3, osr.level_count)):
    print(f'  level {i}: {osr.level_dimensions[i]}')
print(f'mpp-x      : {osr.properties.get(\"openslide.mpp-x\")}')
print(f'mpp-y      : {osr.properties.get(\"openslide.mpp-y\")}')
img = osr.read_region((0,0), osr.level_count-1, (256,256))
arr = np.array(img)
print(f'thumb RGB  : R={arr[:,:,0].mean():.0f} G={arr[:,:,1].mean():.0f} B={arr[:,:,2].mean():.0f}')
w0, h0 = osr.level_dimensions[0]
img0 = osr.read_region((w0//2, h0//2), 0, (256,256))
arr0 = np.array(img0)
print(f'level0 RGB : R={arr0[:,:,0].mean():.0f} G={arr0[:,:,1].mean():.0f} B={arr0[:,:,2].mean():.0f}')
"

    echo ""
    bold "═══════════════════════════════════════════"
    green "  最终输出: $OUTPUT_SVS ($(du -sh "$OUTPUT_SVS" | cut -f1))"
    bold "═══════════════════════════════════════════"
}


# ── 清理中间文件 ────────────────────────────────
cleanup() {
    log "清理中间文件..."
    local to_remove=()

    # 中间产物 (工作流产生的)
    [ -f "$BASE_TIFF" ] && to_remove+=("$BASE_TIFF")
    [ -f "$PYRAMID_SVS" ] && to_remove+=("$PYRAMID_SVS")

    # 旧实验产物 (方案1-4 的失败输出)
    local obsolete=(
        "${WORK_DIR}/studio_deflate.svs"
        "${WORK_DIR}/studio_deflate_patched.svs"
        "${WORK_DIR}/studio_fixed.svs"
        "${WORK_DIR}/studio.svs.bak"
        "${WORK_DIR}/convert.sh"
        "${WORK_DIR}/auto_build_svs.sh"
        "${WORK_DIR}/fix_svs.sh"
        "${WORK_DIR}/convert.log"
        "${WORK_DIR}/auto_build.log"
        "${WORK_DIR}/base_convert.log"
    )
    for f in "${obsolete[@]}"; do
        [ -f "$f" ] && to_remove+=("$f")
    done

    if [ ${#to_remove[@]} -eq 0 ]; then
        warn "没有需要清理的文件"
        return 0
    fi

    echo "  将删除以下文件:"
    local total=0
    for f in "${to_remove[@]}"; do
        local sz=$(du -sh "$f" 2>/dev/null | cut -f1)
        echo "    - $f ($sz)"
        total=$((total + $(stat -c%s "$f" 2>/dev/null || echo 0)))
    done
    echo "  释放空间: ~$((total / 1024 / 1024 / 1024)) GB"

    if [ "$DRY_RUN" = "yes" ]; then
        warn "dry-run: 未实际删除"
        return 0
    fi

    # 安全确认
    echo ""
    read -p "  确认删除? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        warn "已取消"
        return 0
    fi

    for f in "${to_remove[@]}"; do
        rm -f "$f"
        echo "    已删除: $f"
    done
    success "清理完成"
}


# ── 主流程 ──────────────────────────────────────
main() {
    require_input
    derive_paths

    echo ""
    bold "╔══════════════════════════════════════════╗"
    bold "║  VSI → SVS 转换工作流                    ║"
    bold "╚══════════════════════════════════════════╝"
    echo ""
    echo "  输入:  $INPUT_VSI"
    echo "  输出:  $OUTPUT_SVS"
    echo "  中间:  $BASE_TIFF"
    echo "         $PYRAMID_SVS"
    echo "  质量:  $JPEG_QUALITY"
    echo "  Series: ${BF_SERIES:-自动识别}"
    echo "  恢复:  $RESUME | 清理: $CLEANUP"
    echo ""

    check_tools
    check_input
    resolve_series
    detect_dims

    # 工作目录 / 输出目录可能还不存在 (首次运行, 或被清理过)
    if [ "$DRY_RUN" != "yes" ]; then
        mkdir -p "$WORK_DIR" || fail "无法创建工作目录: $WORK_DIR"
        mkdir -p "$(dirname "$OUTPUT_SVS")" || fail "无法创建输出目录: $(dirname "$OUTPUT_SVS")"
    fi

    phase1_bfconvert
    phase2_vips_pyramid
    phase3_reencode
    phase4_verify

    echo ""
    green "═══════════════════════════════════════════"
    green "  转换成功完成!"
    green "  输出: $OUTPUT_SVS"
    green "═══════════════════════════════════════════"

    if [ "$CLEANUP" = "yes" ] && [ "$DRY_RUN" != "yes" ]; then
        echo ""
        read -p "  清理中间文件? [y/N] " do_cleanup
        if [ "$do_cleanup" = "y" ] || [ "$do_cleanup" = "Y" ]; then
            cleanup
        fi
    fi
}


# ── 参数解析 ──────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --input)       INPUT_VSI="$2"; shift 2 ;;
        --output)      OUTPUT_SVS="$2"; shift 2 ;;
        --quality)     JPEG_QUALITY="$2"; shift 2 ;;
        --series)      BF_SERIES="$2"; shift 2 ;;
        --full-width)  FULL_W="$2"; shift 2 ;;
        --full-height) FULL_H="$2"; shift 2 ;;
        --mpp)         MPP="$2"; shift 2 ;;
        --apmag)       APMAG="$2"; shift 2 ;;
        --work-dir)    WORK_DIR="$2"; shift 2 ;;
        --resume)      RESUME=yes; shift ;;
        --no-resume)   RESUME=no; shift ;;
        --no-cleanup)  CLEANUP=no; shift ;;
        --cleanup-only) require_input; derive_paths; cleanup; exit 0 ;;
        --dry-run)     DRY_RUN=yes; shift ;;
        --help)        usage ;;
        *) echo "未知选项: $1"; usage ;;
    esac
done

main
