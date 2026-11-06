"""Синтез речи: на Windows — SAPI (голоса Windows, русский «Irina»/«Pavel»), на macOS — say."""
import queue
import subprocess
import sys
import threading


class Speaker:
    def __init__(self):
        self.voice = ""          # имя голоса; пусто — первый русский
        self.q: queue.Queue = queue.Queue()
        threading.Thread(target=self._loop, daemon=True).start()

    def say(self, text: str):
        self.q.put(text)

    def voices(self) -> list[str]:
        if sys.platform == "win32":
            try:
                import win32com.client
                sp = win32com.client.Dispatch("SAPI.SpVoice")
                return [v.GetDescription() for v in sp.GetVoices()]
            except Exception:
                return []
        if sys.platform == "darwin":
            try:
                out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
                return [l.split("  ")[0].strip() for l in out.splitlines() if "ru_RU" in l]
            except Exception:
                return []
        return []

    def _loop(self):
        sp = None
        if sys.platform == "win32":
            try:
                import pythoncom
                import win32com.client
                pythoncom.CoInitialize()
                sp = win32com.client.Dispatch("SAPI.SpVoice")
            except Exception:
                sp = None
        while True:
            text = self.q.get()
            try:
                if sys.platform == "win32":
                    self._say_windows(sp, text)
                elif sys.platform == "darwin":
                    v = self.voice or (self.voices() or ["Milena"])[0]
                    subprocess.run(["say", "-v", v, text])
                else:
                    subprocess.run(["spd-say", "-l", "ru", text])
            except Exception as e:
                print("голос:", e)

    def _say_windows(self, sp, text: str):
        if sp is None:
            # Запасной путь без pywin32: System.Speech через PowerShell.
            ps = ("Add-Type -AssemblyName System.Speech; $s=New-Object System.Speech.Synthesis.SpeechSynthesizer; "
                  "$r=$s.GetInstalledVoices()|?{$_.VoiceInfo.Culture.Name -like 'ru*'}|select -First 1; "
                  "if($r){$s.SelectVoice($r.VoiceInfo.Name)}; $s.Speak($args[0])")
            subprocess.run(["powershell", "-NoProfile", "-Command", ps, text],
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            return
        voices = list(sp.GetVoices())
        pick = None
        if self.voice:
            pick = next((v for v in voices if v.GetDescription() == self.voice), None)
        if pick is None:
            # Русский голос: язык 419 (LCID русского) в атрибутах голоса.
            pick = next((v for v in voices if "419" in (v.GetAttribute("Language") or "")), None)
        if pick is not None:
            sp.Voice = pick
        sp.Speak(text)
