"""Связь с Битрикс24 (обвязка «Кто там» на портале: /ade/claude/ktotam/).

Подключение: приложение просит код, сотрудник подтверждает его на портале под своей учёткой,
приложение получает токен. Дальше:
  - сообщает «появился / ушёл» (только id сотрудника и время — никаких фото и векторов);
  - раз в 30 с — пульс: кто сейчас перед экраном (чинит пропущенные события);
  - long-poll забирает голосовые сообщения и отдаёт их в inbox — их проговаривает Model.

Сеть — в фоновых потоках; модель и интерфейс работают только с очередями и полями под замком.
"""
import json
import queue
import re
import socket
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from collections import deque

API = "/ade/claude/ktotam/api.php"
HEARTBEAT = 30.0


class Unauthorized(Exception):
    pass


def normalize_url(url: str) -> str:
    """«crm.example.ru/ade/...» → «https://crm.example.ru»."""
    url = (url or "").strip()
    if not url:
        return ""
    if not re.match(r"^https?://", url, re.I):
        url = "https://" + url
    m = re.match(r"^(https?://[^/?#]+)", url, re.I)
    return m.group(1).lower() if m else ""


class B24Client:
    def __init__(self, settings: dict, save, open_browser=True):
        """settings — словарь настроек модели (b24_url, b24_device, b24_token, b24_user, b24_user_name),
        save(key, value) — сохранить настройку."""
        self.s = settings
        self.save = save
        self.open_browser = open_browser
        self.inbox: queue.Queue = queue.Queue()      # тексты для озвучки
        self.notes: queue.Queue = queue.Queue()      # строки для журнала приложения
        self.state = "connected" if self.connected else "off"   # off | pairing | connected | error
        self.status = ""
        self.code = ""
        self.pair_url = ""
        self.people: list[dict] = []                 # сотрудники портала [{id, name, position}]
        self.people_rev = 0
        self._lock = threading.Lock()
        self._events: deque = deque(maxlen=200)
        self._present: list[int] = []
        self._persons: list[dict] | None = None
        self._persons_sent = None
        self._wake = threading.Event()
        self._gen = 0
        if self.connected:
            self._start()

    # ---------- состояние
    @property
    def connected(self) -> bool:
        return bool(self.s.get("b24_url") and self.s.get("b24_device") and self.s.get("b24_token"))

    @property
    def url(self) -> str:
        return self.s.get("b24_url", "")

    def _alive(self, gen) -> bool:
        return gen == self._gen

    # ---------- вызовы от модели (поток интерфейса)
    def event(self, kind: str, user: int, name: str):
        if self.connected:
            with self._lock:
                self._events.append({"type": kind, "user": int(user), "name": name})
            self._wake.set()

    def set_present(self, users):
        users = sorted({int(u) for u in users if int(u) > 0})
        with self._lock:
            self._present = users

    def set_persons(self, persons: list[dict]):
        with self._lock:
            self._persons = persons
        self._wake.set()

    # ---------- подключение
    def connect(self, url: str):
        url = normalize_url(url)
        if not url:
            self.state, self.status = "error", "Впишите адрес портала, например crm.example.ru"
            return
        self.disconnect(local_only=True)
        self.save("b24_url", url)
        self._gen += 1
        self.state, self.status, self.code = "pairing", "Запрашиваю код…", ""
        threading.Thread(target=self._pair, args=(self._gen, url), daemon=True).start()

    def disconnect(self, local_only=False):
        if self.connected and not local_only:
            dev, tok, url = self.s["b24_device"], self.s["b24_token"], self.url
            threading.Thread(target=lambda: self._quiet_call(url, dev, tok, "unpair"), daemon=True).start()
        self._gen += 1
        self._wake.set()
        for k in ("b24_device", "b24_token", "b24_user", "b24_user_name"):
            self.save(k, "" if k != "b24_user" else 0)
        self.state, self.status, self.code, self.people = "off", "", "", []
        self.people_rev += 1
        self._persons_sent = None

    def _pair(self, gen, url):
        try:
            r = self._http(url, "pair_start", {"name": socket.gethostname()[:60] or "Компьютер"})
        except Exception as e:
            if self._alive(gen):
                self.state, self.status = "error", f"Портал не ответил: {self._err(e)}"
            return
        self.code, self.pair_url = r["code"], r["url"]
        self.status = "Подтвердите код на портале (страница открылась в браузере)"
        if self.open_browser:
            try:
                webbrowser.open(self.pair_url)
            except Exception:
                pass
        deadline = time.time() + float(r.get("expires", 600))
        while self._alive(gen) and time.time() < deadline:
            time.sleep(2)
            try:
                p = self._http(url, "pair_poll", {"code": r["code"], "secret": r["secret"]})
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    break
                continue
            except Exception:
                continue
            if p.get("wait"):
                continue
            if not self._alive(gen):
                return
            self.save("b24_device", p["device"])
            self.save("b24_token", p["token"])
            self.save("b24_user", int(p["user"]["id"]))
            self.save("b24_user_name", p["user"]["name"])
            self.code = ""
            self.notes.put(f"🔗 Подключено к Битрикс24: {p['user']['name']}")
            self._start()
            return
        if self._alive(gen):
            self.state, self.status, self.code = "error", "Код не подтвердили за 10 минут — нажмите «Подключить» ещё раз", ""

    def _start(self):
        self._gen += 1
        gen = self._gen
        self.state, self.status = "connected", "Подключено"
        self._persons_sent = None
        threading.Thread(target=self._main_loop, args=(gen,), daemon=True).start()
        threading.Thread(target=self._pull_loop, args=(gen,), daemon=True).start()

    # ---------- рабочие потоки
    def _main_loop(self, gen):
        last_beat, last_people, fails = 0.0, 0.0, 0
        while self._alive(gen):
            try:
                if time.time() - last_people > 600:
                    r = self._call("people", method="GET")
                    self.people = r.get("people", [])
                    self.people_rev += 1
                    last_people = time.time()
                with self._lock:
                    persons = self._persons
                if persons is not None and persons != self._persons_sent:
                    self._call("sync", {"persons": persons})
                    self._persons_sent = persons
                while True:
                    with self._lock:
                        ev = self._events[0] if self._events else None
                    if ev is None:
                        break
                    self._call("event", ev)
                    with self._lock:
                        if self._events and self._events[0] is ev:
                            self._events.popleft()
                if time.time() - last_beat > HEARTBEAT:
                    with self._lock:
                        present = list(self._present)
                    self._call("status", {"present": present})
                    last_beat = time.time()
                if fails:
                    self.notes.put("🔗 Связь с Битрикс24 восстановлена")
                fails = 0
                self.state, self.status = "connected", "Подключено"
            except Unauthorized:
                self._revoked(gen)
                return
            except Exception as e:
                fails += 1
                if fails == 1:
                    self.notes.put(f"🔗 Нет связи с Битрикс24: {self._err(e)}")
                self.state, self.status = "error", f"Нет связи с порталом: {self._err(e)} — повторяю"
                self._wake.wait(min(60, 5 * fails))
                self._wake.clear()
                continue
            self._wake.wait(5)
            self._wake.clear()

    def _pull_loop(self, gen):
        fails = 0
        while self._alive(gen):
            try:
                r = self._call("pull", method="GET", query="&wait=25", timeout=40)
                items = r.get("items", [])
                for it in items:
                    if self._alive(gen):
                        self.inbox.put(it["text"])
                if items:
                    self._call("ack", {"ids": [it["id"] for it in items]})
                fails = 0
            except Unauthorized:
                self._revoked(gen)
                return
            except Exception:
                fails += 1
                time.sleep(min(60, 3 * fails))

    def _revoked(self, gen):
        if not self._alive(gen):
            return
        self.notes.put("🔗 Портал отключил это приложение — подключите заново")
        self.disconnect(local_only=True)
        self.state, self.status = "error", "Приложение отключено на портале — подключите заново"

    # ---------- HTTP
    def _call(self, action, body=None, method="POST", query="", timeout=15):
        return self._http(self.url, action, body, method, query, timeout,
                          {"X-Ktotam-Device": self.s.get("b24_device", ""), "X-Ktotam-Token": self.s.get("b24_token", "")})

    def _quiet_call(self, url, dev, tok, action):
        try:
            self._http(url, action, {}, headers={"X-Ktotam-Device": dev, "X-Ktotam-Token": tok})
        except Exception:
            pass

    @staticmethod
    def _http(url, action, body=None, method="POST", query="", timeout=15, headers=None):
        h = {"Accept": "application/json", "User-Agent": "Ktotam"}
        h.update(headers or {})
        data = None
        if method == "POST":
            data = json.dumps(body or {}, ensure_ascii=False).encode("utf-8")
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(f"{url}{API}?action={action}{query}", data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise Unauthorized() from e
            raise

    @staticmethod
    def _err(e) -> str:
        if isinstance(e, urllib.error.HTTPError):
            return f"ошибка {e.code}"
        if isinstance(e, urllib.error.URLError):
            return str(e.reason)[:80]
        if isinstance(e, ValueError):
            return "ответ не похож на портал с «Кто там»"
        return str(e)[:80]
