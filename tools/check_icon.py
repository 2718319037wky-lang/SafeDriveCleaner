# -*- coding: utf-8 -*-
"""Validate app.ico: container structure + per-layer PNG integrity + artwork presence.

Usage: python check_icon.py <app.ico>

Why this exists:
    An .ico is a binary artifact. "The file exists and is not empty" proves nothing.
    The classic failure is an ICO whose structure is fine but whose artwork is blank
    or fully transparent -- the shortcut and the window still load it, they just fall
    back to a default icon, and you cannot tell without opening display settings.

Why not a colour histogram:
    This artwork deliberately uses the same dark blue (#1D4ED8) for both the check
    mark and the bottom of the background gradient, so colour-based classification
    confuses the two. Instead we sample at *expected geometric positions*.

Output is ASCII-only on purpose: Chinese text through the console pipe is decoded
as GBK and turns into mojibake, which would make every assertion message useless.
"""
import struct
import sys
import zlib

EXPECTED_SIZES = [16, 24, 32, 48, 64, 128, 256]
PNG_SIG = b'\x89PNG\r\n\x1a\n'
MIN_OPAQUE_PCT = 60.0


def fail(msg):
    print('FAIL: ' + msg)
    sys.exit(1)


def parse_png(data):
    """Return (width, height, rgba). Validates signature, per-chunk CRC and row count."""
    if data[:8] != PNG_SIG:
        fail('PNG signature missing')
    pos = 8
    width = height = None
    idat = b''
    seen_iend = False
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        (crc,) = struct.unpack('>I', data[pos + 8 + length:pos + 12 + length])
        if crc != (zlib.crc32(tag + payload) & 0xffffffff):
            fail('CRC mismatch in chunk ' + tag.decode('ascii', 'replace'))
        if tag == b'IHDR':
            width, height, depth, color, comp, filt, inter = struct.unpack('>IIBBBBB', payload)
            if depth != 8 or color != 6 or inter != 0:
                fail('unexpected IHDR: depth=%d color=%d interlace=%d' % (depth, color, inter))
        elif tag == b'IDAT':
            idat += payload
        elif tag == b'IEND':
            seen_iend = True
        pos += 12 + length
    if not seen_iend:
        fail('IEND missing')
    if width != height:
        fail('not square: %dx%d' % (width, height))

    raw = zlib.decompress(idat)
    stride = width * 4
    if len(raw) != (stride + 1) * height:
        fail('IDAT size mismatch: %d != %d' % (len(raw), (stride + 1) * height))

    rgba = bytearray()
    for y in range(height):
        off = y * (stride + 1)
        if raw[off] != 0:
            fail('row %d uses filter %d (only filter 0 supported)' % (y, raw[off]))
        rgba += raw[off + 1:off + 1 + stride]
    return width, height, bytes(rgba)


def sample(rgba, size, nx, ny, radius):
    """Average a (2*radius+1)^2 neighbourhood around normalised coord (nx, ny)."""
    ix = int(round(nx * (size - 1)))
    iy = int(round(ny * (size - 1)))
    acc = [0.0, 0.0, 0.0, 0.0]
    n = 0
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            x = min(max(ix + dx, 0), size - 1)
            y = min(max(iy + dy, 0), size - 1)
            i = (y * size + x) * 4
            acc[0] += rgba[i]
            acc[1] += rgba[i + 1]
            acc[2] += rgba[i + 2]
            acc[3] += rgba[i + 3]
            n += 1
    return acc[0] / n, acc[1] / n, acc[2] / n, acc[3] / n


# (nx, ny, expected, radius, description)
# Expected values: 'white' (shield fill), 'blue' (background gradient, includes the
# check mark since they share a hue) or 'clear' (outside the rounded square).
# Geometry mirrors the SHIELD / CHECK constants in tools/make_icon.py.
PROBES_256 = [
    (0.500, 0.250, 'white', 1, 'shield upper body is white'),
    (0.500, 0.380, 'white', 1, 'shield centre is white'),
    (0.300, 0.330, 'white', 1, 'shield upper-left is white'),
    (0.445, 0.590, 'blue', 0, 'check mark vertex is not white'),
    (0.600, 0.435, 'blue', 0, 'check mark arm is not white'),
    (0.500, 0.950, 'blue', 1, 'below shield tip is background'),
    (0.500, 0.040, 'blue', 1, 'above shield top is background'),
    (0.015, 0.015, 'clear', 0, 'top-left is outside the rounded square'),
    (0.985, 0.985, 'clear', 0, 'bottom-right is outside the rounded square'),
]


