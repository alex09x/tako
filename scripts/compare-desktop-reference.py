#!/usr/bin/env python3
# tako — Reproducible native desktop visual comparison
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Compare sRGB screenshots without rescaling or silently aligning the images.

Use explicit pixel crops to remove the browser's viewport outside #app. Mask
only documented dynamic content (terminal output or moving status effects).
The report always records how much of the image was excluded. Geometry and AX
interaction tests remain the acceptance authority; this supplies visual evidence.
"""

import argparse
import io
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageCms, ImageDraw


def rectangle(value):
    parts = tuple(int(part) for part in value.split(","))
    if len(parts) != 4 or parts[0] < 0 or parts[1] < 0 or min(parts[2:]) <= 0:
        raise argparse.ArgumentTypeError("expected nonnegative x,y and positive width,height")
    x, y, width, height = parts
    return x, y, x + width, y + height


def load_srgb(path, crop):
    with Image.open(path) as original:
        original.load()
        image = original.convert("RGB")
        profile = original.info.get("icc_profile")
        if profile:
            source = ImageCms.ImageCmsProfile(io.BytesIO(profile))
            image = ImageCms.profileToProfile(image, source, ImageCms.createProfile("sRGB"), outputMode="RGB")
        if crop:
            if crop[2] > image.width or crop[3] > image.height:
                raise ValueError(f"crop exceeds {path}: {image.size}")
            image = image.crop(crop)
        return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--reference-crop", type=rectangle)
    parser.add_argument("--actual-crop", type=rectangle)
    parser.add_argument("--exclude", type=rectangle, action="append", default=[])
    parser.add_argument("--tolerance", type=int, default=12)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 0 <= args.tolerance <= 255:
        parser.error("tolerance must be in 0...255")
    reference = load_srgb(args.reference, args.reference_crop)
    actual = load_srgb(args.actual, args.actual_crop)
    if reference.size != actual.size:
        parser.error(f"dimensions differ: reference={reference.size}, actual={actual.size}; no automatic resize")
    mask = Image.new("L", reference.size, 255)
    draw = ImageDraw.Draw(mask)
    for box in args.exclude:
        if box[2] > reference.width or box[3] > reference.height:
            parser.error("excluded rectangle exceeds cropped comparison")
        draw.rectangle((box[0], box[1], box[2] - 1, box[3] - 1), fill=0)
    included = mask.histogram()[255]
    if not included:
        parser.error("comparison excludes every pixel")
    difference = ImageChops.difference(reference, actual)
    red, green, blue = difference.split()
    maximum = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    histogram = maximum.histogram(mask=mask)
    above = sum(histogram[args.tolerance + 1:])
    channel_sum = sum(sum(index * count for index, count in enumerate(channel.histogram(mask=mask)))
                      for channel in (red, green, blue))
    total = reference.width * reference.height
    report = {
        "reference": str(args.reference), "actual": str(args.actual),
        "size": list(reference.size), "reference_crop": args.reference_crop,
        "actual_crop": args.actual_crop, "excluded_rectangles": args.exclude,
        "compared_pixels": included, "excluded_fraction": (total - included) / total,
        "channel_tolerance": args.tolerance, "pixels_above_tolerance": above,
        "fraction_above_tolerance": above / included,
        "mean_absolute_channel_error": channel_sum / (included * 3),
        "color_space": "sRGB", "automatic_rescaling": False,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    # Amplified difference is diagnostic, not a replacement for the screenshots.
    visible_difference = Image.composite(difference, Image.new("RGB", reference.size), mask)
    visible_difference.point(lambda value: min(255, value * 4)).save(args.output / "difference.png")
    Image.blend(reference, actual, .5).save(args.output / "overlay.png")
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
