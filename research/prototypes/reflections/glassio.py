"""Image files and colour for the glass prototypes (RM-22, INF-14), with NumPy and Pillow only.

8-bit JPEG and PNG are read with Pillow, which reduces 16-bit RGB to 8 bits; 16-bit RGB TIFF, the
format the glass set and Lightroom's exports use, is read and written here: baseline TIFF, one
strip per 64 rows, uncompressed or Deflate with horizontal differencing (compression 8, predictor 2).
"""

import pathlib
import struct
import zlib

import numpy as np
from PIL import Image

ROWS_PER_STRIP = 64


def srgb_to_linear(v):
    v = np.asarray(v, np.float32)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(v):
    v = np.clip(np.asarray(v, np.float32), 0, None)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * np.power(v, 1 / 2.4) - 0.055).astype(np.float32)


def read(path):
    """An image as float32 H×W×3 in [0, 1], in the file's own encoding (sRGB for these sets)."""
    path = pathlib.Path(path)
    if path.suffix.lower() in (".tif", ".tiff"):
        return read_tiff(path)
    image = Image.open(path)
    image = image.convert("RGB")
    return np.asarray(image, np.float32) / 255.0


def read_tiff(path):
    data = pathlib.Path(path).read_bytes()
    order = {b"II": "<", b"MM": ">"}[data[:2]]
    (offset,) = struct.unpack(order + "I", data[4:8])
    (count,) = struct.unpack(order + "H", data[offset : offset + 2])
    tags = {}
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8}
    codes = {1: "B", 2: "c", 3: "H", 4: "I", 5: "II"}
    for i in range(count):
        entry = data[offset + 2 + 12 * i : offset + 14 + 12 * i]
        tag, kind, n = struct.unpack(order + "HHI", entry[:8])
        size = sizes[kind] * n
        raw = entry[8:12] if size <= 4 else data[struct.unpack(order + "I", entry[8:12])[0] :][:size]
        values = struct.unpack(order + codes[kind] * n, raw[:size]) if kind != 2 else raw
        tags[tag] = values
    width, height = tags[256][0], tags[257][0]
    bits = tags[258][0]
    samples = tags.get(277, (1,))[0]
    compression = tags.get(259, (1,))[0]
    predictor = tags.get(317, (1,))[0]
    rows = tags.get(278, (height,))[0]
    if tags.get(284, (1,))[0] != 1 or compression not in (1, 8, 32946):
        raise ValueError(f"{path}: only chunky, uncompressed or Deflate TIFF is read here")
    dtype = np.dtype(order + {8: "u1", 16: "u2"}[bits])
    strips = []
    for start, length in zip(tags[273], tags[279]):
        chunk = data[start : start + length]
        strips.append(zlib.decompress(chunk) if compression != 1 else chunk)
    pixels = np.frombuffer(b"".join(strips), dtype)[: width * height * samples].reshape(height, width, samples)
    if predictor == 2:
        pixels = np.cumsum(pixels.astype(dtype.newbyteorder("=")), axis=1, dtype=dtype.newbyteorder("="))
    pixels = pixels[..., :3].astype(np.float32) / (2**bits - 1)
    return pixels if samples >= 3 else np.repeat(pixels, 3, axis=2)


def write_tiff16(path, rgb01, compress=True):
    """A 16-bit RGB TIFF, Deflate-compressed with horizontal differencing unless compress is False."""
    pixels = np.round(np.clip(rgb01, 0, 1) * 65535).astype("<u2")
    height, width = pixels.shape[:2]
    strips = []
    for y in range(0, height, ROWS_PER_STRIP):
        block = pixels[y : y + ROWS_PER_STRIP]
        if compress:
            block = np.diff(block, axis=1, prepend=np.zeros((block.shape[0], 1, 3), "<u2")).astype("<u2")
            strips.append(zlib.compress(block.tobytes(), 6))
        else:
            strips.append(block.tobytes())
    entries = [
        (256, 4, [width]),
        (257, 4, [height]),
        (258, 3, [16, 16, 16]),
        (259, 3, [8 if compress else 1]),
        (262, 3, [2]),
        (273, 4, None),
        (277, 3, [3]),
        (278, 4, [ROWS_PER_STRIP]),
        (279, 4, [len(s) for s in strips]),
        (284, 3, [1]),
        (317, 3, [2 if compress else 1]),
    ]
    ifd_size = 2 + 12 * len(entries) + 4
    extra = bytearray()
    base = 8 + ifd_size
    # Out-of-line values (BitsPerSample, offsets and byte counts) follow the IFD, then the strips.
    layout = {}
    for tag, kind, values in entries:
        n = len(strips) if tag == 273 else len(values)
        size = {3: 2, 4: 4}[kind] * n
        if size > 4:
            layout[tag] = base + len(extra)
            extra += bytes(size)
    data_start = base + len(extra)
    offsets, position = [], data_start
    for s in strips:
        offsets.append(position)
        position += len(s)
    ifd = struct.pack("<H", len(entries))
    for tag, kind, values in entries:
        values = offsets if tag == 273 else values
        code = {3: "H", 4: "I"}[kind]
        packed = struct.pack("<" + code * len(values), *values)
        if tag in layout:
            start = layout[tag] - base
            extra[start : start + len(packed)] = packed
            ifd += struct.pack("<HHII", tag, kind, len(values), layout[tag])
        else:
            ifd += struct.pack("<HHI", tag, kind, len(values)) + packed.ljust(4, b"\0")
    ifd += struct.pack("<I", 0)
    with open(path, "wb") as handle:
        handle.write(b"II*\0" + struct.pack("<I", 8) + ifd + bytes(extra))
        for s in strips:
            handle.write(s)


def write_jpeg(path, rgb01, quality=95):
    Image.fromarray(np.round(np.clip(rgb01, 0, 1) * 255).astype(np.uint8)).save(path, "JPEG", quality=quality, subsampling=0)


def resize(rgb, width, height, linear=True):
    """Resizes an sRGB float image, in linear light by default, with Pillow's Lanczos filter per channel."""
    source = srgb_to_linear(rgb) if linear else rgb
    channels = [np.asarray(Image.fromarray(source[..., c].astype(np.float32), "F").resize((width, height), Image.LANCZOS)) for c in range(3)]
    out = np.stack(channels, axis=2)
    return linear_to_srgb(np.clip(out, 0, None)) if linear else out


def resize_linear(lin, width, height, method=Image.LANCZOS):
    """Resizes a linear-light float image (any number of channels) with Pillow's float mode."""
    planes = lin if lin.ndim == 3 else lin[..., None]
    out = np.stack([np.asarray(Image.fromarray(planes[..., c].astype(np.float32), "F").resize((width, height), method)) for c in range(planes.shape[2])], axis=2)
    return out if lin.ndim == 3 else out[..., 0]
