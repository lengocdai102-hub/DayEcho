#!/usr/bin/env python3
"""生成合规的 AppIcon：1024x1024、**无 alpha 通道**、RGB。

为什么需要这个脚本
------------------
1. `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` 声明了
   `AppIcon-1024.png`，但仓库里**从来没有这个文件** ——
   `legal/AppIcon-1024.png` 是 2048x2048 且带 alpha。
   ⇒ actool 找不到文件 ⇒ `Assets.car` 里没有 AppIcon ⇒
   **主 App 图标显示为白色**（iOS 用白色占位图）。

2. App Store / actool 对 1024 图标要求**不能带 alpha 通道**
   （`colortype 6` = RGBA 会被拒绝；必须是 `colortype 2` = RGB）。

3. `sips` 无法去掉 alpha 通道，所以自己写 PNG 编码。

用法
----
    python3 legal/make_appicon.py            # 输出到 appiconset
    python3 legal/make_appicon.py --check    # 只校验，不写
"""

import argparse
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "legal", "AppIcon-1024.png")
DEST = os.path.join(
    ROOT, "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png"
)


# ---------------------------------------------------------------- PNG 读

def read_png(path):
    """读 PNG，返回 (width, height, pixels)，pixels 是 bytearray，每像素 3 字节 RGB。

    只支持 8-bit、colortype 2(RGB) / 6(RGBA)，非隔行。
    """
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("不是 PNG 文件")

    pos = 8
    idat = bytearray()
    width = height = depth = color = None
    interlace = 0

    while pos < len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if ctype == b"IHDR":
            width, height, depth, color, _comp, _filt, interlace = struct.unpack(
                ">IIBBBBB", chunk[:13]
            )
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length

    if depth != 8:
        raise ValueError("只支持 8-bit，当前 %d" % depth)
    if interlace != 0:
        raise ValueError("不支持隔行 PNG")
    if color not in (2, 6):
        raise ValueError("只支持 colortype 2/6，当前 %d" % color)

    raw = zlib.decompress(bytes(idat))
    channels = {2: 3, 6: 4}[color]
    stride = width * channels

    out = bytearray()
    prev = bytearray(stride)
    i = 0
    for _ in range(height):
        filt = raw[i]
        i += 1
        line = bytearray(raw[i : i + stride])
        i += stride
        if filt == 1:
            for x in range(channels, stride):
                line[x] = (line[x] + line[x - channels]) & 0xFF
        elif filt == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif filt == 3:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif filt == 4:
            for x in range(stride):
                a = line[x - channels] if x >= channels else 0
                b = prev[x]
                c = prev[x - channels] if x >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[x] = (line[x] + pr) & 0xFF
        elif filt != 0:
            raise ValueError("未知 filter 类型 %d" % filt)
        out += line
        prev = line

    # 转成 RGB（alpha 直接丢掉 —— 背景本来就是不透明的渐变）
    rgb = bytearray(width * height * 3)
    if color == 6:
        for p in range(width * height):
            rgb[p * 3 : p * 3 + 3] = out[p * 4 : p * 4 + 3]
    else:
        rgb = out

    return width, height, rgb


def resample_box(src, sw, sh, dst_w, dst_h):
    """面积平均缩放（box filter），够用且不会引入锯齿。"""
    dst = bytearray(dst_w * dst_h * 3)
    for y in range(dst_h):
        y0 = y * sh // dst_h
        y1 = max(y0 + 1, (y + 1) * sh // dst_h)
        for x in range(dst_w):
            x0 = x * sw // dst_w
            x1 = max(x0 + 1, (x + 1) * sw // dst_w)
            r = g = b = n = 0
            for yy in range(y0, y1):
                base = (yy * sw) * 3
                for xx in range(x0, x1):
                    o = base + xx * 3
                    r += src[o]
                    g += src[o + 1]
                    b += src[o + 2]
                    n += 1
            o = (y * dst_w + x) * 3
            dst[o] = r // n
            dst[o + 1] = g // n
            dst[o + 2] = b // n
    return dst


# ---------------------------------------------------------------- PNG 写

def write_png_rgb(path, width, height, pixels):
    """写 8-bit RGB（colortype 2，**无 alpha**）PNG。"""

    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * stride : (y + 1) * stride]

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    out += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(out)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ap.add_argument("--size", type=int, default=1024)
    args = ap.parse_args()

    if not os.path.exists(SOURCE):
        print("找不到源图: %s" % SOURCE)
        return 1

    sw, sh, rgb = read_png(SOURCE)
    print("源图: %dx%d" % (sw, sh))

    if (sw, sh) != (args.size, args.size):
        print("缩放到 %dx%d …" % (args.size, args.size))
        rgb = resample_box(rgb, sw, sh, args.size, args.size)
        sw = sh = args.size

    # 抽样看是不是空白图
    samples = set()
    for y in range(0, sh, max(1, sh // 16)):
        for x in range(0, sw, max(1, sw // 16)):
            o = (y * sw + x) * 3
            samples.add((rgb[o], rgb[o + 1], rgb[o + 2]))
    if len(samples) < 3:
        print("✗ 图标看起来是纯色/空白（只有 %d 种抽样颜色），拒绝写入" % len(samples))
        return 1

    if args.check:
        print("✓ 源图可用，抽样颜色 %d 种" % len(samples))
        return 0

    os.makedirs(os.path.dirname(DEST), exist_ok=True)
    write_png_rgb(DEST, sw, sh, rgb)
    print("✓ 已写出 %s (%dx%d, RGB 无 alpha)" % (DEST, sw, sh))

    # 自检
    w2, h2, _ = read_png(DEST)
    with open(DEST, "rb") as fh:
        head = fh.read(26)
    color_type = struct.unpack(">B", head[25:26])[0]
    print("  自检: %dx%d colortype=%d (2=RGB 无 alpha ✓)" % (w2, h2, color_type))
    return 0


if __name__ == "__main__":
    sys.exit(main())
