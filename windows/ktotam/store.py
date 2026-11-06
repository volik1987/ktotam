"""База лиц на SQLite: users (люди) и samples (снимки лиц + векторы).

Кроп лица хранится целиком (JPEG), поэтому векторы можно пересчитать при смене модели.
"""
import os
import sqlite3
import sys
import time
from dataclasses import dataclass

import numpy as np


@dataclass
class Person:
    id: int
    name: str
    count: int


@dataclass
class Sample:
    id: int
    user_id: int
    emb: np.ndarray
    version: int


def data_dir() -> str:
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.path.expanduser("~")
        d = os.path.join(base, "Ktotam")
    elif sys.platform == "darwin":
        d = os.path.expanduser("~/Library/Application Support/KtotamPy")
    else:
        d = os.path.expanduser("~/.local/share/ktotam")
    os.makedirs(d, exist_ok=True)
    return d


def default_db() -> str:
    return os.path.join(data_dir(), "faces.sqlite")


class Store:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created REAL);
            CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                emb BLOB, version INTEGER, jpeg BLOB, created REAL, source TEXT);
            CREATE INDEX IF NOT EXISTS samples_user ON samples(user_id);
        """)
        self.db.commit()

    # --- люди
    def people(self) -> list[Person]:
        rows = self.db.execute("""
            SELECT u.id, u.name, (SELECT COUNT(*) FROM samples s WHERE s.user_id=u.id)
            FROM users u ORDER BY u.name COLLATE NOCASE""").fetchall()
        return [Person(*r) for r in rows]

    def add_person(self, name: str) -> int:
        cur = self.db.execute("INSERT INTO users(name, created) VALUES(?, ?)", (name, time.time()))
        self.db.commit()
        return cur.lastrowid

    def rename(self, uid: int, name: str):
        self.db.execute("UPDATE users SET name=? WHERE id=?", (name, uid))
        self.db.commit()

    def delete_person(self, uid: int):
        self.db.execute("DELETE FROM users WHERE id=?", (uid,))
        self.db.commit()

    # --- образцы
    def add_sample(self, user: int, emb: np.ndarray, version: int, jpeg: bytes, source: str) -> int:
        cur = self.db.execute(
            "INSERT INTO samples(user_id, emb, version, jpeg, created, source) VALUES(?,?,?,?,?,?)",
            (user, np.asarray(emb, np.float32).tobytes(), version, jpeg, time.time(), source))
        self.db.commit()
        return cur.lastrowid

    def samples(self) -> list[Sample]:
        rows = self.db.execute("SELECT id, user_id, emb, version FROM samples").fetchall()
        return [Sample(r[0], r[1], np.frombuffer(r[2], np.float32), r[3]) for r in rows if r[2]]

    def thumbs(self, user: int, limit: int = 200) -> list[tuple[int, bytes]]:
        return self.db.execute("SELECT id, jpeg FROM samples WHERE user_id=? ORDER BY id DESC LIMIT ?",
                               (user, limit)).fetchall()

    def jpeg(self, sample: int) -> bytes | None:
        r = self.db.execute("SELECT jpeg FROM samples WHERE id=?", (sample,)).fetchone()
        return r[0] if r else None

    def update_emb(self, sample: int, emb: np.ndarray, version: int):
        self.db.execute("UPDATE samples SET emb=?, version=? WHERE id=?",
                        (np.asarray(emb, np.float32).tobytes(), version, sample))
        self.db.commit()

    def delete_sample(self, sid: int):
        self.db.execute("DELETE FROM samples WHERE id=?", (sid,))
        self.db.commit()

    def move_sample(self, sid: int, user: int):
        self.db.execute("UPDATE samples SET user_id=? WHERE id=?", (user, sid))
        self.db.commit()
