# -*- coding: utf-8 -*-
"""美术验收图片指标：对每张图输出一行 JSON——亮度均值/标准差取灰度直方图(convert L)统计，饱和度取 HSV S 通道均值×100/255，unique_colors 取 getcolors(maxcolors=1<<24) 计数（先转 RGB），overexposed_pct 为灰度≥250 像素占比。用法：python tools/measure_image.py <图片路径> [<图片路径>...]（依赖 Pillow）"""
import json
import math
import sys

from PIL import Image

MAX_COLORS = 1 << 24
OVEREXPOSED_GRAY = 250


def _hist_mean_std(hist):
    total = sum(hist)
    mean = sum(i * c for i, c in enumerate(hist)) / total
    var = sum(c * (i - mean) ** 2 for i, c in enumerate(hist)) / total
    return mean, math.sqrt(var)


def measure(path):
    img = Image.open(path)
    gray_hist = img.convert("L").histogram()
    gray_total = sum(gray_hist)
    brightness_mean, brightness_std = _hist_mean_std(gray_hist)
    sat_mean, _ = _hist_mean_std(img.convert("HSV").histogram()[256:512])
    colors = img.convert("RGB").getcolors(maxcolors=MAX_COLORS)
    overexposed = sum(gray_hist[OVEREXPOSED_GRAY:]) * 100.0 / gray_total
    return {
        "path": path,
        "brightness_mean": round(brightness_mean, 2),
        "brightness_std": round(brightness_std, 2),
        "saturation_mean": round(sat_mean * 100.0 / 255.0, 2),
        "unique_colors": len(colors),
        "overexposed_pct": round(overexposed, 2),
    }


def main(argv):
    if len(argv) < 2:
        print("用法: python tools/measure_image.py <图片路径> [<图片路径>...]", file=sys.stderr)
        return 2
    for path in argv[1:]:
        print(json.dumps(measure(path), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
