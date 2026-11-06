"""Только для разработки на маке: снимок своего окна через CGWindowListCreateImage (без прав на запись экрана)."""
import ctypes
import os

from PIL import Image

cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
vp = ctypes.c_void_p
for fn, res, args in [
    (cg.CGWindowListCopyWindowInfo, vp, [ctypes.c_uint32, ctypes.c_uint32]),
    (cf.CFArrayGetCount, ctypes.c_long, [vp]),
    (cf.CFArrayGetValueAtIndex, vp, [vp, ctypes.c_long]),
    (cf.CFDictionaryGetValue, vp, [vp, vp]),
    (cf.CFNumberGetValue, ctypes.c_bool, [vp, ctypes.c_int, vp]),
    (cg.CGImageGetWidth, ctypes.c_size_t, [vp]),
    (cg.CGImageGetHeight, ctypes.c_size_t, [vp]),
    (cg.CGImageGetBytesPerRow, ctypes.c_size_t, [vp]),
    (cg.CGImageGetDataProvider, vp, [vp]),
    (cg.CGDataProviderCopyData, vp, [vp]),
    (cf.CFDataGetBytePtr, vp, [vp]),
    (cf.CFDataGetLength, ctypes.c_long, [vp]),
    (cf.CFRelease, None, [vp]),
]:
    fn.restype, fn.argtypes = res, args


class CGRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


cg.CGWindowListCreateImage.restype = vp
cg.CGWindowListCreateImage.argtypes = [CGRect, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32]


def _num(d, key) -> int:
    v = cf.CFDictionaryGetValue(d, vp.in_dll(cg, key))
    out = ctypes.c_int64(0)
    if v:
        cf.CFNumberGetValue(v, 4, ctypes.byref(out))   # kCFNumberSInt64Type
    return out.value


def grab_own_window():
    arr = cg.CGWindowListCopyWindowInfo(1 | 16, 0)     # на экране, без рабочего стола
    best, area = None, 0
    for i in range(cf.CFArrayGetCount(arr)):
        d = cf.CFArrayGetValueAtIndex(arr, i)
        if _num(d, "kCGWindowOwnerPID") == os.getpid() and _num(d, "kCGWindowLayer") == 0:
            wid = _num(d, "kCGWindowNumber")
            best = best or wid
            area = area
    cf.CFRelease(arr)
    if not best:
        return None
    null = CGRect(float("inf"), float("inf"), 0, 0)    # CGRectNull
    img = cg.CGWindowListCreateImage(null, 8, best, 1 | 8)   # IncludingWindow; IgnoreFraming|BestResolution
    if not img:
        return None
    w, h, bpr = cg.CGImageGetWidth(img), cg.CGImageGetHeight(img), cg.CGImageGetBytesPerRow(img)
    data = cg.CGDataProviderCopyData(cg.CGImageGetDataProvider(img))
    buf = ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data))
    cf.CFRelease(data)
    cf.CFRelease(img)
    return Image.frombuffer("RGBA", (w, h), buf, "raw", "BGRA", bpr, 1).convert("RGB")


def activate():
    """[[NSApplication sharedApplication] activateIgnoringOtherApps:YES] — вывести окно Tk вперёд."""
    objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
    objc.objc_getClass.restype = vp
    objc.sel_registerName.restype = vp
    send = objc.objc_msgSend
    send.restype = vp
    send.argtypes = [vp, vp]
    app = send(objc.objc_getClass(b"NSApplication"), objc.sel_registerName(b"sharedApplication"))
    send2 = ctypes.CFUNCTYPE(vp, vp, vp, ctypes.c_bool)(ctypes.cast(objc.objc_msgSend, vp).value)
    send2(app, objc.sel_registerName(b"activateIgnoringOtherApps:"), True)
