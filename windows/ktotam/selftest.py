"""Автотест без камеры и окна + импорт фото в базу."""
import os
import tempfile

import numpy as np

from .brain import UNKNOWN, Presence, Recognizer, Track, Tracker
from .store import Sample, Store

IMG_EXT = (".jpg", ".jpeg", ".png", ".bmp")
fails = 0


def check(ok: bool, what: str):
    global fails
    print(("  ок   " if ok else "  ОШИБКА ") + what, flush=True)
    if not ok:
        fails += 1


def run(folder: str | None) -> bool:
    print("== Логика")
    logic()
    print("== База")
    store_test()
    print("== Модели")
    models_test()
    if folder:
        print(f"== Узнавание по папке {folder}")
        accuracy(folder)
    print("ВСЁ ХОРОШО" if fails == 0 else f"ОШИБОК: {fails}", flush=True)
    return fails == 0


def logic():
    t = Track(1, (0, 0, 0, 0), 0)
    for v in (5, 5, 5):
        t.vote(v)
    check(t.label == 5, "трек определился после 3 одинаковых кадров")
    t.vote(7)
    check(t.label == 5, "один чужой кадр метку не меняет")
    for _ in range(6):
        t.vote(7)
    check(t.label == 7, "устойчиво другой — метка сменилась")
    t.force(9)
    check(t.label == 9, "поправка пользователя применяется сразу")
    t.force(4, pin=True)
    for _ in range(8):
        t.vote(7)
    check(t.label == 4, "закреплённое поправкой имя держится, пока лицо в кадре")

    p = Presence(3)
    h, b = p.step({1}, 0)
    check(h == [1] and not b, "привет при появлении")
    h, b = p.step(set(), 2)
    check(not b, "пропал на 2 с — не прощаемся")
    h, b = p.step({1}, 2.5)
    check(not h, "вернулся быстро — второй раз не здороваемся")
    h, b = p.step({2}, 6)
    check(h == [2] and b == [1], "второй пришёл, первый ушёл")
    p.forget(2)
    h, b = p.step(set(), 20)
    check(not b, "ошибочно узнанного не провожаем")

    tr = Tracker()
    a = tr.update([(0.4, 0.4, 0.2, 0.2)], 0)[0]
    b2 = tr.update([(0.43, 0.41, 0.2, 0.2)], 0.1)[0]
    check(a is b2, "трекер ведёт сдвинувшееся лицо")
    tr.update([], 2)
    check(not tr.tracks, "трек исчезает, когда лица нет")

    def v(x, y):
        a = np.array([x, y], np.float32)
        return a / np.linalg.norm(a)
    rec = Recognizer(threshold=0.5, margin=0.015)
    rec.rebuild([Sample(1, 1, v(1, 0), 0), Sample(2, 1, v(1, 0.1), 0), Sample(3, 2, v(0, 1), 0)])
    m = rec.match(v(1, 0.05))
    check(m.best == 1 and m.known, "узнаёт ближайшего")
    check(not rec.match(v(1, 1)).known, "посередине — «не знаю»")


def store_test():
    path = os.path.join(tempfile.gettempdir(), f"ktotam-test-{os.getpid()}.sqlite")
    try:
        s = Store(path)
        a, b = s.add_person("Вася"), s.add_person("Петя")
        sid = s.add_sample(a, np.array([0.6, 0.8], np.float32), 1, b"\x01\x02", "t")
        check(next(p for p in s.people() if p.id == a).count == 1, "снимок сохранён")
        s.move_sample(sid, b)
        sm = s.samples()[0]
        check(sm.user_id == b and np.allclose(sm.emb, [0.6, 0.8]), "перенос снимка, вектор цел")
        s.rename(b, "Пётр")
        check(any(p.name == "Пётр" for p in s.people()), "переименование")
        s.delete_person(b)
        check(not s.samples(), "удаление человека удаляет снимки")
        s.db.close()
    finally:
        if os.path.exists(path):
            os.remove(path)


def models_test():
    from .engine import FaceEngine
    eng = FaceEngine()
    blank = np.full((720, 1280, 3), 128, np.uint8)
    check(eng.analyze(blank) == [], "модели загружены, на пустом кадре лиц нет")
    crop = np.random.default_rng(1).integers(0, 255, (112, 112, 3), dtype=np.uint8)
    e = eng.embedding(crop)
    check(e.shape == (128,) and abs(float(np.linalg.norm(e)) - 1) < 1e-4, "вектор лица: 128 чисел, длина 1")


def _subdirs(p):
    return sorted(os.path.join(p, d) for d in os.listdir(p)
                  if os.path.isdir(os.path.join(p, d)) and not d.startswith("_"))


