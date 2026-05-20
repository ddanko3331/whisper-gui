#!/usr/bin/env python3
"""Minimal macOS GUI for whisper-cli (whisper.cpp)."""

from __future__ import annotations

import os
import select
import sys

os.environ.setdefault("TK_SILENCE_DEPRECATION", "1")

import json
import queue
import subprocess
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

CONFIG_PATH = Path.home() / ".config" / "whisper-gui" / "config.json"

DEFAULTS = {
    "cli": "/opt/homebrew/bin/whisper-cli",
    "model": str(Path.home() / "whisper-medium.bin"),
    "language": "auto",
    "threads": 4,
    "use_gpu": False,
    "translate": False,
    "no_timestamps": False,
    "output_txt": True,
    "output_srt": False,
    "output_vtt": False,
    "output_json": False,
}

HOME_AUDIO = Path.home() / "input_ready.wav"


def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            data = json.loads(CONFIG_PATH.read_text())
            return {**DEFAULTS, **data}
        except (json.JSONDecodeError, OSError):
            pass
    return dict(DEFAULTS)


def save_config(cfg: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))


class WhisperGui(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Whisper")
        self.minsize(560, 480)
        self.geometry("700x580")

        self.cfg = load_config()
        self.audio_path = tk.StringVar(
            value=str(HOME_AUDIO) if HOME_AUDIO.is_file() else ""
        )
        self.cli_path = tk.StringVar(value=self.cfg["cli"])
        self.model_path = tk.StringVar(value=self.cfg["model"])
        self.language = tk.StringVar(value=self.cfg["language"])
        self.threads = tk.IntVar(value=int(self.cfg["threads"]))
        self.use_gpu = tk.BooleanVar(value=bool(self.cfg.get("use_gpu", False)))
        self.translate = tk.BooleanVar(value=bool(self.cfg["translate"]))
        self.no_timestamps = tk.BooleanVar(value=bool(self.cfg["no_timestamps"]))
        self.output_txt = tk.BooleanVar(value=bool(self.cfg["output_txt"]))
        self.output_srt = tk.BooleanVar(value=bool(self.cfg["output_srt"]))
        self.output_vtt = tk.BooleanVar(value=bool(self.cfg["output_vtt"]))
        self.output_json = tk.BooleanVar(value=bool(self.cfg["output_json"]))

        self._proc: subprocess.Popen[bytes] | None = None
        self._log_queue: queue.Queue = queue.Queue()
        self._output_stem: Path | None = None

        self._build_ui()
        self._poll_log()
        self._bring_to_front()

    def _bring_to_front(self) -> None:
        self.lift()
        self.attributes("-topmost", True)
        self.after(200, lambda: self.attributes("-topmost", False))
        self.focus_force()

    def _build_ui(self) -> None:
        pad = {"padx": 10, "pady": 4}
        root = ttk.Frame(self, padding=12)
        root.pack(fill=tk.BOTH, expand=True)

        row = ttk.Frame(root)
        row.pack(fill=tk.X, **pad)
        ttk.Label(row, text="Audio").pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=self.audio_path).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8)
        )
        ttk.Button(row, text="Choose…", command=self._pick_audio).pack(side=tk.LEFT)

        self._path_row(root, "CLI", self.cli_path, self._pick_cli)
        self._path_row(root, "Model", self.model_path, self._pick_model)

        opts = ttk.LabelFrame(root, text="Options", padding=8)
        opts.pack(fill=tk.X, **pad)

        lang_row = ttk.Frame(opts)
        lang_row.pack(fill=tk.X, pady=2)
        ttk.Label(lang_row, text="Language").pack(side=tk.LEFT)
        ttk.Combobox(
            lang_row,
            textvariable=self.language,
            values=["auto", "en", "ru", "de", "fr", "es", "it", "uk", "zh", "ja"],
            width=10,
        ).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Label(lang_row, text="Threads").pack(side=tk.LEFT, padx=(20, 0))
        ttk.Spinbox(lang_row, from_=1, to=16, textvariable=self.threads, width=5).pack(
            side=tk.LEFT, padx=(8, 0)
        )

        flags = ttk.Frame(opts)
        flags.pack(fill=tk.X, pady=4)
        ttk.Checkbutton(
            flags,
            text="Use GPU (Metal) — off = CPU, more reliable",
            variable=self.use_gpu,
        ).pack(side=tk.LEFT)
        ttk.Checkbutton(flags, text="Translate → English", variable=self.translate).pack(
            side=tk.LEFT, padx=(12, 0)
        )

        flags2 = ttk.Frame(opts)
        flags2.pack(fill=tk.X, pady=2)
        ttk.Checkbutton(
            flags2, text="Plain text (no timestamps)", variable=self.no_timestamps
        ).pack(side=tk.LEFT)

        out = ttk.Frame(opts)
        out.pack(fill=tk.X, pady=2)
        ttk.Label(out, text="Save files:").pack(side=tk.LEFT)
        for label, var in [
            (".txt", self.output_txt),
            (".srt", self.output_srt),
            (".vtt", self.output_vtt),
            (".json", self.output_json),
        ]:
            ttk.Checkbutton(out, text=label, variable=var).pack(side=tk.LEFT, padx=(8, 0))

        actions = ttk.Frame(root)
        actions.pack(fill=tk.X, **pad)
        self.run_btn = ttk.Button(actions, text="Transcribe", command=self._run)
        self.run_btn.pack(side=tk.LEFT)
        self.stop_btn = ttk.Button(actions, text="Stop", command=self._stop, state=tk.DISABLED)
        self.stop_btn.pack(side=tk.LEFT, padx=(8, 0))
        ttk.Button(actions, text="Copy transcript", command=self._copy_transcript).pack(
            side=tk.LEFT, padx=(8, 0)
        )
        ttk.Button(actions, text="Open folder", command=self._open_output_dir).pack(
            side=tk.LEFT, padx=(8, 0)
        )

        paned = ttk.PanedWindow(root, orient=tk.VERTICAL)
        paned.pack(fill=tk.BOTH, expand=True, **pad)

        log_frame = ttk.LabelFrame(paned, text="Log", padding=4)
        paned.add(log_frame, weight=1)
        self.log = tk.Text(log_frame, wrap=tk.WORD, font=("Menlo", 10), height=8)
        log_scroll = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=log_scroll.set)
        self.log.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        log_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        tx_frame = ttk.LabelFrame(paned, text="Transcript", padding=4)
        paned.add(tx_frame, weight=2)
        self.transcript = tk.Text(tx_frame, wrap=tk.WORD, font=("Helvetica", 13))
        tx_scroll = ttk.Scrollbar(tx_frame, command=self.transcript.yview)
        self.transcript.configure(yscrollcommand=tx_scroll.set)
        self.transcript.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        tx_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.status = ttk.Label(
            root,
            text="Choose audio → Transcribe. CPU mode is on by default (medium model may take a few minutes).",
        )
        self.status.pack(anchor=tk.W, **pad)

    def _path_row(self, parent: ttk.Frame, label: str, var: tk.StringVar, pick) -> None:
        row = ttk.Frame(parent)
        row.pack(fill=tk.X, pady=2)
        ttk.Label(row, text=label, width=6).pack(side=tk.LEFT)
        ttk.Entry(row, textvariable=var).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        ttk.Button(row, text="…", width=3, command=pick).pack(side=tk.LEFT)

    def _pick_audio(self) -> None:
        path = filedialog.askopenfilename(
            title="Choose audio",
            filetypes=[
                ("Audio", "*.wav *.mp3 *.m4a *.flac *.ogg *.aac"),
                ("All files", "*.*"),
            ],
        )
        if path:
            self.audio_path.set(path)

    def _pick_cli(self) -> None:
        path = filedialog.askopenfilename(title="whisper-cli binary")
        if path:
            self.cli_path.set(path)

    def _pick_model(self) -> None:
        path = filedialog.askopenfilename(
            title="Model (.bin)",
            filetypes=[("GGML model", "*.bin"), ("All files", "*.*")],
        )
        if path:
            self.model_path.set(path)

    def _persist(self) -> None:
        self.cfg.update(
            {
                "cli": self.cli_path.get(),
                "model": self.model_path.get(),
                "language": self.language.get(),
                "threads": int(self.threads.get()),
                "use_gpu": self.use_gpu.get(),
                "translate": self.translate.get(),
                "no_timestamps": self.no_timestamps.get(),
                "output_txt": self.output_txt.get(),
                "output_srt": self.output_srt.get(),
                "output_vtt": self.output_vtt.get(),
                "output_json": self.output_json.get(),
            }
        )
        save_config(self.cfg)

    def _build_cmd(self, audio: Path) -> list[str]:
        cli = Path(self.cli_path.get().strip())
        model = Path(self.model_path.get().strip())
        if not cli.is_file():
            raise FileNotFoundError(f"CLI not found: {cli}")
        if not model.is_file():
            raise FileNotFoundError(f"Model not found: {model}")

        cmd = [
            str(cli),
            "-m",
            str(model),
            "-f",
            str(audio),
            "-t",
            str(int(self.threads.get())),
            "-l",
            self.language.get().strip(),
            "-pp",
        ]
        if not self.use_gpu.get():
            cmd.append("-ng")
        if self.translate.get():
            cmd.append("-tr")
        if self.no_timestamps.get():
            cmd.append("-nt")
        if self.output_txt.get():
            cmd.append("-otxt")
        if self.output_srt.get():
            cmd.append("-osrt")
        if self.output_vtt.get():
            cmd.append("-ovtt")
        if self.output_json.get():
            cmd.append("-oj")

        stem = audio.with_suffix("")
        self._output_stem = stem
        cmd.extend(["-of", str(stem)])
        cmd.append(str(audio))
        return cmd

    def _run(self) -> None:
        audio = self.audio_path.get().strip()
        if not audio:
            messagebox.showwarning("Whisper", "Choose an audio file first.")
            return
        audio_path = Path(audio)
        if not audio_path.is_file():
            messagebox.showerror("Whisper", f"File not found:\n{audio}")
            return

        self._persist()
        try:
            cmd = self._build_cmd(audio_path)
        except FileNotFoundError as exc:
            messagebox.showerror("Whisper", str(exc))
            return

        self.log.delete("1.0", tk.END)
        self.transcript.delete("1.0", tk.END)
        self._append_log(f"$ {' '.join(cmd)}\n\n")
        self.run_btn.configure(state=tk.DISABLED)
        self.stop_btn.configure(state=tk.NORMAL)
        mode = "GPU" if self.use_gpu.get() else "CPU"
        self.status.configure(text=f"Transcribing on {mode}… (please wait)")
        self.update_idletasks()

        def worker() -> None:
            code = 1
            try:
                self._proc = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                assert self._proc.stdout is not None
                fd = self._proc.stdout.fileno()
                while True:
                    if self._proc.poll() is not None:
                        chunk = self._proc.stdout.read()
                        if chunk:
                            self._log_queue.put(chunk.decode("utf-8", errors="replace"))
                        break
                    ready, _, _ = select.select([fd], [], [], 0.2)
                    if ready:
                        chunk = os.read(fd, 4096)
                        if chunk:
                            self._log_queue.put(chunk.decode("utf-8", errors="replace"))
                code = self._proc.wait()
            except OSError as exc:
                self._log_queue.put(f"\nError: {exc}\n")
            finally:
                self._proc = None
                self._log_queue.put(("done", code))

        threading.Thread(target=worker, daemon=True).start()

    def _stop(self) -> None:
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            self.status.configure(text="Stopping…")

    def _poll_log(self) -> None:
        try:
            while True:
                item = self._log_queue.get_nowait()
                if isinstance(item, tuple) and item[0] == "done":
                    code = item[1]
                    self.run_btn.configure(state=tk.NORMAL)
                    self.stop_btn.configure(state=tk.DISABLED)
                    self._on_finished(code)
                    continue
                self._append_log(str(item))
        except queue.Empty:
            pass
        self.after(80, self._poll_log)

    def _on_finished(self, code: int) -> None:
        self._load_transcript_file()
        if code == 0:
            self.status.configure(text="Done.")
            return
        if code < 0:
            code = 256 + code
        hint = ""
        if code in (139, -11) and self.use_gpu.get():
            hint = "\n\nTip: turn off “Use GPU” to run on CPU."
        elif code in (139, -11):
            hint = "\n\nThe process crashed. Check the log above."
        self.status.configure(text=f"Failed (exit {code}).")
        messagebox.showerror("Whisper", f"whisper-cli exited with code {code}.{hint}")

    def _load_transcript_file(self) -> None:
        stem = self._output_stem
        if not stem:
            return
        for ext in (".txt", ".srt", ".json"):
            path = stem.with_suffix(ext)
            if path.is_file():
                try:
                    text = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                self.transcript.delete("1.0", tk.END)
                self.transcript.insert("1.0", text)
                self.status.configure(text=f"Done — loaded {path.name}")
                return
        # Parse transcript lines from log (lines starting with [)
        log_text = self.log.get("1.0", tk.END)
        lines = [
            ln
            for ln in log_text.splitlines()
            if ln.startswith("[") and "]" in ln[:12]
        ]
        if lines:
            self.transcript.delete("1.0", tk.END)
            self.transcript.insert("1.0", "\n".join(lines))

    def _append_log(self, text: str) -> None:
        self.log.insert(tk.END, text)
        self.log.see(tk.END)

    def _copy_transcript(self) -> None:
        content = self.transcript.get("1.0", tk.END).strip()
        if content:
            self.clipboard_clear()
            self.clipboard_append(content)

    def _open_output_dir(self) -> None:
        audio = self.audio_path.get().strip()
        if not audio:
            return
        folder = str(Path(audio).resolve().parent)
        subprocess.run(["open", folder], check=False)


def main() -> None:
    try:
        app = WhisperGui()
    except tk.TclError as exc:
        print(f"GUI failed to start: {exc}", file=sys.stderr)
        sys.exit(1)
    app.mainloop()


if __name__ == "__main__":
    main()
