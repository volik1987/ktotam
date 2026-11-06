"""Источник кадров в отдельном потоке: веб-камера, IP-камера (rtsp://…) или папка с фото (тест).

Поток сам ищет лица и считает векторы; в интерфейс отдаёт только последний результат.
"""
import os
import queue
import sys
import threading
import time

import cv2
import numpy as np

from .engine import FaceEngine, imread


class Camera:
    def __init__(self, engine: FaceEngine):
        self.engine = engine
        self.out: queue.Queue = queue.Queue(maxsize=2)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.error = ""

    def start(self, source: str = "0", fake_folder: str | None = None):
        self.stop()
        self._stop.clear()
        self.error = ""
        target = self._run_fake if fake_folder else self._run_cam
        self._thread = threading.Thread(target=target, args=(fake_folder or source,), daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2)
        self._thread = None

    def _emit(self, bgr: np.ndarray):
        hits = self.engine.analyze(bgr)
        h, w = bgr.shape[:2]
        scale = min(1.0, 960 / w)
        shown = cv2.resize(bgr, (int(w * scale), int(h * scale))) if scale < 1 else bgr
        item = (cv2.cvtColor(shown, cv2.COLOR_BGR2RGB), hits, time.monotonic())
        try:
            self.out.put_nowait(item)
        except queue.Full:
            try:
                self.out.get_nowait()
            except queue.Empty:
                pass
            self.out.put_nowait(item)

    def _open(self, source: str):
        if source.isdigit():
            idx = int(source)
            if sys.platform == "win32":
                cap = cv2.VideoCapture(idx, cv2.CAP_DSHOW)   # DirectShow открывается быстрее MSMF
                if not cap.isOpened():
                    cap = cv2.VideoCapture(idx)
            else:
                cap = cv2.VideoCapture(idx)
            cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
            cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
        else:
            cap = cv2.VideoCapture(source)                   # rtsp://… или файл видео
        return cap

    def _run_cam(self, source: str):
        cap = self._open(source)
        if not cap.isOpened():
            self.error = f"Камера «{source}» не открылась"
            return
        fails = 0
        while not self._stop.is_set():
            ok, frame = cap.read()
            if not ok or frame is None:
                fails += 1
                if fails > 50:
                    self.error = "Камера перестала отдавать кадры"
                    break
                time.sleep(0.05)
                continue
            fails = 0
            self._emit(frame)
        cap.release()

    def _run_fake(self, folder: str, fps: float = 5):
        """Фото из папки по кругу; файл с «_empty» в имени — кадр без людей."""
        files = sorted(f for f in os.listdir(folder)
                       if f.lower().endswith((".jpg", ".jpeg", ".png")) or "_empty" in f)
        blank = np.full((720, 1280, 3), 128, np.uint8)
        i = 0
        time.sleep(0.3)
        while files and not self._stop.is_set():
            t0 = time.monotonic()
            f = files[i % len(files)]
            i += 1
            img = None if "_empty" in f else imread(os.path.join(folder, f))
            self._emit(blank if img is None else img)
            time.sleep(max(0, 1 / fps - (time.monotonic() - t0)))
