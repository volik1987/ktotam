"""Логика без интерфейса: узнавание ближайшими соседями, трекер лиц, присутствие (привет/пока)."""
from collections import Counter
from dataclasses import dataclass

import numpy as np

UNKNOWN = -1


@dataclass
class Match:
    best: int | None = None    # ближайший человек (даже если не уверены)
    dist: float = 9.0          # расстояние до него (меньше — похожее)
    second: float = 9.0        # до следующего человека
    known: bool = False        # уверенно узнан


class Recognizer:
    """Для каждого человека — среднее k ближайших его снимков; дальше порога — «не знаю»."""

    def __init__(self, threshold: float = 1.0, margin: float = 0.03, k: int = 3, max_per_user: int = 400):
        self.threshold, self.margin, self.k, self.max_per_user = threshold, margin, k, max_per_user
        self.by_user: dict[int, np.ndarray] = {}

    def rebuild(self, samples):
        m: dict[int, list] = {}
        for s in samples:
            if len(s.emb):
                m.setdefault(s.user_id, []).append(s.emb)
        self.by_user = {u: np.stack(v[-self.max_per_user:]) for u, v in m.items()}

    def add(self, emb: np.ndarray, user: int):
        cur = self.by_user.get(user)
        arr = emb[None, :] if cur is None else np.vstack([cur, emb])[-self.max_per_user:]
        self.by_user[user] = arr

    def score(self, emb: np.ndarray, mat: np.ndarray) -> float:
        d = np.sqrt(np.maximum(0, ((mat - emb) ** 2).sum(1)))
        kk = min(self.k, len(d))
        return float(np.partition(d, kk - 1)[:kk].mean())

    def match(self, emb: np.ndarray) -> Match:
        if not self.by_user:
            return Match()
        scores = sorted(((self.score(emb, mat), u) for u, mat in self.by_user.items()))
        best_d, best_u = scores[0]
        second = scores[1][0] if len(scores) > 1 else 9.0
        known = best_d <= self.threshold and (second - best_d) >= self.margin
        return Match(best_u, best_d, second, known)


class Track:
    """Лицо, которое ведём от кадра к кадру. Метка устойчива: решает большинство последних кадров."""

    def __init__(self, tid: int, rect, now: float):
        self.id, self.rect, self.last_seen = tid, rect, now
        self.votes: list[int] = []
        self.label: int | None = None     # None — ещё думаем, -1 — незнакомец
        self.hit = None
        self.match = Match()
        self.last_snap = 0.0
        self.pinned: int | None = None    # имя закреплено поправкой пользователя
        self.boost_left = 0
        self.last_boost = 0.0

    def vote(self, v: int):
        if self.pinned is not None:
            self.label = self.pinned
            return
        self.votes.append(v)
        self.votes = self.votes[-8:]
        cnt = Counter(self.votes)
        top, n = cnt.most_common(1)[0]
        if len(self.votes) >= 3 and n * 2 > len(self.votes):
            self.label = top
        elif self.label is not None and cnt[self.label] < 2:
            self.label = None

    def force(self, v: int, pin: bool = False):
        self.votes = [v] * 6
        self.label = v
        if pin:
            self.pinned = v


def iou(a, b) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ix = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    iy = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    i = ix * iy
    u = aw * ah + bw * bh - i
    return i / u if u > 0 else 0.0


class Tracker:
    def __init__(self, lost_after: float = 0.8):
        self.tracks: list[Track] = []
        self.next_id = 1
        self.lost_after = lost_after

    def update(self, rects, now: float) -> list[Track]:
        free = set(range(len(self.tracks)))
        result = []
        for r in rects:
            best_i, best_v = -1, 0.15
            for i in free:
                t = self.tracks[i]
                v = iou(t.rect, r)
                if v < 0.15:
                    dc = np.hypot(t.rect[0] + t.rect[2] / 2 - r[0] - r[2] / 2, t.rect[1] + t.rect[3] / 2 - r[1] - r[3] / 2)
                    if dc < max(t.rect[2], r[2]) * 0.6:
                        v = 0.16
                if v > best_v:
                    best_v, best_i = v, i
            if best_i >= 0:
                free.discard(best_i)
                t = self.tracks[best_i]
                t.rect, t.last_seen = r, now
            else:
                t = Track(self.next_id, r, now)
                self.next_id += 1
                self.tracks.append(t)
            result.append(t)
        self.tracks = [t for t in self.tracks if now - t.last_seen <= self.lost_after]
        return result


class Presence:
    """Здороваемся при появлении, прощаемся после паузы отсутствия."""

    def __init__(self, absence: float = 3.0):
        self.absence = absence
        self.last_seen: dict[int, float] = {}

    @property
    def present(self) -> set[int]:
        return set(self.last_seen)

    def step(self, visible: set[int], now: float):
        hello = sorted(u for u in visible if u not in self.last_seen)
        for u in visible:
            self.last_seen[u] = now
        bye = sorted(u for u, t in self.last_seen.items() if now - t > self.absence)
        for u in bye:
            del self.last_seen[u]
        return hello, bye

    def forget(self, u: int):
        self.last_seen.pop(u, None)
