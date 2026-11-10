"""Состояние приложения: база, узнавание, треки, приветствия, поправки. Без интерфейса."""
import json
import os
import time
import uuid
from dataclasses import dataclass, field

import numpy as np

from .b24 import B24Client
from .brain import UNKNOWN, Match, Presence, Recognizer, Tracker
from .engine import FaceEngine, FaceHit
from .speaker import Speaker
from .store import Store, data_dir


@dataclass
class LiveFace:
    id: int
    rect: tuple
    label: int | None
    match: Match
    crop: np.ndarray
    emb: np.ndarray


@dataclass
class Review:
    crop: np.ndarray
    emb: np.ndarray
    match: Match
    time: float
    resolved: str | None = None
    id: str = field(default_factory=lambda: uuid.uuid4().hex)


DEFAULTS = {"threshold": 0.95, "absence": 3.0, "speak": True, "greet_unknown": False,
            "auto_learn": False, "mirror": True, "voice": "", "camera": "0",
            "b24_url": "", "b24_device": "", "b24_token": "", "b24_user": 0, "b24_user_name": ""}


class Model:
    def __init__(self, db_path: str, engine: FaceEngine, mute: bool = False, b24: bool = True):
        self.store = Store(db_path)
        self.engine = engine
        self.rec = Recognizer()
        self.tracker = Tracker()
        self.presence = Presence()
        self.speaker = Speaker()
        self.mute = mute
        self.faces: list[LiveFace] = []
        self.people = []
        self.reviews: list[Review] = []
        self.events: list[tuple[float, str]] = []
        self.enroll_user: int | None = None
        self.enroll_left = 0
        self.enroll_total = 20
        self.revision = 0
        self._last_enroll = 0.0
        self._last_auto: dict[int, float] = {}
        self.review_every = 8.0
        self.settings_path = os.path.join(data_dir(), "settings.json")
        self.s = dict(DEFAULTS)
        try:
            with open(self.settings_path, encoding="utf-8") as f:
                self.s.update(json.load(f))
        except (OSError, ValueError):
            pass
        self.apply_settings()
        self.b24 = B24Client(self.s, self.set) if b24 else None
        self.refresh_people()
        self._migrate()
        self.rec.rebuild(self.store.samples())

    # --- настройки
    def set(self, key, value):
        self.s[key] = value
        self.apply_settings()
        try:
            with open(self.settings_path, "w", encoding="utf-8") as f:
                json.dump(self.s, f, ensure_ascii=False, indent=1)
        except OSError:
            pass

    def apply_settings(self):
        self.rec.threshold = float(self.s["threshold"])
        self.presence.absence = float(self.s["absence"])
        self.speaker.voice = self.s["voice"]

    def _migrate(self):
        for sm in self.store.samples():
            if sm.version != FaceEngine.VERSION:
                img = FaceEngine.from_jpeg(self.store.jpeg(sm.id))
                if img is not None and img.shape[:2] == (112, 112):
                    self.store.update_emb(sm.id, self.engine.embedding(img), FaceEngine.VERSION)

    def refresh_people(self):
        self.people = self.store.people()
        self.revision += 1
        if self.b24:
            self.b24.set_persons([{"name": p.name, "user": p.b24, "samples": p.count} for p in self.people])

    def b24_of(self, uid) -> int:
        return next((p.b24 for p in self.people if p.id == uid), 0)

    def link_b24(self, uid: int, b24: int):
        """Связать человека из базы с сотрудником портала (0 — отвязать)."""
        self.store.set_b24(uid, b24)
        self.refresh_people()

    def tick_b24(self):
        """Из потока интерфейса: проговорить пришедшие с портала сообщения, перенести заметки в журнал."""
        if not self.b24:
            return
        try:
            while True:
                self.log(self.b24.notes.get_nowait())
        except Exception:
            pass
        try:
            while True:
                text = self.b24.inbox.get_nowait()
                self.log("🔊 " + text)
                if not self.mute:
                    self.speaker.say(text)
        except Exception:
            pass

    def name(self, uid) -> str:
        if uid is None:
            return "?"
        if uid == UNKNOWN:
            return "незнакомец"
        return next((p.name for p in self.people if p.id == uid), "?")

    @property
    def present_names(self) -> list[str]:
        return sorted(self.name(u) for u in self.presence.present if u > 0)

    def log(self, text: str):
        print(f"{time.monotonic() % 1000:.1f} событие: {text}", flush=True)
        self.events.insert(0, (time.time(), text))
        del self.events[300:]

    # --- кадр
    def ingest(self, hits: list[FaceHit], now: float):
        tracks = self.tracker.update([h.rect for h in hits], now)
        live = []
        thr = float(self.s["threshold"])
        for h, t in zip(hits, tracks):
            m = self.rec.match(h.emb)
            t.hit, t.match = h, m
            t.vote(m.best if m.known else UNKNOWN)
            if t.pinned is not None and t.boost_left > 0 and now - t.last_boost > 0.4 and abs(h.yaw) < 0.35:
                t.last_boost = now
                t.boost_left -= 1
                self._add(h.crop, h.emb, t.pinned, "fix+", refresh=t.boost_left == 0)
            live.append(LiveFace(t.id, h.rect, t.label, m, h.crop, h.emb))
            if t.label is not None and now - t.last_snap > self.review_every and abs(h.yaw) < 0.35:
                t.last_snap = now
                self.reviews.insert(0, Review(h.crop, h.emb, m, time.time()))
                del self.reviews[120:]
            if (self.s["auto_learn"] and m.known and t.label == m.best and m.dist < thr * 0.8
                    and now - self._last_auto.get(m.best, 0) > 5 and abs(h.yaw) < 0.25):
                self._last_auto[m.best] = now
                self._add(h.crop, h.emb, m.best, "auto", refresh=False)

        if self.enroll_user is not None and self.enroll_left > 0 and now - self._last_enroll > 0.25 and hits:
            i = max(range(len(hits)), key=lambda k: hits[k].px)
            if abs(hits[i].yaw) < 0.5:
                self._last_enroll = now
                self._add(hits[i].crop, hits[i].emb, self.enroll_user, "enroll", refresh=False)
                tracks[i].force(self.enroll_user)
                self.enroll_left -= 1
                if self.enroll_left == 0:
                    u = self.enroll_user
                    self.enroll_user = None
                    self.refresh_people()
                    self.log(f"Серия снимков для «{self.name(u)}» готова")
        self.faces = live

        visible = set()
        for t in self.tracker.tracks:
            if t.label is not None and (t.label > 0 or (t.label == UNKNOWN and self.s["greet_unknown"])):
                visible.add(t.label)
        hello, bye = self.presence.step(visible, now)
        for u in bye:
            self._greet(u, False)
        for u in hello:
            self._greet(u, True)
        if self.b24:
            self.b24.set_present(self.b24_of(u) for u in self.presence.present if u > 0)

    def _greet(self, u: int, hello: bool):
        who = self.name(u)
        text = f"Привет, {who}!" if hello else f"Пока, {who}!"
        self.log(("👋 " if hello else "🚪 ") + text)
        if self.s["speak"] and not self.mute:
            self.speaker.say(text)
        if self.b24:
            b24 = self.b24_of(u) if u > 0 else 0
            self.b24.event("appeared" if hello else "left", b24, who if u > 0 else "")

    # --- обучение
    def _add(self, crop, emb, u: int, source: str, refresh: bool = True):
        self.store.add_sample(u, emb, FaceEngine.VERSION, FaceEngine.jpeg(crop), source)
        self.rec.add(emb, u)
        if refresh:
            self.refresh_people()

    def _face_for(self, target):
        kind, key = target
        if kind == "live":
            f = next((f for f in self.faces if f.id == key), None)
            return (f.crop, f.emb, f.match) if f else None
        if kind == "review":
            r = next((r for r in self.reviews if r.id == key), None)
            return (r.crop, r.emb, r.match) if r else None
        return None

    def confirm(self, target):
        f = self._face_for(target)
        if f and f[2].best is not None:
            self.assign(target, f[2].best)

    def assign(self, target, u: int):
        f = self._face_for(target)
        if not f:
            return
        crop, emb, m = f
        self._add(crop, emb, u, "confirm" if m.best == u else "fix")
        kind, key = target
        if kind == "live":
            t = next((t for t in self.tracker.tracks if t.id == key), None)
            if t:
                old = t.label
                t.force(u, pin=True)
                t.boost_left = 2 if m.best == u else 6
                t.last_boost = time.monotonic()
                if old is not None and old != u and not any(o is not t and o.label == old for o in self.tracker.tracks):
                    self.presence.forget(old)
        elif kind == "review":
            for r in self.reviews:
                if r.id == key:
                    r.resolved = ("✓ " if m.best == u else "→ ") + self.name(u)
        if m.best != u:
            self.log(f"Поправка: это «{self.name(u)}», а не «{self.name(m.best)}»")

    def dismiss(self, rid: str):
        for r in self.reviews:
            if r.id == rid:
                r.resolved = "✗ пропущено"

    def add_person(self, name: str, target=("none", None)):
        n = (name or "").strip()
        if not n:
            return None
        uid = self.store.add_person(n)
        self.refresh_people()
        self.log(f"Новый человек: «{n}»")
        if target[0] != "none":
            self.assign(target, uid)
        return uid

    def rename(self, uid: int, name: str):
        n = name.strip()
        if n:
            self.store.rename(uid, n)
            self.refresh_people()

    def delete_person(self, uid: int):
        self.store.delete_person(uid)
        self.presence.forget(uid)
        for t in self.tracker.tracks:
            if t.label == uid:
                t.votes, t.label, t.pinned = [], None, None
        self.rec.rebuild(self.store.samples())
        self.refresh_people()

    def delete_sample(self, sid: int):
        self.store.delete_sample(sid)
        self.rec.rebuild(self.store.samples())
        self.refresh_people()

    def move_sample(self, sid: int, u: int):
        self.store.move_sample(sid, u)
        self.rec.rebuild(self.store.samples())
        self.refresh_people()

    def start_enroll(self, u: int, count: int = 20):
        self.enroll_user, self.enroll_left, self.enroll_total = u, count, count
        self.log(f"Снимаю серию для «{self.name(u)}»: смотрите в камеру, поворачивайте голову")

    def stop_enroll(self):
        self.enroll_user, self.enroll_left = None, 0
        self.refresh_people()
