"""Окно «Кто там» на Tk: камера с рамками, лица в кадре с кнопками поправки, люди, проверка, журнал, настройки."""
import os
import queue
import sys
import time
import tkinter as tk
from tkinter import messagebox, simpledialog, ttk

import cv2
from PIL import Image, ImageTk

from .brain import UNKNOWN
from .camera import Camera
from .engine import resource
from .model import Model

PALETTE = ["#34a853", "#4285f4", "#f5a623", "#9b59b6", "#e91e63", "#16a085", "#d4ac0d", "#2ecc71", "#5c6bc0", "#00acc1"]


def color(uid):
    if uid is None:
        return "#888888"
    if uid == UNKNOWN:
        return "#e53935"
    return PALETTE[uid % len(PALETTE)]


def fmt(d: float) -> str:
    return "—" if d > 8 else f"{d:.2f}"


def photo(bgr, size: int) -> ImageTk.PhotoImage:
    img = Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)).resize((size, size))
    return ImageTk.PhotoImage(img)


class Scrollable(ttk.Frame):
    """Прокручиваемая колонка виджетов."""

    def __init__(self, parent, **kw):
        super().__init__(parent, **kw)
        self.canvas = tk.Canvas(self, highlightthickness=0, borderwidth=0)
        bar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.inner = ttk.Frame(self.canvas)
        self.inner.bind("<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self._win = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.bind("<Configure>", lambda e: self.canvas.itemconfigure(self._win, width=e.width))
        self.canvas.configure(yscrollcommand=bar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        bar.pack(side="right", fill="y")
        self.canvas.bind("<Enter>", lambda e: self.canvas.bind_all("<MouseWheel>", self._wheel))
        self.canvas.bind("<Leave>", lambda e: self.canvas.unbind_all("<MouseWheel>"))

    def _wheel(self, e):
        step = -1 * (e.delta // 120 if sys.platform == "win32" else e.delta)
        self.canvas.yview_scroll(int(step), "units")

    def clear(self):
        for w in self.inner.winfo_children():
            w.destroy()


class App:
    def __init__(self, root: tk.Tk, model: Model, camera: Camera, fake_folder: str | None = None):
        self.root, self.m, self.cam = root, model, camera
        self.fake = fake_folder
        self.frame_img = None
        self._live_sig = None
        self._people_rev = -1
        self._reviews_sig = None
        self._events_n = -1
        self._open_people: set[int] = set()
        self._imgs: dict[str, list] = {"live": [], "people": [], "review": []}

        root.title("Кто там")
        # Размер по экрану: на ноутбуке 1366×768 окно 1240×780 не влезло бы вместе с панелью задач.
        sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
        w, h = min(1240, sw - 40), min(780, sh - 90)
        root.geometry(f"{w}x{h}+{max(0, (sw - w) // 2)}+{max(0, (sh - h - 50) // 2)}")
        root.minsize(min(900, w), min(560, h))
        try:
            if sys.platform == "win32":
                root.iconbitmap(resource("assets", "icon.ico"))
            else:
                root.iconphoto(True, tk.PhotoImage(file=resource("assets", "icon.png")))
        except Exception:
            pass
        style = ttk.Style()
        if "vista" in style.theme_names():
            style.theme_use("vista")
        style.configure("Head.TLabel", font=("Segoe UI", 13, "bold"))
        style.configure("Small.TLabel", foreground="#666")
        style.configure("Card.TFrame", relief="groove", borderwidth=1)

        left = ttk.Frame(root, padding=10)
        left.pack(side="left", fill="both", expand=True)
        right = ttk.Frame(root, padding=10, width=420 if w >= 1150 else 360)
        right.pack(side="right", fill="y")
        right.pack_propagate(False)

        # Заголовок
        head = ttk.Frame(left)
        head.pack(fill="x")
        self.lbl_present = ttk.Label(head, text="Перед компом никого", style="Head.TLabel")
        self.lbl_present.pack(anchor="w")
        self.lbl_stats = ttk.Label(head, text="", style="Small.TLabel")
        self.lbl_stats.pack(anchor="w")
        self.lbl_status = ttk.Label(head, text="", foreground="#e67e22")
        self.lbl_status.place(relx=1.0, y=0, anchor="ne")

        # Камера
        self.canvas = tk.Canvas(left, bg="#202020", highlightthickness=0)
        self.canvas.pack(fill="both", expand=True, pady=8)

        # Лица в кадре
        self.live = ttk.Frame(left, height=96)
        self.live.pack(fill="x")

        # Серия снимков
        bar = ttk.Frame(left)
        bar.pack(fill="x", pady=(8, 0))
        ttk.Label(bar, text="Серия снимков:").pack(side="left")
        self.enroll_who = ttk.Combobox(bar, state="readonly", width=26)
        self.enroll_who.pack(side="left", padx=6)
        self.btn_enroll = ttk.Button(bar, text="Снять 20 кадров", command=self._enroll)
        self.btn_enroll.pack(side="left")
        self.enroll_prog = ttk.Progressbar(bar, length=160, maximum=20)
        self.lbl_enroll = ttk.Label(bar, text="")
        self.btn_stop = ttk.Button(bar, text="Стоп", command=lambda: self.m.stop_enroll())

        # Правая панель
        self.nb = ttk.Notebook(right)
        self.nb.pack(fill="both", expand=True)
        self.tab_people = ttk.Frame(self.nb, padding=6)
        self.tab_review = ttk.Frame(self.nb, padding=6)
        self.tab_events = ttk.Frame(self.nb, padding=6)
        self.tab_settings = ttk.Frame(self.nb, padding=6)
        self.tab_b24 = ttk.Frame(self.nb, padding=6)
        for t, n in ((self.tab_people, "Люди"), (self.tab_review, "Проверка"),
                     (self.tab_events, "Журнал"), (self.tab_settings, "Настройки"), (self.tab_b24, "Б24")):
            self.nb.add(t, text=n)
        self._build_people()
        self._build_review()
        self._build_events()
        self._build_settings()
        self._build_b24()

        self.start_camera()
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(30, self.tick)

    # ---------- камера и цикл
    def start_camera(self):
        if self.fake:
            self.cam.start(fake_folder=self.fake)
            self.lbl_status.config(text="Тестовый режим: фото из папки")
        else:
            self.cam.start(self.m.s["camera"])
            self.lbl_status.config(text="")

    def close(self):
        self.cam.stop()
        self.root.destroy()

    def tick(self):
        got = None
        try:
            while True:
                got = self.cam.out.get_nowait()
        except queue.Empty:
            pass
        if got:
            rgb, hits, now = got
            self.m.ingest(hits, now)
            self.draw_frame(rgb)
            self.update_live()
        if self.cam.error:
            self.lbl_status.config(text=self.cam.error)
        self.m.tick_b24()
        self.update_b24()
        self.update_header()
        self.update_people()
        self.update_reviews()
        self.update_events()
        self.root.after(30, self.tick)

    def update_header(self):
        names = self.m.present_names
        self.lbl_present.config(text="Перед компом: " + ", ".join(names) if names else "Перед компом никого")
        total = sum(p.count for p in self.m.people)
        self.lbl_stats.config(text=f"В базе: {len(self.m.people)} чел., {total} снимков")
        if self.m.enroll_user is not None:
            self.btn_enroll.pack_forget()
            self.enroll_who.pack_forget()
            self.enroll_prog.pack(side="left", padx=6)
            self.lbl_enroll.pack(side="left", padx=6)
            self.btn_stop.pack(side="left")
            self.enroll_prog.config(maximum=self.m.enroll_total, value=self.m.enroll_total - self.m.enroll_left)
            self.lbl_enroll.config(text=f"Снимаю «{self.m.name(self.m.enroll_user)}»: осталось {self.m.enroll_left}. "
                                        "Покрутите головой.")
        elif self.btn_stop.winfo_ismapped():
            self.enroll_prog.pack_forget()
            self.lbl_enroll.pack_forget()
            self.btn_stop.pack_forget()
            self.enroll_who.pack(side="left", padx=6)
            self.btn_enroll.pack(side="left")

    def draw_frame(self, rgb):
        cw, ch = max(self.canvas.winfo_width(), 50), max(self.canvas.winfo_height(), 50)
        h, w = rgb.shape[:2]
        k = min(cw / w, ch / h)
        dw, dh = int(w * k), int(h * k)
        img = Image.fromarray(rgb)
        if self.m.s["mirror"]:
            img = img.transpose(Image.FLIP_LEFT_RIGHT)
        self.frame_img = ImageTk.PhotoImage(img.resize((dw, dh)))
        ox, oy = (cw - dw) // 2, (ch - dh) // 2
        c = self.canvas
        c.delete("all")
        c.create_image(ox, oy, image=self.frame_img, anchor="nw")
        for f in self.m.faces:
            x, y, fw, fh = f.rect
            if self.m.s["mirror"]:
                x = 1 - x - fw
            x0, y0, x1, y1 = ox + x * dw, oy + y * dh, ox + (x + fw) * dw, oy + (y + fh) * dh
            col = color(f.label)
            c.create_rectangle(x0, y0, x1, y1, outline=col, width=3)
            if f.label is None:
                title = "…"
            elif f.label == UNKNOWN:
                title = "Не знаю" + (f" (≈ {self.m.name(f.match.best)})" if f.match.best is not None else "")
            else:
                title = self.m.name(f.label)
            t = c.create_text((x0 + x1) / 2, max(12, y0 - 14), text=f"{title}  {fmt(f.match.dist)}",
                              fill="white", font=("Segoe UI", 12, "bold"))
            bx = c.bbox(t)
            r = c.create_rectangle(bx[0] - 5, bx[1] - 2, bx[2] + 5, bx[3] + 2, fill=col, outline="")
            c.tag_raise(t, r)

    # ---------- меню «Это…»
    def face_menu(self, parent, target, match) -> ttk.Frame:
        fr = ttk.Frame(parent)
        if match.best is not None:
            ttk.Button(fr, text=f"✓ Да, {self.m.name(match.best)}",
                       command=lambda: self.m.confirm(target)).pack(side="left")
        mb = ttk.Menubutton(fr, text="Это…" if match.best is None else "Нет, это…")
        menu = tk.Menu(mb, tearoff=0)
        for p in self.m.people:
            menu.add_command(label=p.name, command=lambda uid=p.id: self.m.assign(target, uid))
        if self.m.people:
            menu.add_separator()
        menu.add_command(label="Новый человек…", command=lambda: self.ask_new(target))
        mb["menu"] = menu
        mb.pack(side="left", padx=4)
        return fr

    def ask_new(self, target=("none", None)):
        name = simpledialog.askstring("Кто это?", "Имя человека:", parent=self.root)
        if name:
            self.m.add_person(name, target)

    def update_live(self):
        sig = (tuple((f.id, f.label, f.match.best, f.match.known) for f in self.m.faces), self.m.revision)
        if sig == self._live_sig:
            # Тот же состав — обновляем только числа.
            for f, lbl in zip(self.m.faces, getattr(self, "_live_dist", [])):
                lbl.config(text=f"расстояние {fmt(f.match.dist)} · следующий {fmt(f.match.second)}")
            return
        self._live_sig = sig
        for w in self.live.winfo_children():
            w.destroy()
        self._imgs["live"] = []
        self._live_dist = []
        if not self.m.faces:
            ttk.Label(self.live, text="Лиц в кадре нет", style="Small.TLabel").pack(anchor="w", pady=30)
            return
        for f in self.m.faces[:4]:
            card = ttk.Frame(self.live, style="Card.TFrame", padding=6)
            card.pack(side="left", padx=(0, 8))
            im = photo(f.crop, 64)
            self._imgs["live"].append(im)
            tk.Label(card, image=im, bd=0).pack(side="left", padx=(0, 8))
            col = ttk.Frame(card)
            col.pack(side="left")
            if f.match.best is None:
                cap = "База пуста — кто это?"
            elif f.match.known:
                cap = f"Думаю, это {self.m.name(f.match.best)}"
            else:
                cap = f"Не уверена… похоже на {self.m.name(f.match.best)}"
            tk.Label(col, text=cap, fg=color(f.label), font=("Segoe UI", 11, "bold")).pack(anchor="w")
            d = ttk.Label(col, text="", style="Small.TLabel")
            d.pack(anchor="w")
            self._live_dist.append(d)
            self.face_menu(col, ("live", f.id), f.match).pack(anchor="w", pady=(2, 0))
        self.update_live()

    # ---------- Люди
    def _build_people(self):
        top = ttk.Frame(self.tab_people)
        top.pack(fill="x")
        self.new_name = ttk.Entry(top)
        self.new_name.pack(side="left", fill="x", expand=True)
        self.new_name.bind("<Return>", lambda e: self._add_person())
        ttk.Button(top, text="Добавить", command=self._add_person).pack(side="left", padx=(6, 0))
        self.people_hint = ttk.Label(self.tab_people, wraplength=380, style="Small.TLabel",
                                     text="Пока никого. Добавьте человека, затем «Снять 20 кадров» под камерой — "
                                          "или «Это… → Новый человек» у лица в кадре.")
        self.people_list = Scrollable(self.tab_people)
        self.people_list.pack(fill="both", expand=True, pady=(8, 0))

    def _add_person(self):
        self.m.add_person(self.new_name.get())
        self.new_name.delete(0, "end")

    def _enroll(self):
        i = self.enroll_who.current()
        if 0 <= i < len(self.m.people):
            self.m.start_enroll(self.m.people[i].id)

    def update_people(self):
        if self._people_rev == self.m.revision:
            return
        self._people_rev = self.m.revision
        names = [p.name for p in self.m.people]
        cur = self.enroll_who.get()
        self.enroll_who["values"] = names
        if cur not in names:
            self.enroll_who.set("— кто перед камерой —")
        if self.m.people:
            self.people_hint.pack_forget()
        else:
            self.people_hint.pack(before=self.people_list, anchor="w", pady=(8, 0))
        self.people_list.clear()
        self._imgs["people"] = []
        for p in self.m.people:
            self._person_row(p)

    def _person_row(self, p):
        box = ttk.Frame(self.people_list.inner, style="Card.TFrame", padding=6)
        box.pack(fill="x", pady=3)
        row = ttk.Frame(box)
        row.pack(fill="x")
        tk.Label(row, text="●", fg=color(p.id), font=("Segoe UI", 12)).pack(side="left")
        e = ttk.Entry(row, font=("Segoe UI", 11, "bold"), width=10)
        e.insert(0, p.name)
        e.pack(side="left", fill="x", expand=True, padx=4)
        e.bind("<Return>", lambda ev, uid=p.id, w=e: self.m.rename(uid, w.get()))
        e.bind("<FocusOut>", lambda ev, uid=p.id, w=e, old=p.name: w.get() != old and self.m.rename(uid, w.get()))
        ttk.Label(row, text=f"{p.count} фото", style="Small.TLabel").pack(side="left", padx=4)
        ttk.Button(row, text="📷", width=3, command=lambda: self.m.start_enroll(p.id)).pack(side="left")
        opened = p.id in self._open_people
        ttk.Button(row, text="▲" if opened else "▼", width=3, command=lambda: self._toggle(p.id)).pack(side="left")
        ttk.Button(row, text="🗑", width=3, command=lambda: self._delete_person(p)).pack(side="left")
        if opened:
            grid = ttk.Frame(box)
            grid.pack(fill="x", pady=(6, 0))
            for i, (sid, jpg) in enumerate(self.m.store.thumbs(p.id)):
                img = cv2.imdecode(__import__("numpy").frombuffer(jpg, "uint8"), cv2.IMREAD_COLOR)
                if img is None:
                    continue
                im = photo(img, 52)
                self._imgs["people"].append(im)
                lb = tk.Label(grid, image=im, bd=0)
                lb.grid(row=i // 6, column=i % 6, padx=2, pady=2)
                lb.bind("<Button-3>", lambda ev, s=sid, uid=p.id: self._thumb_menu(ev, s, uid))
                lb.bind("<Button-2>", lambda ev, s=sid, uid=p.id: self._thumb_menu(ev, s, uid))
            ttk.Label(box, text="Правый клик по снимку — удалить или перенести.", style="Small.TLabel").pack(anchor="w")

    def _toggle(self, uid):
        self._open_people ^= {uid}
        self.m.revision += 1

    def _delete_person(self, p):
        if messagebox.askyesno("Удалить", f"Удалить «{p.name}» и все снимки?", parent=self.root):
            self.m.delete_person(p.id)

    def _thumb_menu(self, ev, sid, uid):
        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label="Удалить снимок", command=lambda: self.m.delete_sample(sid))
        sub = tk.Menu(menu, tearoff=0)
        for p in self.m.people:
            if p.id != uid:
                sub.add_command(label=p.name, command=lambda to=p.id: self.m.move_sample(sid, to))
        menu.add_cascade(label="Перенести к…", menu=sub)
        menu.tk_popup(ev.x_root, ev.y_root)

    # ---------- Проверка
    def _build_review(self):
        ttk.Label(self.tab_review, wraplength=380, style="Small.TLabel",
                  text="Что думала программа. Подтвердите или поправьте — снимок уйдёт в базу.").pack(anchor="w")
        self.only_open = tk.BooleanVar(value=True)
        ttk.Checkbutton(self.tab_review, text="Только непроверенные", variable=self.only_open,
                        command=lambda: setattr(self, "_reviews_sig", None)).pack(anchor="w", pady=4)
        self.review_list = Scrollable(self.tab_review)
        self.review_list.pack(fill="both", expand=True)

    def update_reviews(self):
        items = [r for r in self.m.reviews if not self.only_open.get() or r.resolved is None]
        sig = (tuple((r.id, r.resolved) for r in items), self.m.revision)
        if sig == self._reviews_sig:
            return
        self._reviews_sig = sig
        self.review_list.clear()
        self._imgs["review"] = []
        for r in items[:60]:
            box = ttk.Frame(self.review_list.inner, style="Card.TFrame", padding=6)
            box.pack(fill="x", pady=3)
            im = photo(r.crop, 60)
            self._imgs["review"].append(im)
            tk.Label(box, image=im, bd=0).pack(side="left", padx=(0, 8))
            col = ttk.Frame(box)
            col.pack(side="left", fill="x")
            if r.match.best is None:
                t = "Не знала, кто это"
            elif r.match.known:
                t = f"Думала: {self.m.name(r.match.best)}"
            else:
                t = f"Сомневалась: {self.m.name(r.match.best)}?"
            ttk.Label(col, text=t, font=("Segoe UI", 10, "bold")).pack(anchor="w")
            ttk.Label(col, text=f"{time.strftime('%H:%M:%S', time.localtime(r.time))} · {fmt(r.match.dist)}",
                      style="Small.TLabel").pack(anchor="w")
            if r.resolved:
                ttk.Label(col, text=r.resolved, foreground="#2e7d32").pack(anchor="w")
            else:
                fr = self.face_menu(col, ("review", r.id), r.match)
                ttk.Button(fr, text="✗", width=3, command=lambda rid=r.id: self.m.dismiss(rid)).pack(side="left")
                fr.pack(anchor="w")

    # ---------- Журнал
    def _build_events(self):
        self.events = tk.Listbox(self.tab_events, font=("Segoe UI", 10), activestyle="none")
        self.events.pack(fill="both", expand=True)

    def update_events(self):
        if len(self.m.events) == self._events_n:
            return
        self._events_n = len(self.m.events)
        self.events.delete(0, "end")
        for t, text in self.m.events:
            self.events.insert("end", f"{time.strftime('%H:%M:%S', time.localtime(t))}   {text}")

    # ---------- Настройки
    def _build_settings(self):
        f = self.tab_settings
        s = self.m.s

        def section(t):
            ttk.Label(f, text=t, font=("Segoe UI", 11, "bold")).pack(anchor="w", pady=(10, 2))

        section("Узнавание")
        self.thr_lbl = ttk.Label(f, text="")
        self.thr_lbl.pack(anchor="w")
        thr = tk.DoubleVar(value=s["threshold"])

        def on_thr(v):
            self.m.set("threshold", round(float(v), 2))
            self.thr_lbl.config(text=f"Порог «узнал»: {self.m.s['threshold']:.2f}")
        ttk.Scale(f, from_=0.6, to=1.25, variable=thr, command=on_thr).pack(fill="x")
        on_thr(s["threshold"])
        ttk.Label(f, wraplength=380, style="Small.TLabel",
                  text="Меньше — строже (чаще «не знаю»), больше — смелее (чаще путает). "
                       "Ориентир — число «расстояние» у лица в кадре.").pack(anchor="w")
        self._check(f, "Самообучение: уверенные снимки сами пополняют базу", "auto_learn")

        section("Приветствие")
        self._check(f, "Говорить голосом", "speak")
        self._check(f, "Здороваться с незнакомцами", "greet_unknown")
        self.abs_lbl = ttk.Label(f, text="")
        self.abs_lbl.pack(anchor="w")
        ab = tk.DoubleVar(value=s["absence"])

        def on_abs(v):
            self.m.set("absence", round(float(v), 1))
            self.abs_lbl.config(text=f"«Пока» через {self.m.s['absence']:.1f} с отсутствия")
        ttk.Scale(f, from_=1, to=15, variable=ab, command=on_abs).pack(fill="x")
        on_abs(s["absence"])
        row = ttk.Frame(f)
        row.pack(fill="x", pady=4)
        ttk.Label(row, text="Голос:").pack(side="left")
        voices = ["Авто (русский)"] + self.m.speaker.voices()
        vc = ttk.Combobox(row, values=voices, state="readonly")
        vc.set(s["voice"] or voices[0])
        vc.bind("<<ComboboxSelected>>", lambda e: self.m.set("voice", "" if vc.current() == 0 else vc.get()))
        vc.pack(side="left", fill="x", expand=True, padx=6)
        ttk.Button(f, text="Проверить голос",
                   command=lambda: self.m.speaker.say(f"Привет, {self.m.people[0].name if self.m.people else 'друг'}!")
                   ).pack(anchor="w")

        section("Камера")
        row = ttk.Frame(f)
        row.pack(fill="x")
        ttk.Label(row, text="Номер или адрес:").pack(side="left")
        cam = ttk.Combobox(row, values=["0", "1", "2", "3"])
        cam.set(s["camera"])
        cam.pack(side="left", fill="x", expand=True, padx=6)

        def apply_cam(*_):
            self.m.set("camera", cam.get().strip() or "0")
            self.start_camera()
        cam.bind("<<ComboboxSelected>>", apply_cam)
        cam.bind("<Return>", apply_cam)
        ttk.Label(f, wraplength=380, style="Small.TLabel",
                  text="0 — встроенная камера. Для IP-камеры — адрес потока, например "
                       "rtsp://user:pass@192.168.1.10:554/stream1, затем Enter.").pack(anchor="w")
        self._check(f, "Зеркалить картинку", "mirror")

        section("База")
        ttk.Label(f, text=self.m.store.path, wraplength=380, style="Small.TLabel").pack(anchor="w")
        ttk.Button(f, text="Открыть папку", command=self._open_folder).pack(anchor="w", pady=2)

    # ---------- Битрикс24
    def _build_b24(self):
        f = self.tab_b24
        self._b24_sig = None
        ttk.Label(f, text="Битрикс24", font=("Segoe UI", 11, "bold")).pack(anchor="w")
        ttk.Label(f, wraplength=380, style="Small.TLabel",
                  text="Портал узнаёт, кто из сотрудников перед экраном, и присылает голосовые сообщения. "
                       "На портал уходят только «появился / ушёл» и время — снимки и данные лиц остаются здесь."
                  ).pack(anchor="w", pady=(0, 6))
        row = ttk.Frame(f)
        row.pack(fill="x")
        ttk.Label(row, text="Адрес:").pack(side="left")
        self.b24_url = ttk.Entry(row)
        self.b24_url.insert(0, self.m.s.get("b24_url", "").replace("https://", ""))
        self.b24_url.pack(side="left", fill="x", expand=True, padx=6)
        self.b24_btn = ttk.Button(row, text="Подключить", command=self._b24_toggle)
        self.b24_btn.pack(side="left")
        self.b24_url.bind("<Return>", lambda e: self._b24_toggle())
        self.b24_status = ttk.Label(f, text="", wraplength=380)
        self.b24_status.pack(anchor="w", pady=(6, 0))
        self.b24_code = ttk.Label(f, text="", font=("Consolas", 22, "bold"))
        self.b24_code.pack(anchor="w")
        self.b24_open = ttk.Button(f, text="Открыть страницу подтверждения",
                                   command=lambda: __import__("webbrowser").open(self.m.b24.pair_url))
        ttk.Label(f, text="Кто есть кто", font=("Segoe UI", 11, "bold")).pack(anchor="w", pady=(12, 0))
        ttk.Label(f, wraplength=380, style="Small.TLabel",
                  text="Свяжите людей из базы с сотрудниками портала — по ним работают события и сообщения."
                  ).pack(anchor="w")
        self.b24_links = Scrollable(f)
        self.b24_links.pack(fill="both", expand=True, pady=4)

    def _b24_toggle(self):
        b = self.m.b24
        if b.connected or b.state == "pairing":
            b.disconnect()
        else:
            b.connect(self.b24_url.get())

    def update_b24(self):
        b = self.m.b24
        if not b:
            return
        sig = (b.state, b.status, b.code, b.people_rev, self.m.revision, self.m.s.get("b24_user_name"))
        if sig == self._b24_sig:
            return
        self._b24_sig = sig
        busy = b.connected or b.state == "pairing"
        self.b24_btn.config(text="Отключить" if busy else "Подключить")
        self.b24_url.config(state="disabled" if busy else "normal")
        text = b.status
        if b.connected and self.m.s.get("b24_user_name"):
            text = f"{b.status} · учётка: {self.m.s['b24_user_name']}"
        self.b24_status.config(text=text, foreground="#c0392b" if b.state == "error" else
                               ("#1a9b4b" if b.state == "connected" else ""))
        self.b24_code.config(text=b.code)
        if b.code and b.pair_url:
            self.b24_open.pack(anchor="w", after=self.b24_code)
        else:
            self.b24_open.pack_forget()
        self.b24_links.clear()
        inner = self.b24_links.inner
        if not b.connected:
            ttk.Label(inner, text="Сначала подключитесь к порталу.", style="Small.TLabel").pack(anchor="w")
            return
        if not b.people:
            ttk.Label(inner, text="Загружаю сотрудников…", style="Small.TLabel").pack(anchor="w")
            return
        names = ["— не связан —"] + [e["name"] + (f" ({e['position']})" if e.get("position") else "") for e in b.people]
        ids = [0] + [int(e["id"]) for e in b.people]
        for p in self.m.people:
            r = ttk.Frame(inner)
            r.pack(fill="x", pady=1)
            ttk.Label(r, text=p.name, width=14).pack(side="left")
            cb = ttk.Combobox(r, values=names, state="readonly")
            cb.current(ids.index(p.b24) if p.b24 in ids else 0)
            cb.pack(side="left", fill="x", expand=True, padx=4)
            cb.bind("<<ComboboxSelected>>", lambda e, uid=p.id, c=cb: self.m.link_b24(uid, ids[c.current()]))
        if not self.m.people:
            ttk.Label(inner, text="В базе пока никого — добавьте людей на вкладке «Люди».",
                      style="Small.TLabel").pack(anchor="w")

    def _check(self, parent, text, key):
        v = tk.BooleanVar(value=bool(self.m.s[key]))
        ttk.Checkbutton(parent, text=text, variable=v, command=lambda: self.m.set(key, v.get())).pack(anchor="w")

    def _open_folder(self):
        d = os.path.dirname(self.m.store.path)
        if sys.platform == "win32":
            os.startfile(d)
        elif sys.platform == "darwin":
            os.system(f'open "{d}"')
