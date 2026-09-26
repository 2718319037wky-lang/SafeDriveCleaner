# -*- coding: utf-8 -*-
"""生成 app.ico：蓝底 + 白色盾牌 + 对勾（纯标准库，手写 PNG + ICO）。

PNG 编码与 ICO 容器部分沿用了 windows-desktop-shortcut 技能里已验证过的实现，
只替换图案渲染函数。

用法: python make_icon.py <输出路径.ico>
"""
import zlib
import struct
import math
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else 'app.ico'
SIZES = [16, 24, 32, 48, 64, 128, 256]

C_TOP = (0x3B, 0x82, 0xF6)      # 渐变起始（亮蓝）
C_BOT = (0x1D, 0x4E, 0xD8)      # 渐变结束（深蓝）
C_SHIELD = (0xFF, 0xFF, 0xFF)   # 盾牌：纯白
C_CHECK = (0x1D, 0x4E, 0xD8)    # 对勾：深蓝（在白盾上形成镂空感）

# 盾牌轮廓（归一化坐标，y 向下）
SHIELD = [
    (0.500, 0.120),
    (0.825, 0.240),
    (0.825, 0.500),
    (0.760, 0.665),
    (0.500, 0.880),
    (0.240, 0.665),
    (0.175, 0.500),
    (0.175, 0.240),
]

# 对勾折线（归一化坐标）
CHECK = [(0.320, 0.470), (0.445, 0.590), (0.690, 0.345)]
CHECK_HALF_W = 0.055            # 半线宽（归一化）


def clamp01(v):
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def lerp(a, b, t):
    return a + (b - a) * t


def dist_seg(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 <= 0.0 else (wx * vx + wy * vy) / L2
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    dx, dy = wx - t * vx, wy - t * vy
    return math.hypot(dx, dy)


def poly_sdf(px, py, pts):
    """点到多边形的有符号距离：内部为负。"""
    inside = False
    n = len(pts)
    j = n - 1
    for i in range(n):
        xi, yi = pts[i]
        xj, yj = pts[j]
        if (yi > py) != (yj > py):
            xt = (xj - xi) * (py - yi) / (yj - yi) + xi
            if px < xt:
                inside = not inside
        j = i
    d = min(dist_seg(px, py, pts[i][0], pts[i][1], pts[(i + 1) % n][0], pts[(i + 1) % n][1])
            for i in range(n))
    return -d if inside else d


def render(size):
    """返回 size×size 的 RGBA bytes。解析式抗锯齿，不依赖第三方库。"""
    inset = size * 0.02
    half = size * 0.5 - inset
    radius = size * 0.22
    cx = cy = size * 0.5

    shield_px = [(x * size, y * size) for (x, y) in SHIELD]
    check_px = [(x * size, y * size) for (x, y) in CHECK]
    check_w = CHECK_HALF_W * size

    px_buf = bytearray(size * size * 4)

    def rrect_cov(x, y):
        dx = abs(x - cx) - (half - radius)
        dy = abs(y - cy) - (half - radius)
        ax = dx if dx > 0 else 0.0
        ay = dy if dy > 0 else 0.0
        dist = math.hypot(ax, ay) + min(max(dx, dy), 0.0) - radius
        return clamp01(0.5 - dist)

    def shield_cov(x, y):
        return clamp01(0.5 - poly_sdf(x, y, shield_px))

    def check_cov(x, y):
        d = min(dist_seg(x, y, check_px[i][0], check_px[i][1],
                         check_px[i + 1][0], check_px[i + 1][1])
                for i in range(len(check_px) - 1))
        return clamp01(0.5 - (d - check_w))

    for yy in range(size):
        t = (yy + 0.5) / size
        base_r = lerp(C_TOP[0], C_BOT[0], t)
        base_g = lerp(C_TOP[1], C_BOT[1], t)
        base_b = lerp(C_TOP[2], C_BOT[2], t)
        row = yy * size * 4
        for xx in range(size):
            x = xx + 0.5
            y = yy + 0.5
            a = rrect_cov(x, y)
            i = row + xx * 4
            if a <= 0.0:
                px_buf[i] = px_buf[i + 1] = px_buf[i + 2] = px_buf[i + 3] = 0
                continue

            cr, cg, cb = base_r, base_g, base_b

            s = shield_cov(x, y)
            if s > 0.0:
                cr = lerp(cr, C_SHIELD[0], s)
                cg = lerp(cg, C_SHIELD[1], s)
                cb = lerp(cb, C_SHIELD[2], s)

            k = check_cov(x, y)
            if k > 0.0:
                # 对勾只在盾牌范围内生效，避免溢出到蓝色背景上
                k *= s
                cr = lerp(cr, C_CHECK[0], k)
                cg = lerp(cg, C_CHECK[1], k)
                cb = lerp(cb, C_CHECK[2], k)

            px_buf[i] = int(cr + 0.5)
            px_buf[i + 1] = int(cg + 0.5)
            px_buf[i + 2] = int(cb + 0.5)
            px_buf[i + 3] = int(a * 255.0 + 0.5)

    return bytes(px_buf)


def png_encode(size, rgba):
    raw = bytearray()
    stride = size * 4
    for yy in range(size):
        raw.append(0)
        raw += rgba[yy * stride:(yy + 1) * stride]

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
            chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))


def build_ico(items):
    n = len(items)
    header = struct.pack('<HHH', 0, 1, n)
    offset = 6 + 16 * n
    entries = b''
    blob = b''
    for size, png in items:
        b = 0 if size >= 256 else size
        entries += struct.pack('<BBBBHHII', b, b, 0, 0, 1, 32, len(png), offset)
        offset += len(png)
        blob += png
    return header + entries + blob


items = []
for s in SIZES:
    items.append((s, png_encode(s, render(s))))

data = build_ico(items)
with open(OUT, 'wb') as f:
    f.write(data)

print('WROTE %s bytes=%d sizes=%s' % (OUT, len(data), ','.join(str(s) for s in SIZES)))
