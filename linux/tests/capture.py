"""Capture an Xvfb root window using system Xlib and the Python standard library."""
import ctypes as c
from pathlib import Path
import struct
import zlib


class XImage(c.Structure):
    _fields_ = [("width", c.c_int), ("height", c.c_int), ("xoffset", c.c_int), ("format", c.c_int), ("data", c.c_void_p), ("byte_order", c.c_int), ("bitmap_unit", c.c_int), ("bitmap_bit_order", c.c_int), ("bitmap_pad", c.c_int), ("depth", c.c_int), ("bytes_per_line", c.c_int), ("bits_per_pixel", c.c_int), ("red_mask", c.c_ulong), ("green_mask", c.c_ulong), ("blue_mask", c.c_ulong)]


def capture(path):
    x = c.CDLL("libX11.so.6")
    x.XOpenDisplay.argtypes, x.XOpenDisplay.restype = [c.c_char_p], c.c_void_p
    x.XDefaultRootWindow.argtypes, x.XDefaultRootWindow.restype = [c.c_void_p], c.c_ulong
    x.XDefaultScreen.argtypes, x.XDefaultScreen.restype = [c.c_void_p], c.c_int
    x.XDisplayWidth.argtypes, x.XDisplayWidth.restype = [c.c_void_p, c.c_int], c.c_int
    x.XDisplayHeight.argtypes, x.XDisplayHeight.restype = [c.c_void_p, c.c_int], c.c_int
    x.XGetImage.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_ulong, c.c_int]
    x.XGetImage.restype = c.POINTER(XImage)
    x.XDestroyImage.argtypes = [c.POINTER(XImage)]
    x.XCloseDisplay.argtypes = [c.c_void_p]
    display = x.XOpenDisplay(None)
    if not display:
        raise RuntimeError("X11 display is unavailable")
    screen = x.XDefaultScreen(display)
    width, height = x.XDisplayWidth(display, screen), x.XDisplayHeight(display, screen)
    image = x.XGetImage(display, x.XDefaultRootWindow(display), 0, 0, width, height, c.c_ulong(-1), 2)
    try:
        info = image.contents
        assert info.bits_per_pixel == 32 and info.byte_order == 0
        data = c.string_at(info.data, info.bytes_per_line * height)
        pixels = bytearray()
        for row in range(height):
            pixels.append(0)
            start = row * info.bytes_per_line
            for col in range(width):
                offset = start + 4 * col
                pixels.extend((data[offset + 2], data[offset + 1], data[offset]))
        def chunk(kind, value):
            return struct.pack("!I", len(value)) + kind + value + struct.pack("!I", zlib.crc32(kind + value))
        Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    finally:
        x.XDestroyImage(image)
        x.XCloseDisplay(display)