def _images(p):
    return sorted(os.path.join(p, f) for f in os.listdir(p) if f.lower().endswith(IMG_EXT))


def accuracy(folder: str):
    """Папка человек/ролик/кадры. У кого несколько роликов — учим на первом, узнаём на остальных;
    у кого один — учим на первой половине, узнаём на второй. Плюс «незнакомцы»."""
    from .engine import FaceEngine, imread
    eng = FaceEngine()
    names, train, same, cross = {}, [], [], []
    for uid, p in enumerate(_subdirs(folder), 1):
        names[uid] = os.path.basename(p)
        clips = _subdirs(p) or [p]
        line = f"  {names[uid]}:"
        for ci, c in enumerate(clips):
            embs = []
            for f in _images(c):
                img = imread(f)
                h = eng.largest_face(img) if img is not None else None
                if h is not None:
                    embs.append(Sample(len(embs), uid, h.emb, FaceEngine.VERSION))
            line += f" {os.path.basename(c)}={len(embs)}"
            if len(clips) == 1:
                train += embs[:len(embs) // 2]
                same += embs[len(embs) // 2:]
            elif ci == 0:
                train += embs
            else:
                cross += embs
        print(line, flush=True)
    if len(names) < 2:
        print("  нужно минимум 2 человека")
        return
    q = lambda a, p: float(np.quantile(a, p)) if len(a) else 0.0
    rec = Recognizer(threshold=9, margin=0)
    rec.rebuild(train)

    def evaluate(data, title):
        if not data:
            return 1.0
        ok, ok_d, conf, vo, vn, window, prev = 0, [], {}, 0, 0, [], None
        for s in data:
            m = rec.match(s.emb)
            if m.best == s.user_id:
                ok += 1
                ok_d.append(m.dist)
            else:
                k = f"{names[s.user_id]}→{names.get(m.best, '?')}"
                conf[k] = conf.get(k, 0) + 1
            if s.user_id != prev:
                window, prev = [], s.user_id
            window = (window + [m.best])[-8:]
            if len(window) >= 3:
                vn += 1
                vo += max(set(window), key=window.count) == s.user_id
        acc = ok / len(data)
        print(f"  {title}: по кадру {acc * 100:.1f}% ({ok} из {len(data)}), с голосованием трека "
              f"{vo / max(vn, 1) * 100:.1f}%; расстояние до верного: медиана {q(ok_d, .5):.3f}, 90% {q(ok_d, .9):.3f}")
        if conf:
            print("    путает: " + ", ".join(f"{k} {v}" for k, v in sorted(conf.items(), key=lambda x: -x[1])[:8]))
        return acc

    acc_same = evaluate(same, "тот же ролик")
    acc_cross = evaluate(cross, "другой ролик")
    test = same + cross
    stranger = []
    for u in names:
        r2 = Recognizer(threshold=9, margin=0)
        r2.rebuild([s for s in train if s.user_id != u])
        stranger += [r2.match(s.emb).dist for s in test if s.user_id == u]
    known = [(m.dist, m.best == s.user_id) for s in test for m in [rec.match(s.emb)]]
    print("  порог → узнаёт своих верно / принимает чужого за своего:")
    for t in np.arange(0.8, 1.31, 0.05):
        a = sum(1 for d, ok in known if d <= t and ok) / len(known)
        far = sum(1 for d in stranger if d <= t) / max(len(stranger), 1)
        print(f"    {t:.2f} → {a * 100:5.1f}% / {far * 100:5.1f}%")
    check(acc_same >= 0.9, "тот же ролик ≥ 90%")
    check(acc_cross >= 0.8, "другой ролик ≥ 80%")


def import_folder(folder: str, db: str) -> bool:
    """Каждая подпапка — человек (имя = имя папки), фото можно класть и глубже."""
    from .engine import FaceEngine, imread
    eng = FaceEngine()
    st = Store(db)
    for p in _subdirs(folder):
        name = os.path.basename(p)
        uid = next((x.id for x in st.people() if x.name == name), None) or st.add_person(name)
        n = 0
        for root, _, files in os.walk(p):
            for f in sorted(files):
                if not f.lower().endswith(IMG_EXT):
                    continue
                img = imread(os.path.join(root, f))
                h = eng.largest_face(img) if img is not None else None
                if h is not None:
                    st.add_sample(uid, h.emb, FaceEngine.VERSION, eng.jpeg(h.crop), "import")
                    n += 1
        print(f"{name}: добавлено {n} лиц", flush=True)
    return True
