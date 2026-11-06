#!/usr/bin/env python3
"""Quantify bright-specimen window captures: non-background coverage,
functional hue coverage (purple/blue/yellow/orange), luminance spread.
Color values are lighting-shifted on purpose; we quantify hue families."""
import colorsys
import sys

import numpy as np
from PIL import Image

BG = np.array([238, 237, 231], dtype=np.int16)
HUES = {"purple": (250, 310), "blue": (195, 250), "yellow": (40, 68), "orange": (12, 40)}


def hue_deg(rgb):
    r, g, b = [c / 255.0 for c in rgb]
    h, _s, _v = colorsys.rgb_to_hsv(r, g, b)
    return h * 360.0


def analyse(path):
    image = np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)
    height, width, _ = image.shape
    flat = image.reshape(-1, 3)
    bg = (np.abs(flat - BG) <= 10).all(axis=1)
    non_bg = flat[~bg]
    luminance = non_bg @ np.array([0.2126, 0.7152, 0.0722])
    hues = np.array([hue_deg(px) for px in non_bg])
    saturated = non_bg.max(axis=1) - non_bg.min(axis=1) > 30
    print(f"{path}: {width}x{height}")
    print(f"  non-background pixels: {non_bg.shape[0]} ({non_bg.shape[0] / flat.shape[0]:.2%})")
    print(f"  luminance mean/std/min/max: {luminance.mean():.1f} / {luminance.std():.1f} / {luminance.min()} / {luminance.max()}")
    for name, (lo, hi) in HUES.items():
        mask = saturated & ((hues >= lo) & (hues < hi))
        count = int(mask.sum())
        line = f"  {name} hue {lo}-{hi}deg: {count} px ({count / flat.shape[0]:.3%})"
        if count:
            rgb_median = np.median(non_bg[mask], axis=0).astype(int)
            line += f", median rgb {tuple(rgb_median)}"
        print(line)


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        analyse(arg)
