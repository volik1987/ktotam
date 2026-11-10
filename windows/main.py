"""«Кто там» для Windows: узнаёт, кто перед компьютером, и здоровается голосом.

Ключи запуска:
  --selftest [папка]       логика + модели + (если дана папка человек/ролик/кадры) точность
  --import <папка>         добавить в базу фото: папка/Имя/*.jpg
  --db <файл>              другая база
  --fake-camera <папка>    вместо камеры — фото из папки по кругу
  --mute                   не говорить вслух (события печатаются в консоль)
  --test-fix <имя>         через 3 с поправить лицо в кадре на этого человека
  --snapshot <png> <сек>   снимок окна через N секунд и выход
  --log <файл>             весь вывод в файл (у собранного .exe нет консоли)
  --tab <номер>            открыть вкладку справа (0 — «Люди», 4 — «Б24»)
"""
import argparse
import os
import sys


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--selftest", nargs="?", const="", default=None)
    ap.add_argument("--import", dest="imp")
    ap.add_argument("--db")
    ap.add_argument("--fake-camera")
    ap.add_argument("--mute", action="store_true")
    ap.add_argument("--test-fix")
    ap.add_argument("--snapshot", nargs=2, metavar=("PNG", "SEC"))
    ap.add_argument("--log")
    ap.add_argument("--tab", type=int)
    a, _ = ap.parse_known_args()

    if a.log:
        f = open(a.log, "w", encoding="utf-8", buffering=1)
        sys.stdout = sys.stderr = f
    elif sys.stdout is None:            # .exe без консоли
        sys.stdout = sys.stderr = open(os.devnull, "w")
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

    from ktotam.store import default_db
    db = a.db or default_db()

    if a.selftest is not None:
        from ktotam import selftest
        sys.exit(0 if selftest.run(a.selftest or None) else 1)
    if a.imp:
        from ktotam import selftest
        sys.exit(0 if selftest.import_folder(a.imp, db) else 1)

    import tkinter as tk
    from ktotam.camera import Camera
    from ktotam.engine import FaceEngine
    from ktotam.model import Model
    from ktotam.ui import App

    if sys.platform == "win32":
        try:                              # чёткий текст на экранах с масштабом 125–200%
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    engine = FaceEngine()
    root = tk.Tk()
    model = Model(db, engine, mute=a.mute)
    app = App(root, model, Camera(engine), fake_folder=a.fake_camera)
    if a.tab is not None:
        app.nb.select(a.tab)

    if a.test_fix:
        def fix():
            f = model.faces[0] if model.faces else None
            p = next((p for p in model.people if p.name == a.test_fix), None)
            if not f or not p:
                print("тест: нет лица", flush=True)
                return
            print(f"тест: было «{model.name(f.label)}», поправляю на «{a.test_fix}»", flush=True)
            model.assign(("live", f.id), p.id)
            root.after(1500, lambda: print(f"тест: теперь «{','.join(model.name(x.label) for x in model.faces)}», "
                                           f"перед компом: {model.present_names}", flush=True))
        root.after(3000, fix)

    if a.snapshot:
        path, secs = a.snapshot[0], float(a.snapshot[1])
        if sys.platform == "darwin":
            # Окно Python само не становится активным (Stage Manager прячет его в полосу миниатюр).
            def front():
                root.lift()
                root.attributes("-topmost", True)
                root.focus_force()
                from ktotam.snap_mac import activate
                activate()
            root.after(300, front)

        def snap():
            root.update()
            try:
                if sys.platform == "darwin":
                    from ktotam.snap_mac import grab_own_window
                    img = grab_own_window()
                else:
                    from PIL import ImageGrab
                    x, y = root.winfo_rootx(), root.winfo_rooty()
                    img = ImageGrab.grab(bbox=(x, y, x + root.winfo_width(), y + root.winfo_height()))
                if img is not None:
                    img.save(path)
                    print("snapshot:", path, flush=True)
            except Exception as e:
                print("snapshot error:", e, flush=True)
            app.close()
        root.after(int(secs * 1000), snap)

    root.mainloop()


if __name__ == "__main__":
    main()
