"""Поиск лиц (YuNet) + выравнивание + вектор лица (SFace) — модели OpenCV Zoo.

SFace — настоящая модель распознавания лиц (128 чисел на лицо), она заметно лучше
отличает незнакомцев, чем общий «отпечаток картинки» в macOS-версии.
"""
import os
import sys
from dataclasses import dataclass

import cv2
import numpy as np


def resource(*parts) -> str:
    """Путь к файлу рядом с программой (и внутри собранного PyInstaller .exe)."""
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return os.path.join(base, *parts)


@dataclass
class FaceHit:
    rect: tuple[float, float, float, float]   # x, y, w, h — доли кадра, начало сверху слева
    crop: np.ndarray                          # выровненное лицо 112×112 BGR
    emb: np.ndarray                           # вектор (L2 = 1)
    yaw: float                                # грубая оценка поворота головы (0 — анфас)
    px: float                                 # ширина лица в пикселях


class FaceEngine:
    VERSION = 101            # 1xx — SFace; при смене модели база пересчитывается из кропов

    def __init__(self, models_dir: str | None = None):
        md = models_dir or resource("models")
        self.det = cv2.FaceDetectorYN.create(os.path.join(md, "face_detection_yunet_2023mar.onnx"), "",
                                             (320, 320), 0.8, 0.3, 50)
        self.rec = cv2.FaceRecognizerSF.create(os.path.join(md, "face_recognition_sface_2021dec.onnx"), "")
        self.min_face = 0.06      # минимальная ширина лица, доля кадра
        self.detect_width = 640   # поиск лиц на уменьшенном кадре — быстрее

    def detect(self, bgr: np.ndarray) -> np.ndarray:
        h, w = bgr.shape[:2]
        scale = min(1.0, self.detect_width / w)
        small = cv2.resize(bgr, (int(w * scale), int(h * scale))) if scale < 1 else bgr
        self.det.setInputSize((small.shape[1], small.shape[0]))
        _, faces = self.det.detect(small)
        if faces is None:
            return np.zeros((0, 15), np.float32)
        faces = faces.copy()
        faces[:, :14] /= scale
        return faces

    def embedding(self, crop: np.ndarray) -> np.ndarray:
        e = self.rec.feature(crop).flatten().astype(np.float32)
        n = float(np.linalg.norm(e))
        return e / n if n > 0 else e

    @staticmethod
    def yaw(f: np.ndarray) -> float:
        # Точки YuNet: правый глаз, левый глаз, нос, углы рта. Смещение носа от середины глаз.
        rx, lx, nx = f[4], f[6], f[8]
        d = abs(lx - rx)
        return float((nx - (rx + lx) / 2) / d) if d > 1 else 0.0

    def analyze(self, bgr: np.ndarray, min_face: float | None = None) -> list[FaceHit]:
        h, w = bgr.shape[:2]
        mf = self.min_face if min_face is None else min_face
        out = []
        for f in self.detect(bgr):
            fw = float(f[2])
            if fw / w < mf or fw < 36:
                continue
            crop = self.rec.alignCrop(bgr, f)
            out.append(FaceHit((f[0] / w, f[1] / h, f[2] / w, f[3] / h), crop, self.embedding(crop),
                               self.yaw(f), fw))
        return out

    def largest_face(self, bgr: np.ndarray) -> FaceHit | None:
        hits = self.analyze(bgr, min_face=0.02)
        return max(hits, key=lambda x: x.px) if hits else None

    @staticmethod
    def jpeg(img: np.ndarray, quality: int = 88) -> bytes:
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
        return buf.tobytes() if ok else b""

    @staticmethod
    def from_jpeg(data: bytes) -> np.ndarray | None:
        return cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR) if data else None


def imread(path: str) -> np.ndarray | None:
    """cv2.imread не понимает кириллицу в путях на Windows — читаем байты сами."""
    try:
        data = np.fromfile(path, np.uint8)
    except OSError:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR) if data.size else None