def classify(r, g, b, a):
    if a < 128:
        return 'clear'
    if r > 225 and g > 225 and b > 225:
        return 'white'
    return 'blue'


def main():
    if len(sys.argv) < 2:
        fail('usage: check_icon.py <app.ico>')
    path = sys.argv[1]
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except IOError as e:
        fail('cannot read %s: %s' % (path, e))

    if len(data) < 6:
        fail('file too small')

    reserved, itype, count = struct.unpack('<HHH', data[:6])
    if reserved != 0 or itype != 1:
        fail('bad ICO header: reserved=%d type=%d' % (reserved, itype))
    if count != len(EXPECTED_SIZES):
        fail('layer count %d != expected %d' % (count, len(EXPECTED_SIZES)))
    print('container: type=%d layers=%d bytes=%d' % (itype, count, len(data)))

    ok = True
    layers = {}
    for i in range(count):
        base = 6 + i * 16
        w, h, colors, res, planes, bpp, length, offset = struct.unpack(
            '<BBBBHHII', data[base:base + 16])
        expect = EXPECTED_SIZES[i]
        if bpp != 32:
            print('layer %d: FAIL bpp=%d (expected 32)' % (expect, bpp))
            ok = False
            continue
        declared = 256 if w == 0 else w
        if declared != expect:
            print('layer %d: FAIL declared width=%d' % (expect, declared))
            ok = False
            continue
        pw, ph, rgba = parse_png(data[offset:offset + length])
        if pw != expect or ph != expect:
            print('layer %d: FAIL png is %dx%d' % (expect, pw, ph))
            ok = False
            continue
        layers[expect] = rgba
        print('layer %3d: PNG structure OK' % expect)

    # Every layer must actually carry the artwork.
    for size in EXPECTED_SIZES:
        rgba = layers.get(size)
        if rgba is None:
            ok = False
            continue
        total = size * size
        opaque = 0
        white = 0
        blue = 0
        for i in range(0, len(rgba), 4):
            a = rgba[i + 3]
            if a < 128:
                continue
            opaque += 1
            if rgba[i] > 225 and rgba[i + 1] > 225 and rgba[i + 2] > 225:
                white += 1
            else:
                blue += 1
        opaque_pct = 100.0 * opaque / total
        white_pct = 100.0 * white / total
        blue_pct = 100.0 * blue / total
        print('layer %3d: opaque=%5.1f%%  shield-fill=%5.1f%%  non-fill=%5.1f%%'
              % (size, opaque_pct, white_pct, blue_pct))
        if opaque_pct < MIN_OPAQUE_PCT:
            print('    FAIL: artwork too transparent')
            ok = False
        if white_pct < 3.0:
            print('    FAIL: shield fill missing')
            ok = False
        if blue_pct < 3.0:
            print('    FAIL: background missing')
            ok = False

    # Geometric probes only on the 256 layer, where a pixel is unambiguous.
    rgba256 = layers.get(256)
    if rgba256 is not None:
        print('256 layer geometric probes:')
        for nx, ny, want, radius, desc in PROBES_256:
            r, g, b, a = sample(rgba256, 256, nx, ny, radius)
            got = classify(r, g, b, a)
            status = 'OK ' if got == want else 'BAD'
            print('    %s  %-38s want=%-5s got=%-5s rgb=(%.0f,%.0f,%.0f) a=%.0f'
                  % (status, desc, want, got, r, g, b, a))
            if got != want:
                ok = False

    if not ok:
        print('RESULT: FAILED')
        sys.exit(1)
    print('RESULT: ALL LAYERS OK')


if __name__ == '__main__':
    main()
