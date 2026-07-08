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
from typing import List, Tuple, Optional, Union, Dict, Any

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
    "obsidian_vault_path": "",
    "obsidian_save_directly": False,
    "obsidian_folder": "Transcriptions",
    "diarize_threshold": 0.65,
    "diarize_speakers": 0,
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
        self.custom_name = tk.StringVar(value="")
        self.note_name = tk.StringVar(value="")
        self.tag_options = ["meeting", "conference", "bank", "lecture", "interview", "podcast"]
        self.tags_str = tk.StringVar(value="")
        self.obsidian_vault_path = tk.StringVar(value=self.cfg.get("obsidian_vault_path", ""))
        self.obsidian_save_directly = tk.BooleanVar(value=bool(self.cfg.get("obsidian_save_directly", False)))
        self.obsidian_folder = tk.StringVar(value=self.cfg.get("obsidian_folder", "Transcriptions"))
        self.diarize_threshold = tk.DoubleVar(value=float(self.cfg.get("diarize_threshold", 0.65)))
        self.diarize_speakers = tk.IntVar(value=int(self.cfg.get("diarize_speakers", 0)))

        self._proc: Optional[subprocess.Popen] = None
        self.is_transcribing: bool = False
        self._log_queue: queue.Queue = queue.Queue()
        self._output_stem: Optional[Path] = None
        self.original_source_path: Optional[str] = None
        self.browser_dir: str = str(Path.home() / "Library" / "Application Support" / "whisper-gui" / "converted")
        self.browser_files: List[str] = []
        self.browser_selected_path = None
        
        # Audio Player Preview State (Main Tab)
        self.preview_proc = None
        self.preview_duration = 0.0
        self.preview_elapsed = 0.0
        self.preview_is_paused = False
        self.preview_timer_id = None
        self.preview_slider_updating = False

        # Audio Player Browser State (Browser Tab)
        self.browser_proc = None
        self.browser_duration = 0.0
        self.browser_elapsed = 0.0
        self.browser_is_paused = False
        self.browser_timer_id = None
        self.browser_slider_updating = False
        self.browser_audio_path = None
        self.timestamp_ranges = []

        import re
        self.progress_pat = re.compile(r"progress\s*=\s*(\d+)%")

        self.browser_current_highlighted_line = None

        self._build_ui()
        self._auto_discover_obsidian_vault()
        self._poll_log()

        # Audio change trace
        self.audio_path.trace_add("write", lambda *args: self._on_audio_path_changed())
        self._on_audio_path_changed()

        # Window closing handler
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self._bring_to_front()

    def _bring_to_front(self) -> None:
        self.lift()
        self.attributes("-topmost", True)
        self.after(200, lambda: self.attributes("-topmost", False))
        self.focus_force()

    def _build_ui(self) -> None:
        pad = {"padx": 10, "pady": 4}
        
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True)
        self.notebook.bind("<<NotebookTabChanged>>", self._on_tab_changed)

        root = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(root, text="Transcribe")
        
        browser_tab = ttk.Frame(self.notebook, padding=12)
        self.notebook.add(browser_tab, text="Browser")
        self._build_browser_ui(browser_tab)

        row = ttk.Frame(root)
        row.pack(fill=tk.X, **pad)
        self.audio_row = row
        ttk.Label(row, text="Audio", width=10).pack(side=tk.LEFT)
        self.audio_entry = ttk.Entry(row, textvariable=self.audio_path)
        self.audio_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        ttk.Button(row, text="Choose…", command=self._pick_audio).pack(side=tk.LEFT)

        # Setup Main Tab Audio Preview Player UI
        self.preview_frame = ttk.Frame(root)
        self.preview_frame.pack(fill=tk.X, **pad)
        
        preview_lbl = ttk.Label(self.preview_frame, text="Preview", width=10)
        preview_lbl.pack(side=tk.LEFT)
        
        self.preview_play_btn = ttk.Button(self.preview_frame, text="▶", width=3, state=tk.DISABLED, command=self._play_pause_preview)
        self.preview_play_btn.pack(side=tk.LEFT, padx=(8, 0))
        
        self.preview_slider = ttk.Scale(self.preview_frame, from_=0, to=100, state=tk.DISABLED, command=self._seek_preview)
        self.preview_slider.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        
        self.preview_time_lbl = ttk.Label(self.preview_frame, text="00:00 / 00:00", width=12, anchor=tk.E)
        self.preview_time_lbl.pack(side=tk.LEFT)

        self._path_row(root, "CLI", self.cli_path, self._pick_cli)
        
        # Check updates button for whisper-cpp
        update_row = ttk.Frame(root)
        update_row.pack(fill=tk.X, pady=2)
        ttk.Label(update_row, text="", width=10).pack(side=tk.LEFT)
        self.update_btn = ttk.Button(update_row, text="Check Whisper Update", command=self._check_whisper_update)
        self.update_btn.pack(side=tk.LEFT, padx=(8, 0))
        self.sherpa_update_btn = ttk.Button(update_row, text="Check Sherpa Update", command=self._check_sherpa_update)
        self.sherpa_update_btn.pack(side=tk.LEFT, padx=(8, 0))

        self._path_row(root, "Model", self.model_path, self._pick_model)

        # Custom Save Name row
        save_row = ttk.Frame(root)
        save_row.pack(fill=tk.X, **pad)
        ttk.Label(save_row, text="Save Name", width=10).pack(side=tk.LEFT)
        ttk.Entry(save_row, textvariable=self.custom_name).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8)
        )

        # Note Name row
        note_row = ttk.Frame(root)
        note_row.pack(fill=tk.X, **pad)
        ttk.Label(note_row, text="Note Name", width=10).pack(side=tk.LEFT)
        ttk.Entry(note_row, textvariable=self.note_name).pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8)
        )

        # Tags row
        tag_row = ttk.Frame(root)
        tag_row.pack(fill=tk.X, **pad)
        ttk.Label(tag_row, text="Tags", width=10).pack(side=tk.LEFT)
        
        self.tags_entry = ttk.Entry(tag_row, textvariable=self.tags_str)
        self.tags_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        self.tags_entry.bind("<KeyRelease>", self._autocomplete_tags)
        
        choose_tags_btn = ttk.Button(tag_row, text="Choose…", command=self._choose_tags)
        choose_tags_btn.pack(side=tk.LEFT)
        
        import_tags_btn = ttk.Button(tag_row, text="Import…", command=self._import_obsidian_tags)
        import_tags_btn.pack(side=tk.LEFT, padx=(6, 0))

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

        # Obsidian section
        obsidian_frame = ttk.LabelFrame(opts, text="Obsidian Integration", padding=8)
        obsidian_frame.pack(fill=tk.X, pady=(6, 2))
        
        path_row = ttk.Frame(obsidian_frame)
        path_row.pack(fill=tk.X, pady=2)
        ttk.Label(path_row, text="Obsidian Vault", width=12).pack(side=tk.LEFT)
        ttk.Entry(path_row, textvariable=self.obsidian_vault_path).pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        ttk.Button(path_row, text="…", width=3, command=self._pick_obsidian_vault).pack(side=tk.LEFT)
        
        fld_row = ttk.Frame(obsidian_frame)
        fld_row.pack(fill=tk.X, pady=2)
        ttk.Label(fld_row, text="Vault folder", width=12).pack(side=tk.LEFT)
        ttk.Entry(fld_row, textvariable=self.obsidian_folder, width=25).pack(side=tk.LEFT, padx=(8, 0))
        
        ttk.Checkbutton(
            obsidian_frame,
            text="🪨 Save copy directly to Obsidian vault",
            variable=self.obsidian_save_directly,
        ).pack(anchor=tk.W, pady=(4, 0))

        # Speaker Recognition section
        self.diarize_enabled = tk.BooleanVar(value=bool(self.cfg.get("diarize_enabled", False)))
        speakers_frame = ttk.LabelFrame(opts, text="Speaker Recognition", padding=8)
        speakers_frame.pack(fill=tk.X, pady=(6, 2))
        
        spk_row = ttk.Frame(speakers_frame)
        spk_row.pack(fill=tk.X, pady=2)
        
        ttk.Checkbutton(
            spk_row,
            text="👥 Enable Local Diarization (Speaker Recognition)",
            variable=self.diarize_enabled,
            command=self._on_diarize_toggle,
        ).pack(side=tk.LEFT)
        
        ttk.Button(
            spk_row,
            text="Register Voice…",
            command=self._register_voice,
        ).pack(side=tk.LEFT, padx=(12, 0))
        
        # Match threshold row
        thresh_row = ttk.Frame(speakers_frame)
        thresh_row.pack(fill=tk.X, pady=2)
        ttk.Label(thresh_row, text="Match threshold", width=15).pack(side=tk.LEFT)
        thresh_entry = ttk.Entry(thresh_row, textvariable=self.diarize_threshold, width=10)
        thresh_entry.pack(side=tk.LEFT, padx=(8, 0))
        thresh_entry.bind("<FocusOut>", lambda e: self._persist())
        thresh_entry.bind("<Return>", lambda e: self._persist())

        # Expected speakers row
        spks_row = ttk.Frame(speakers_frame)
        spks_row.pack(fill=tk.X, pady=2)
        ttk.Label(spks_row, text="Expected speakers", width=15).pack(side=tk.LEFT)
        spks_entry = ttk.Entry(spks_row, textvariable=self.diarize_speakers, width=10)
        spks_entry.pack(side=tk.LEFT, padx=(8, 0))
        spks_entry.bind("<FocusOut>", lambda e: self._persist())
        spks_entry.bind("<Return>", lambda e: self._persist())
        
        self.registered_speakers_str = tk.StringVar(value="None registered")
        self.registered_speakers_lbl = ttk.Label(speakers_frame, textvariable=self.registered_speakers_str, foreground="gray", font=("Helvetica", 10))
        self.registered_speakers_lbl.pack(anchor=tk.W, pady=(4, 0))

        # System & Dependencies section
        sys_frame = ttk.LabelFrame(opts, text="System & Dependencies", padding=8)
        sys_frame.pack(fill=tk.X, pady=(6, 2))
        
        ver_row = ttk.Frame(sys_frame)
        ver_row.pack(fill=tk.X, pady=2)
        ttk.Label(ver_row, text="App Version:").pack(side=tk.LEFT)
        ttk.Label(ver_row, text="1.2.0 (Active)", foreground="green").pack(side=tk.LEFT, padx=(6, 0))
        
        dep_btn = ttk.Button(sys_frame, text="Check Dependencies", command=self._check_dependencies)
        dep_btn.pack(anchor=tk.W, pady=(4, 4))
        
        doc_frame = ttk.Frame(sys_frame)
        doc_frame.pack(fill=tk.BOTH, expand=True, pady=2)
        doc_scroll = ttk.Scrollbar(doc_frame)
        doc_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        doc_text = tk.Text(doc_frame, wrap=tk.WORD, font=("Courier", 10), height=5, yscrollcommand=doc_scroll.set)
        doc_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        doc_scroll.config(command=doc_text.yview)
        
        doc_text.insert(tk.END, """=== WHISPER GUI - README & RELEASE NOTES ===

Whisper GUI is a premium client for whisper.cpp.

RELEASE NOTES (v1.2.0):
- Added asynchronous "Check Dependencies" diagnostics.
- Added premium transcribing button pulsing glow animation.
- Resolved speaker recognition pipe deadlock on long audios.
- Resolved argument conflicts between plain-text and diarization.
- Enabled real-time stdout/stderr log streaming.

REQUIREMENTS:
- whisper-cli (brew install whisper-cpp)
- ffmpeg (brew install ffmpeg)
- python3 (with wave, json, math, struct)
""")
        doc_text.configure(state=tk.DISABLED)

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

        status_bar = ttk.Frame(root)
        status_bar.pack(fill=tk.X, **pad)
        
        self.status = ttk.Label(
            status_bar,
            text="Choose audio → Transcribe. CPU mode is on by default (medium model may take a few minutes).",
        )
        self.status.pack(side=tk.LEFT, fill=tk.X, expand=True)
        
        build_lbl = ttk.Label(
            status_bar,
            text="Version 2.1.0 (Build 2026.0529)",
            foreground="gray",
            font=("Helvetica", 9)
        )
        build_lbl.pack(side=tk.RIGHT)

        self.progress_frame = ttk.Frame(root)
        self.progress = ttk.Progressbar(self.progress_frame, orient=tk.HORIZONTAL, mode='determinate')
        self.progress.pack(side=tk.LEFT, fill=tk.X, expand=True)
        self.progress_lbl = ttk.Label(self.progress_frame, text="0%", width=6, anchor=tk.E, font=("Helvetica", 10, "bold"))
        self.progress_lbl.pack(side=tk.RIGHT, padx=(8, 0))
        
        self._refresh_speakers_list()

    def _on_diarize_toggle(self) -> None:
        self.cfg["diarize_enabled"] = self.diarize_enabled.get()
        save_config(self.cfg)

    def _refresh_speakers_list(self) -> None:
        # Check if sherpa is available to determine active speakers_dir
        sherpa_available = False
        try:
            import sherpa_onnx
            model_path = Path.home() / ".config" / "whisper-gui" / "models" / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
            if model_path.is_file():
                sherpa_available = True
        except ImportError:
            pass

        base_dir = Path.home() / ".config" / "whisper-gui" / "speakers"
        speakers_dir = base_dir / "sherpa" if sherpa_available else base_dir
        
        if speakers_dir.is_dir():
            sigs = []
            for p in speakers_dir.iterdir():
                if p.suffix == ".sig":
                    stem = p.stem
                    is_temp = stem.startswith("Speaker ") and stem[8:].isdigit()
                    if not is_temp:
                        sigs.append(stem)
            if sigs:
                self.registered_speakers_str.set("Registered: " + ", ".join(sorted(sigs)))
                return
        self.registered_speakers_str.set("None registered")

    def _get_mac_contacts(self) -> List[str]:
        script = 'tell application "Contacts" to get name of every person'
        try:
            import subprocess
            proc = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=3)
            if proc.returncode == 0:
                names = proc.stdout.strip().split(', ')
                return sorted(list(set([n.strip() for n in names if n.strip()])))
        except Exception:
            pass
        return []

    def _extract_speaker(self, line: str) -> Optional[str]:
        trimmed = line.strip()
        if not trimmed:
            return None
        lower_trimmed = trimmed.lower()
        for prefix in ("file:", "path:", "tags:", "created:", "note:", "title:", "source_file:", "---"):
            if lower_trimmed.startswith(prefix):
                return None
        colon_idx = trimmed.find(":")
        if colon_idx != -1:
            speaker_part = trimmed[:colon_idx].strip()
            if 0 < len(speaker_part) < 30 and not any(char in speaker_part for char in "[]<>-"):
                if not speaker_part.replace(".", "").isdigit():
                    return speaker_part
        return None

    def _get_speaker_colors(self, speaker_name: Optional[str]) -> Tuple[str, str]:
        if not speaker_name or speaker_name == "Unknown Speaker":
            return "#f5f5f5", "#e0e0e0"
        
        colors = [
            ("#eef6ff", "#bde0fe"), # Blue
            ("#f0fff4", "#bbf7d0"), # Green
            ("#faf5ff", "#f3e8ff"), # Purple
            ("#fffaf0", "#ffedd5"), # Orange
            ("#fff5f7", "#fce7f3"), # Pink
            ("#f0fdfa", "#ccfbf1"), # Cyan
        ]
        h = sum(ord(c) for c in speaker_name)
        return colors[h % len(colors)]



    def _path_row(self, parent: ttk.Frame, label: str, var: tk.StringVar, pick) -> None:
        row = ttk.Frame(parent)
        row.pack(fill=tk.X, pady=2)
        ttk.Label(row, text=label, width=10).pack(side=tk.LEFT)
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
            self.original_source_path = path
            self._setup_preview_player(path)

    def _pick_cli(self) -> None:
        path = filedialog.askopenfilename(title="whisper-cli binary")
        if path:
            self.cli_path.set(path)

    def _check_whisper_update(self) -> None:
        self.update_btn.configure(state=tk.DISABLED, text="Checking...")
        self.update_idletasks()
        
        def worker():
            import subprocess
            from shutil import which
            # Find brew path
            brew_path = "/opt/homebrew/bin/brew"
            if not os.path.exists(brew_path):
                if os.path.exists("/usr/local/bin/brew"):
                    brew_path = "/usr/local/bin/brew"
                else:
                    brew_path = which("brew") or "brew"
            
            try:
                env = os.environ.copy()
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
                res = subprocess.run([brew_path, "info", "whisper-cpp"], capture_output=True, text=True, env=env)
                output = res.stdout + "\n" + res.stderr
                output = output.strip()
                if not output:
                    output = "No output from brew info."
            except Exception as e:
                output = f"Could not run brew: {e}\n\nMake sure Homebrew is installed and on your PATH."
            
            def done():
                self.update_btn.configure(state=tk.NORMAL, text="Check Whisper Update")
                from tkinter import messagebox
                messagebox.showinfo("Whisper Update Check", output)
            self.after(0, done)
            
        import threading
        threading.Thread(target=worker, daemon=True).start()

    def _check_sherpa_update(self) -> None:
        self.sherpa_update_btn.configure(state=tk.DISABLED, text="Checking...")
        self.update_idletasks()
        
        def worker():
            import sys
            import urllib.request
            import json
            try:
                import sherpa_onnx
                curr = sherpa_onnx.__version__
            except ImportError:
                output = "sherpa-onnx is not installed.\n\nTo install, run:\npip3 install sherpa-onnx --break-system-packages"
                curr = None
                
            if curr:
                try:
                    req = urllib.request.Request('https://pypi.org/pypi/sherpa-onnx/json', headers={'User-Agent': 'Mozilla/5.0'})
                    latest = json.loads(urllib.request.urlopen(req, timeout=5).read().decode())['info']['version']
                    if curr == latest:
                        output = f"sherpa-onnx is up-to-date (version: {curr})."
                    else:
                        output = f"Update available for sherpa-onnx!\n\nInstalled: {curr}\nLatest: {latest}\n\nTo upgrade, run:\npip3 install sherpa-onnx --upgrade --break-system-packages"
                except Exception as e:
                    output = f"Installed: {curr}\n\nFailed to check PyPI for updates: {e}"
                    
            def done():
                self.sherpa_update_btn.configure(state=tk.NORMAL, text="Check Sherpa Update")
                from tkinter import messagebox
                messagebox.showinfo("Sherpa-ONNX Update Check", output)
            self.after(0, done)
            
        import threading
        threading.Thread(target=worker, daemon=True).start()

    def _check_dependencies(self) -> None:
        import subprocess
        from shutil import which
        
        def worker():
            report = "=== DEPENDENCY DIAGNOSTICS ===\n\n"
            report += "● Whisper GUI Version: 1.2.0\n"
            report += "   Status: Active & running\n\n"
            
            brew_path = "/opt/homebrew/bin/brew"
            if not os.path.exists(brew_path):
                if os.path.exists("/usr/local/bin/brew"):
                    brew_path = "/usr/local/bin/brew"
                else:
                    brew_path = which("brew") or "brew"
            
            if which("brew") or os.path.exists("/opt/homebrew/bin/brew") or os.path.exists("/usr/local/bin/brew"):
                report += f"✔ Homebrew: Found\n"
            else:
                report += "✘ Homebrew: Not found in PATH\n"
                
            ffmpeg_val = self.ffmpeg_path.get().strip()
            if os.path.exists(ffmpeg_val) or which("ffmpeg"):
                report += f"✔ ffmpeg: Found\n"
            else:
                report += f"✘ ffmpeg: Not found\n"
                
            cli_val = self.cli_path.get().strip()
            if os.path.exists(cli_val) or which("whisper-cli"):
                report += f"✔ whisper-cli: Found\n"
            else:
                report += f"✘ whisper-cli: Not found\n"
                
            python_path = sys.executable
            report += f"✔ Python 3: Found at {python_path}\n"
            try:
                import sherpa_onnx
                report += f"   - sherpa-onnx: Found version {sherpa_onnx.__version__}\n"
            except ImportError:
                report += "   - sherpa-onnx: Not found (Optional - run 'pip install sherpa-onnx' for advanced speaker profiling)\n"
            
            engine_path = Path(__file__).parent / "speaker_engine.py"
            if engine_path.is_file():
                report += f"✔ Speaker Engine: Found at {engine_path}\n"
            else:
                report += "✘ Speaker Engine: Not found (diarization disabled)\n"
                
            try:
                env = os.environ.copy()
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
                res = subprocess.run([brew_path, "info", "whisper-cpp"], capture_output=True, text=True, env=env)
                if res.returncode == 0 and res.stdout:
                    first_lines = "\n".join(res.stdout.splitlines()[:3])
                    report += f"\n==> Brew whisper-cpp Info:\n{first_lines}\n"
            except Exception:
                pass
                
            def done():
                from tkinter import messagebox
                messagebox.showinfo("Dependency Diagnostics", report)
            self.after(0, done)
            
        import threading
        threading.Thread(target=worker, daemon=True).start()

    def _animate_run_btn(self, phase=0) -> None:
        if not getattr(self, "is_transcribing", False):
            self.run_btn.configure(text="Transcribe")
            return
            
        spinners = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        spinner = spinners[phase % len(spinners)]
        indicator = "⚡" if (phase // 3) % 2 == 0 else "✨"
        self.run_btn.configure(text=f"{indicator} {spinner} Transcribing...")
        self.after(100, lambda: self._animate_run_btn(phase + 1))

    def _pick_model(self) -> None:
        path = filedialog.askopenfilename(
            title="Model (.bin)",
            filetypes=[("GGML model", "*.bin"), ("All files", "*.*")],
        )
        if path:
            self.model_path.set(path)

    def _pick_obsidian_vault(self) -> None:
        path = filedialog.askdirectory(title="Choose Obsidian Vault Folder")
        if path:
            self.obsidian_vault_path.set(path)
            self.status.configure(text=f"Obsidian Vault linked: {os.path.basename(path)}")
            self._persist()

    def _scan_obsidian_tags(self, vault_path: str) -> List[str]:
        import re
        unique_tags = set()
        inline_pat = re.compile(r"#([a-zA-Z][a-zA-Z0-9_\-\/]*)")
        
        for root, dirs, files in os.walk(vault_path):
            dirs[:] = [d for d in dirs if not d.startswith(".")]
            for file in files:
                if not file.lower().endswith(".md"):
                    continue
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read()
                except OSError:
                    continue
                
                lines = content.splitlines()
                in_frontmatter = False
                frontmatter_lines = []
                for line in lines:
                    trimmed = line.strip()
                    if trimmed == "---":
                        if in_frontmatter:
                            break
                        else:
                            in_frontmatter = True
                            continue
                    if in_frontmatter:
                        frontmatter_lines.append(line)
                        
                frontmatter_tags = []
                yaml_in_tag_block = False
                for fm_line in frontmatter_lines:
                    trimmed = fm_line.strip()
                    if trimmed.lower().startswith("tags:") or trimmed.lower().startswith("tag:"):
                        parts = fm_line.split(":", 1)
                        if len(parts) > 1:
                            val = parts[1].strip()
                            if val.startswith("[") and val.endswith("]"):
                                array_parts = [p.strip() for p in val[1:-1].split(",") if p.strip()]
                                frontmatter_tags.extend(array_parts)
                            elif val:
                                frontmatter_tags.append(val)
                            else:
                                yaml_in_tag_block = True
                    elif yaml_in_tag_block:
                        if trimmed.startswith("-"):
                            val = trimmed[1:].strip()
                            frontmatter_tags.extend([val])
                        elif ":" in fm_line:
                            yaml_in_tag_block = False
                            
                for t in frontmatter_tags:
                    cleaned = t.strip().replace("#", "")
                    if cleaned:
                        unique_tags.add(cleaned.lower())
                        
                matches = inline_pat.findall(content)
                for t in matches:
                    unique_tags.add(t.lower())
                    
        return sorted(list(unique_tags))

    def _import_obsidian_tags(self) -> None:
        self._persist()
        path = self.obsidian_vault_path.get().strip()
        if not path:
            messagebox.showwarning("Obsidian", "Please configure your Obsidian Vault path under the Options tab first.")
            return
            
        self.status.configure(text="Scanning Obsidian Vault for tags…")
        self.update_idletasks()
        
        def worker():
            tags = self._scan_obsidian_tags(path)
            def update_ui():
                if not tags:
                    self.status.configure(text="No tags found in the linked vault.")
                    messagebox.showinfo("Obsidian", f"No tags discovered inside Obsidian vault:\n{path}\n\nAdd tags with #tag or in frontmatter tags: [tag] inside your .md notes.")
                else:
                    merged = list(self.tag_options)
                    for t in tags:
                        if t not in merged:
                            merged.append(t)
                    original = ["meeting", "conference", "bank", "lecture", "interview", "podcast"]
                    new_ones = sorted([t for t in merged if t not in original])
                    self.tag_options = original + new_ones
                    self.status.configure(text=f"Imported {len(tags)} tags from Obsidian!")
                    messagebox.showinfo("Obsidian", f"Successfully imported {len(tags)} unique tags from your Obsidian Vault! Click 'Choose...' to select them.")
            self.after(0, update_ui)
            
        threading.Thread(target=worker, daemon=True).start()

    def _auto_discover_obsidian_vault(self) -> None:
        if self.obsidian_vault_path.get().strip():
            return
        
        config_path = Path.home() / "Library" / "Application Support" / "obsidian" / "obsidian.json"
        if not config_path.is_file():
            return
            
        try:
            data = json.loads(config_path.read_text(encoding="utf-8"))
            vaults = data.get("vaults", {})
            sorted_vaults = sorted(
                vaults.values(),
                key=lambda v: v.get("ts", 0),
                reverse=True
            )
            if sorted_vaults:
                path = sorted_vaults[0].get("path", "")
                if path:
                    self.obsidian_vault_path.set(path)
                    self._persist()
                    vault_name = os.path.basename(path)
                    self.status.configure(text=f"Auto-detected Obsidian Vault: {vault_name}")
        except Exception:
            pass

    def _save_to_obsidian(self, text: str, note_name: str, tags: str, source_file: str) -> None:
        vault_path = self.obsidian_vault_path.get().strip()
        if not vault_path or not self.obsidian_save_directly.get():
            return
            
        if not os.path.isdir(vault_path):
            return
            
        subfolder = self.obsidian_folder.get().strip() or "Transcriptions"
        target_dir = os.path.join(vault_path, subfolder)
        
        try:
            os.makedirs(target_dir, exist_ok=True)
        except OSError as e:
            self._append_log(f"\nFailed to create Obsidian folder: {e}\n")
            return
            
        import datetime
        now = datetime.datetime.now()
        date_time_str = now.strftime("%Y-%m-%d %H.%m")
        
        clean_note_name = f"Transcription {date_time_str}"
        custom_note_name = note_name.strip()
        if custom_note_name:
            clean_note_name += f" - {custom_note_name}"
            
        import re
        clean_note_name = re.sub(r'[\\/*?:"<>|#^\[\]]', '_', clean_note_name)
        if not clean_note_name:
            clean_note_name = "Transcription"
            
        file_path = os.path.join(target_dir, f"{clean_note_name}.md")
        
        content = "---\n"
        tag_list = [t.strip() for t in tags.split(",") if t.strip()]
        if tag_list:
            content += "tags:\n"
            for t in tag_list:
                content += f"  - {t.lower()}\n"
                
        date_str = now.strftime("%Y-%m-%dT%H:%M:%S")
        content += f"created: {date_str}\n"
        content += f"source_file: {source_file if source_file else 'None'}\n"
        content += "---\n\n"
        
        content += f"# Transcription - {date_time_str}\n"
        if custom_note_name:
            content += f"## Note: {custom_note_name}\n"
            
        audio_name = os.path.basename(source_file) if source_file else ""
        content += f"**Source Audio File:** `{audio_name}`\n"
        content += f"**Path:** `{source_file}`\n\n"
        content += "----------------------------------------\n\n"
        content += text
        
        try:
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(content)
            self._append_log(f"\n[Obsidian] Note saved successfully:\n{subfolder}/{clean_note_name}.md\n")
        except OSError as e:
            self._append_log(f"\n[Obsidian] Failed to save note: {e}\n")

    def _choose_tags(self) -> None:
        menu = tk.Menu(self, tearoff=0)
        current_tags = [t.strip().lower() for t in self.tags_str.get().split(",") if t.strip()]
        
        def toggle_tag(tag: str):
            tags = [t.strip() for t in self.tags_str.get().split(",") if t.strip()]
            tag_lower = tag.lower()
            existing_match = next((t for t in tags if t.lower() == tag_lower), None)
            if existing_match:
                tags.remove(existing_match)
            else:
                tags.append(tag)
            self.tags_str.set(", ".join(tags))
            
        for option in self.tag_options:
            is_active = option.lower() in current_tags
            menu.add_checkbutton(
                label=option,
                onvalue=True,
                offvalue=False,
                variable=tk.BooleanVar(value=is_active),
                command=lambda opt=option: toggle_tag(opt)
            )
            
        try:
            x = self.tags_entry.winfo_rootx()
            y = self.tags_entry.winfo_rooty() + self.tags_entry.winfo_height()
            menu.post(x, y)
        except tk.TclError:
            pass

    def _persist(self) -> None:
        try:
            thresh_val = float(self.diarize_threshold.get())
        except (tk.TclError, ValueError):
            thresh_val = 0.65
            
        try:
            max_spk_val = max(0, int(self.diarize_speakers.get()))
        except (tk.TclError, ValueError):
            max_spk_val = 0

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
                "obsidian_vault_path": self.obsidian_vault_path.get().strip(),
                "obsidian_save_directly": self.obsidian_save_directly.get(),
                "obsidian_folder": self.obsidian_folder.get().strip() or "Transcriptions",
                "diarize_threshold": thresh_val,
                "diarize_speakers": max_spk_val,
            }
        )
        save_config(self.cfg)

    def _build_cmd(self, audio: Path) -> List[str]:
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
        if self.no_timestamps.get() and not self.diarize_enabled.get():
            cmd.append("-nt")
        if self.output_txt.get():
            cmd.append("-otxt")
        if self.output_srt.get():
            cmd.append("-osrt")
        if self.output_vtt.get():
            cmd.append("-ovtt")
        if self.output_json.get():
            cmd.append("-oj")

        custom_name = self.custom_name.get().strip()
        if custom_name:
            stem = audio.parent / custom_name
        else:
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
        if not self.original_source_path:
            self.original_source_path = str(audio_path)

        self._stop_preview_player()
        self._stop_browser_player()

        if getattr(self, "is_transcribing", False):
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
        self.is_transcribing = True
        self._animate_run_btn()
        self.stop_btn.configure(state=tk.NORMAL)
        mode = "GPU" if self.use_gpu.get() else "CPU"
        self.status.configure(text=f"Transcribing on {mode}… (please wait)")
        pad = {"padx": 10, "pady": 4}
        self.progress_frame.pack(fill=tk.X, before=self.status, **pad)
        self.progress['value'] = 0
        self.progress_lbl.configure(text="0%")
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
            self.progress_frame.pack_forget()
        self.is_transcribing = False
        self.run_btn.configure(state=tk.NORMAL)

    def _poll_log(self) -> None:
        try:
            while True:
                item = self._log_queue.get_nowait()
                if isinstance(item, tuple) and item[0] == "done":
                    code = item[1]
                    self.stop_btn.configure(state=tk.DISABLED)
                    if not self.diarize_enabled.get() or code != 0:
                        self.is_transcribing = False
                        self.run_btn.configure(state=tk.NORMAL)
                    self._on_finished(code)
                    continue
                log_chunk = str(item)
                self._append_log(log_chunk)
                
                # Parse progress
                matches = self.progress_pat.findall(log_chunk)
                if matches:
                    pct = int(matches[-1])
                    self.progress['value'] = pct
                    self.progress_lbl.configure(text=f"{pct}%")
        except queue.Empty:
            pass
        self.after(80, self._poll_log)

    def _on_finished(self, code: int) -> None:
        self.progress_frame.pack_forget()
        if code == 0:
            if self.diarize_enabled.get():
                self._run_diarization_and_load()
            else:
                self._load_transcript_file()
                self.status.configure(text="Done.")
            return
        if code < 0:
            code = 256 + code
        hint = ""
        if code in (139, -11) and self.use_gpu.get():
            hint = "\n\nTip: turn off “Use GPU” to run on CPU."
        elif code in (139, -11):
            hint = "\n\nThe process crashed. Check the log above."
        self._load_transcript_file()
        self.status.configure(text=f"Failed (exit {code}).")
        messagebox.showerror("Whisper", f"whisper-cli exited with code {code}.{hint}")

    def _run_diarization_and_load(self) -> None:
        stem = self._output_stem
        audio = self.audio_path.get().strip()
        if not stem or not audio:
            self._load_transcript_file()
            self.status.configure(text="Done.")
            return
            
        engine_path = Path(__file__).parent / "speaker_engine.py"
        if not engine_path.is_file():
            self._load_transcript_file()
            self.status.configure(text="Done (Speaker Engine not found).")
            return
            
        # Extract timestamped lines from log
        log_content = self.log.get("1.0", tk.END)
        import re
        pat = re.compile(
            r"\[\d{2}:\d{2}:\d{2}\.\d{3}\s*-+>\s*\d{2}:\d{2}:\d{2}\.\d{3}\]|\[\d{2}:\d{2}\.\d{3}\s*-+>\s*\d{2}:\d{2}\.\d{3}\]"
        )
        timestamped_lines = []
        for line in log_content.splitlines():
            trimmed = line.strip()
            if pat.search(trimmed):
                timestamped_lines.append(trimmed)
                
        if not timestamped_lines:
            self._append_log("Diarization skipped: No timestamped segments found in the transcription log.\n")
            self._load_transcript_file()
            self.is_transcribing = False
            self.run_btn.configure(state=tk.NORMAL)
            self.status.configure(text="Done (No timestamps found in log).")
            return
            
        txt_path = stem.with_suffix(".txt")
        try:
            txt_path.write_text("\n".join(timestamped_lines), encoding="utf-8")
        except Exception as e:
            self._append_log(f"Failed to write timestamped transcript: {e}\n")
            self.status.configure(text="Failed to write timestamped transcript.")
            self._load_transcript_file()
            self.is_transcribing = False
            self.run_btn.configure(state=tk.NORMAL)
            return
            
        self.status.configure(text="Running speaker diarization...")
        self.update_idletasks()
        
        self._append_log("\n--- speaker diarization ---\n")
        self._append_log(f"Transcript path: {txt_path}\n")
        self._append_log(f"Audio path: {audio}\n")
        self._append_log(f"Extracted {len(timestamped_lines)} timestamped lines for diarization.\n")
        
        def worker():
            try:
                threshold_val = float(self.diarize_threshold.get())
            except (tk.TclError, ValueError):
                threshold_val = 0.65
                
            try:
                max_spk_val = max(0, int(self.diarize_speakers.get()))
            except (tk.TclError, ValueError):
                max_spk_val = 0

            cmd = [
                sys.executable,
                str(engine_path),
                "--diarize",
                str(txt_path),
                audio,
                "--threshold",
                str(threshold_val),
                "--max-speakers",
                str(max_spk_val),
            ]
            self.after(0, lambda: self._append_log(f"Running: {' '.join(cmd)}\n\n"))
            
            try:
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                if proc.stdout:
                    for line in proc.stdout:
                        self.after(0, lambda l=line: self._append_log(l))
                proc.wait()
                
                def done():
                    self._load_transcript_file()
                    self.is_transcribing = False
                    self.run_btn.configure(state=tk.NORMAL)
                    if proc.returncode == 0:
                        self._append_log("\nDiarization process completed successfully.\n")
                        self.status.configure(text="Done with speaker recognition.")
                    else:
                        self._append_log(f"\nDiarization process exited with non-zero code {proc.returncode}\n")
                        self.status.configure(text=f"Speaker recognition failed (exit {proc.returncode}).")
                self.after(0, done)
            except Exception as e:
                self.after(0, lambda: self._append_log(f"Diarization launch failed: {e}\n"))
                def done_err():
                    self._load_transcript_file()
                    self.is_transcribing = False
                    self.run_btn.configure(state=tk.NORMAL)
                    self.status.configure(text="Diarization launch failed.")
                self.after(0, done_err)
            
        import threading
        threading.Thread(target=worker, daemon=True).start()

    def _make_transcript_header(self) -> str:
        audio = self.audio_path.get().strip()
        path = getattr(self, "original_source_path", None) or audio
        if not path or not os.path.exists(path):
            return ""
        
        filename = os.path.basename(path)
        date_str = "Unknown"
        try:
            stat_info = os.stat(path)
            birthtime = getattr(stat_info, "st_birthtime", stat_info.st_mtime)
            import datetime
            dt = datetime.datetime.fromtimestamp(birthtime)
            date_str = dt.strftime("%b %d, %Y at %I:%M:%S %p")
        except Exception:
            pass
            
        header = f"File: {filename}\n"
        note_name = self.note_name.get().strip()
        if note_name:
            header += f"Note: {note_name}\n"
        custom_title = self.custom_name.get().strip()
        if custom_title:
            header += f"Title: {custom_title}\n"
        selected_tags = self.tags_str.get().strip()
        if selected_tags:
            header += f"Tags: {selected_tags}\n"
        header += f"Created: {date_str}\n"
        header += "----------------------------------------\n\n\n"
        return header

    def _load_transcript_file(self) -> None:
        stem = self._output_stem
        if not stem:
            return
        header = self._make_transcript_header()
        for ext in (".txt", ".srt", ".json"):
            path = stem.with_suffix(ext)
            if path.is_file():
                try:
                    text = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                
                if ext == ".txt":
                    if not (text.startswith("File: ") and "----------------------------------------" in text[:200]):
                        text = header + text
                        try:
                            path.write_text(text, encoding="utf-8")
                        except OSError:
                            pass
                        note_text = text
                    else:
                        note_text = text
                        if "----------------------------------------\n\n\n" in text:
                            note_text = text.split("----------------------------------------\n\n\n", 1)[1]
                else:
                    text = header + text
                    note_text = text

                self.transcript.delete("1.0", tk.END)
                self.transcript.insert("1.0", text)
                self.status.configure(text=f"Done — loaded {path.name}")
                self._save_to_obsidian(note_text, self.note_name.get(), self.tags_str.get(), self.audio_path.get())
                return
        # Parse transcript lines from log (lines starting with [)
        log_text = self.log.get("1.0", tk.END)
        lines = [
            ln
            for ln in log_text.splitlines()
            if ln.startswith("[") and "]" in ln[:12]
        ]
        if lines:
            fallback = "\n".join(lines)
            self.transcript.delete("1.0", tk.END)
            self.transcript.insert("1.0", header + fallback)
            self._save_to_obsidian(fallback, self.note_name.get(), self.tags_str.get(), self.audio_path.get())

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

    def _on_tab_changed(self, event) -> None:
        selected_tab = self.notebook.select()
        if selected_tab:
            tab_text = self.notebook.tab(selected_tab, "text")
            if tab_text == "Browser":
                self._refresh_browser_files()

    def _build_browser_ui(self, parent: ttk.Frame) -> None:
        paned = ttk.PanedWindow(parent, orient=tk.HORIZONTAL)
        paned.pack(fill=tk.BOTH, expand=True)

        sidebar = ttk.Frame(paned, padding=(0, 0, 8, 0))
        paned.add(sidebar, weight=1)

        dir_row = ttk.Frame(sidebar)
        dir_row.pack(fill=tk.X, pady=(0, 6))

        choose_btn = ttk.Button(dir_row, text="Choose Folder…", command=self._choose_browser_dir)
        choose_btn.pack(side=tk.LEFT)

        refresh_btn = ttk.Button(dir_row, text="Refresh", command=self._refresh_browser_files)
        refresh_btn.pack(side=tk.LEFT, padx=(6, 6))

        self.browser_path_lbl = ttk.Label(dir_row, font=("Helvetica", 10), foreground="gray")
        self.browser_path_lbl.pack(side=tk.LEFT, fill=tk.X, expand=True)

        list_frame = ttk.Frame(sidebar)
        list_frame.pack(fill=tk.BOTH, expand=True)

        self.browser_listbox = tk.Listbox(
            list_frame,
            font=("Helvetica", 12),
            activestyle="none",
            selectmode=tk.SINGLE,
            highlightthickness=1,
            highlightbackground="#cccccc",
            bd=0
        )
        list_scroll = ttk.Scrollbar(list_frame, orient=tk.VERTICAL, command=self.browser_listbox.yview)
        self.browser_listbox.configure(yscrollcommand=list_scroll.set)

        self.browser_listbox.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        list_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.browser_listbox.bind("<<ListboxSelect>>", self._browser_file_selected)

        content_pane = ttk.Frame(paned, padding=(8, 0, 0, 0))
        paned.add(content_pane, weight=2)

        actions_row = ttk.Frame(content_pane)
        actions_row.pack(fill=tk.X, pady=(0, 6))

        self.browser_copy_btn = ttk.Button(
            actions_row, text="Copy", command=self._copy_browser_content, state=tk.DISABLED
        )
        self.browser_copy_btn.pack(side=tk.LEFT)

        self.browser_reveal_btn = ttk.Button(
            actions_row, text="Reveal in Finder", command=self._reveal_browser_file, state=tk.DISABLED
        )
        self.browser_reveal_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.browser_share_btn = ttk.Button(
            actions_row, text="Share", command=self._share_browser_content, state=tk.DISABLED
        )
        self.browser_share_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.browser_delete_btn = ttk.Button(
            actions_row, text="Delete", command=self._delete_browser_file, state=tk.DISABLED
        )
        self.browser_delete_btn.pack(side=tk.LEFT, padx=(6, 0))

        self.browser_rename_spk_btn = ttk.Button(
            actions_row, text="Rename Speaker…", command=self._rename_speaker, state=tk.DISABLED
        )
        self.browser_rename_spk_btn.pack(side=tk.LEFT, padx=(6, 0))

        # Setup Browser Tab Synchronized Player UI
        self.browser_player_frame = ttk.Frame(content_pane)
        self.browser_player_frame.pack(fill=tk.X, pady=(0, 6))
        
        browser_lbl = ttk.Label(self.browser_player_frame, text="Sync Play", width=10)
        browser_lbl.pack(side=tk.LEFT)
        
        self.browser_play_btn = ttk.Button(self.browser_player_frame, text="▶", width=3, state=tk.DISABLED, command=self._play_pause_browser)
        self.browser_play_btn.pack(side=tk.LEFT, padx=(8, 0))
        
        self.browser_slider = ttk.Scale(self.browser_player_frame, from_=0, to=100, state=tk.DISABLED, command=self._seek_browser)
        self.browser_slider.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(8, 8))
        
        self.browser_time_lbl = ttk.Label(self.browser_player_frame, text="No active audio loaded", width=25, anchor=tk.E)
        self.browser_time_lbl.pack(side=tk.LEFT)

        self.browser_text_frame = ttk.Frame(content_pane)
        self.browser_text_frame.pack(fill=tk.BOTH, expand=True)

        self.browser_text = tk.Text(
            self.browser_text_frame,
            wrap=tk.WORD,
            font=("Helvetica", 14),
            state=tk.DISABLED,
            highlightthickness=1,
            highlightbackground="#cccccc",
            bd=0
        )
        text_scroll = ttk.Scrollbar(self.browser_text_frame, orient=tk.VERTICAL, command=self.browser_text.yview)
        self.browser_text.configure(yscrollcommand=text_scroll.set)

        self.browser_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        text_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        
        self.browser_text.bind("<ButtonRelease-1>", self._browser_text_clicked)

    def _refresh_browser_files(self) -> None:
        path = Path(self.browser_dir)
        try:
            path.mkdir(parents=True, exist_ok=True)
        except Exception:
            path = Path.home()
            self.browser_dir = str(path)

        # Truncate head of path if it's too long
        display_path = str(path)
        if len(display_path) > 40:
            display_path = "…" + display_path[-37:]
        self.browser_path_lbl.configure(text=display_path)

        self.browser_listbox.delete(0, tk.END)

        files = []
        try:
            for item in path.iterdir():
                if item.is_file() and item.suffix.lower() in (".txt", ".srt", ".vtt"):
                    files.append(item)
        except OSError:
            pass

        def get_mod_time(p: Path) -> float:
            try:
                return p.stat().st_mtime
            except Exception:
                return 0.0

        files.sort(key=get_mod_time, reverse=True)
        self.browser_files = [str(f) for f in files]

        if not self.browser_files:
            self.browser_copy_btn.configure(state=tk.DISABLED)
            self.browser_reveal_btn.configure(state=tk.DISABLED)
            self.browser_delete_btn.configure(state=tk.DISABLED)
            self.browser_rename_spk_btn.configure(state=tk.DISABLED)
            self._set_browser_text("")
            return

        for f_path in self.browser_files:
            p = Path(f_path)
            date_str = ""
            try:
                mtime = p.stat().st_mtime
                import datetime
                dt = datetime.datetime.fromtimestamp(mtime)
                date_str = dt.strftime("%m/%d/%y, %I:%M %p")
            except Exception:
                pass
            
            display_name = p.name + (f"  ({date_str})" if date_str else "")
            self.browser_listbox.insert(tk.END, display_name)

        if self.browser_selected_path and self.browser_selected_path in self.browser_files:
            idx = self.browser_files.index(self.browser_selected_path)
            self.browser_listbox.selection_set(idx)
            self.browser_listbox.see(idx)
            self.browser_listbox.activate(idx)
        else:
            self.browser_selected_path = None
            self.browser_copy_btn.configure(state=tk.DISABLED)
            self.browser_reveal_btn.configure(state=tk.DISABLED)
            self.browser_delete_btn.configure(state=tk.DISABLED)
            self.browser_rename_spk_btn.configure(state=tk.DISABLED)
            self._set_browser_text("")

    def _browser_file_selected(self, event) -> None:
        selection = self.browser_listbox.curselection()
        if not selection:
            return
        
        idx = selection[0]
        if idx >= len(self.browser_files):
            return
            
        file_path = self.browser_files[idx]
        self.browser_selected_path = file_path

        p = Path(file_path)
        try:
            content = p.read_text(encoding="utf-8", errors="replace")
            self._set_browser_text(content)
            self.browser_copy_btn.configure(state=tk.NORMAL)
            self.browser_reveal_btn.configure(state=tk.NORMAL)
            self.browser_share_btn.configure(state=tk.NORMAL)
            self.browser_delete_btn.configure(state=tk.NORMAL)
            self.browser_rename_spk_btn.configure(state=tk.NORMAL)
            
            # Setup browser player
            self._setup_browser_player(content)
            
        except Exception as e:
            self._set_browser_text(f"Error loading file: {e}")
            self.browser_copy_btn.configure(state=tk.DISABLED)
            self.browser_reveal_btn.configure(state=tk.DISABLED)
            self.browser_share_btn.configure(state=tk.DISABLED)
            self.browser_delete_btn.configure(state=tk.DISABLED)
            self.browser_rename_spk_btn.configure(state=tk.DISABLED)
            self._disable_browser_player()

    def _set_browser_text(self, text: str) -> None:
        self.browser_text.configure(state=tk.NORMAL)
        self.browser_text.delete("1.0", tk.END)
        self.browser_text.insert("1.0", text)
        
        # Apply static speaker background coloring
        lines = text.splitlines()
        for idx, line in enumerate(lines):
            line_num = idx + 1
            speaker = self._extract_speaker(line)
            if speaker:
                bg_color, active_color = self._get_speaker_colors(speaker)
                tag_name = f"spk_{speaker}"
                self.browser_text.tag_configure(tag_name, background=bg_color)
                self.browser_text.tag_add(tag_name, f"{line_num}.0", f"{line_num}.end")
                
        self.browser_text.configure(state=tk.DISABLED)

    def _choose_browser_dir(self) -> None:
        initial = self.browser_dir if os.path.isdir(self.browser_dir) else str(Path.home())
        path = filedialog.askdirectory(title="Choose Folder", initialdir=initial)
        if path:
            self.browser_dir = path
            self.browser_selected_path = None
            self._set_browser_text("")
            self.browser_copy_btn.configure(state=tk.DISABLED)
            self.browser_reveal_btn.configure(state=tk.DISABLED)
            self.browser_share_btn.configure(state=tk.DISABLED)
            self.browser_delete_btn.configure(state=tk.DISABLED)
            self._disable_browser_player()
            self._refresh_browser_files()

    def _copy_browser_content(self) -> None:
        if not self.browser_selected_path:
            return
        content = self.browser_text.get("1.0", tk.END).strip()
        if content:
            self.clipboard_clear()
            self.clipboard_append(content)
            filename = os.path.basename(self.browser_selected_path)
            self.status.configure(text=f"Copied {filename} to clipboard.")

    def _reveal_browser_file(self) -> None:
        if not self.browser_selected_path:
            return
        subprocess.run(["open", "-R", self.browser_selected_path], check=False)

    def _share_browser_content(self) -> None:
        if not self.browser_selected_path:
            return
            
        content = self.browser_text.get("1.0", tk.END).strip()
        if not content:
            return
            
        import urllib.parse
        
        menu = tk.Menu(self, tearoff=0)
        
        def share_via_email():
            quoted_text = urllib.parse.quote(content)
            if len(quoted_text) > 1500:
                quoted_text = quoted_text[:1500] + urllib.parse.quote("\n... (truncated)")
            subprocess.run(["open", f"mailto:?body={quoted_text}"], check=False)
            
        def share_via_whatsapp():
            quoted_text = urllib.parse.quote(content)
            if len(quoted_text) > 2000:
                quoted_text = quoted_text[:2000] + urllib.parse.quote("...")
            subprocess.run(["open", f"https://api.whatsapp.com/send?text={quoted_text}"], check=False)
            
        def share_via_telegram():
            quoted_text = urllib.parse.quote(content)
            if len(quoted_text) > 2000:
                quoted_text = quoted_text[:2000] + urllib.parse.quote("...")
            subprocess.run(["open", f"https://t.me/share/url?text={quoted_text}"], check=False)
            
        menu.add_command(label="✉️ Email", command=share_via_email)
        menu.add_command(label="💬 WhatsApp", command=share_via_whatsapp)
        menu.add_command(label="✈️ Telegram", command=share_via_telegram)
        
        try:
            x = self.browser_share_btn.winfo_rootx()
            y = self.browser_share_btn.winfo_rooty() + self.browser_share_btn.winfo_height()
            menu.post(x, y)
        except tk.TclError:
            pass

    def _delete_browser_file(self) -> None:
        if not self.browser_selected_path:
            return
        filename = os.path.basename(self.browser_selected_path)
        confirm = messagebox.askyesno(
            "Delete Transcription File?",
            f"Are you sure you want to permanently delete {filename}?"
        )
        if confirm:
            try:
                os.remove(self.browser_selected_path)
                self.browser_selected_path = None
                self._set_browser_text("")
                self.browser_copy_btn.configure(state=tk.DISABLED)
                self.browser_reveal_btn.configure(state=tk.DISABLED)
                self.browser_share_btn.configure(state=tk.DISABLED)
                self.browser_delete_btn.configure(state=tk.DISABLED)
                self._disable_browser_player()
                self._refresh_browser_files()
            except Exception as e:
                messagebox.showerror("Error", f"Failed to delete file:\n{e}")

    def _register_voice(self) -> None:
        dialog = tk.Toplevel(self)
        dialog.title("Register Voice Profile")
        dialog.geometry("440x210")
        dialog.resizable(False, False)
        dialog.transient(self)
        dialog.grab_set()
        
        # Center dialog
        dialog.update_idletasks()
        w = dialog.winfo_width()
        h = dialog.winfo_height()
        extra_x = (self.winfo_width() - w) // 2
        extra_y = (self.winfo_height() - h) // 2
        dialog.geometry(f"+{self.winfo_x() + extra_x}+{self.winfo_y() + extra_y}")
        
        # Padding frame
        pad = ttk.Frame(dialog, padding=16)
        pad.pack(fill=tk.BOTH, expand=True)
        
        # 1. Contact / Name row
        row1 = ttk.Frame(pad)
        row1.pack(fill=tk.X, pady=6)
        ttk.Label(row1, text="Contact or Name:", width=15).pack(side=tk.LEFT)
        
        contacts = self._get_mac_contacts()
        name_var = tk.StringVar()
        combo = ttk.Combobox(row1, textvariable=name_var, values=contacts, width=28)
        combo.pack(side=tk.LEFT, padx=(8, 0))
        combo.set("")
        
        # 2. Audio File row
        row2 = ttk.Frame(pad)
        row2.pack(fill=tk.X, pady=6)
        ttk.Label(row2, text="Audio Sample:", width=15).pack(side=tk.LEFT)
        
        file_var = tk.StringVar()
        file_entry = ttk.Entry(row2, textvariable=file_var, width=22)
        file_entry.pack(side=tk.LEFT, padx=(8, 0))
        
        def browse_file():
            from tkinter import filedialog
            path = filedialog.askopenfilename(
                parent=dialog,
                title="Select Audio Sample",
                filetypes=[("Audio files", "*.wav *.mp3 *.m4a *.flac"), ("All files", "*.*")]
            )
            if path:
                file_var.set(path)
                
        ttk.Button(row2, text="Browse…", command=browse_file, width=8).pack(side=tk.LEFT, padx=(6, 0))
        
        # Status Label
        status_lbl = ttk.Label(pad, text="", foreground="gray", font=("Helvetica", 10))
        status_lbl.pack(fill=tk.X, pady=(6, 0))
        
        # 3. Action row
        row3 = ttk.Frame(pad)
        row3.pack(fill=tk.X, side=tk.BOTTOM, pady=(12, 0))
        
        def run_learning():
            name = name_var.get().strip()
            audio = file_var.get().strip()
            
            if not name:
                status_lbl.configure(text="⚠️ Please select a contact or enter a name.", foreground="red")
                return
            if not audio or not os.path.isfile(audio):
                status_lbl.configure(text="⚠️ Please select a valid audio file.", foreground="red")
                return
                
            status_lbl.configure(text="Extracting voice footprint and registering...", foreground="black")
            dialog.update()
            
            # Find python
            import sys
            python_path = sys.executable
            
            # Find speaker_engine.py
            engine_path = Path(__file__).parent / "speaker_engine.py"
            if not engine_path.is_file():
                # Check Resources directory inside app bundle
                engine_path = Path(sys.argv[0]).parent.parent / "Resources" / "speaker_engine.py"
                if not engine_path.is_file():
                    engine_path = Path("/Users/dfe/whisper-gui/speaker_engine.py")
                    
            cmd = [python_path, str(engine_path), "--learn", name, audio]
            
            def worker():
                try:
                    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
                    if proc.returncode == 0:
                        def success():
                            status_lbl.configure(text="✔ Successfully registered speaker profile!", foreground="green")
                            self._refresh_speakers_list()
                            dialog.after(1200, dialog.destroy)
                        dialog.after(0, success)
                    else:
                        err = proc.stderr.strip() or proc.stdout.strip() or "Registration failed"
                        def fail(msg=err):
                            status_lbl.configure(text=f"✘ Error: {msg}", foreground="red")
                            submit_btn.configure(state=tk.NORMAL)
                        dialog.after(0, fail)
                except Exception as e:
                    def error_cb(msg=str(e)):
                        status_lbl.configure(text=f"✘ Error: {msg}", foreground="red")
                        submit_btn.configure(state=tk.NORMAL)
                    dialog.after(0, error_cb)
            
            submit_btn.configure(state=tk.DISABLED)
            import threading
            threading.Thread(target=worker, daemon=True).start()
            
        submit_btn = ttk.Button(row3, text="Extract & Register", command=run_learning)
        submit_btn.pack(side=tk.RIGHT, padx=(6, 0))
        
        ttk.Button(row3, text="Cancel", command=dialog.destroy).pack(side=tk.RIGHT)

    def _rename_speaker(self) -> None:
        if not self.browser_selected_path:
            return
            
        content = self.browser_text.get("1.0", tk.END)
        lines = content.splitlines()
        
        # 1. Scan the file for all unique speakers
        speakers = set()
        for line in lines:
            spk = self._extract_speaker(line)
            if spk:
                speakers.add(spk)
                
        if not speakers:
            messagebox.showinfo("Rename Speaker", "No speakers found in this transcript to rename.")
            return

        # Create custom dialog
        dialog = tk.Toplevel(self)
        dialog.title("Rename Speaker")
        dialog.geometry("420x180")
        dialog.resizable(False, False)
        dialog.transient(self)
        dialog.grab_set()
        
        # Center dialog
        dialog.update_idletasks()
        w = dialog.winfo_width()
        h = dialog.winfo_height()
        extra_x = (self.winfo_width() - w) // 2
        extra_y = (self.winfo_height() - h) // 2
        dialog.geometry(f"+{self.winfo_x() + extra_x}+{self.winfo_y() + extra_y}")
        
        pad = ttk.Frame(dialog, padding=16)
        pad.pack(fill=tk.BOTH, expand=True)
        
        # Row 1: Old Name
        row1 = ttk.Frame(pad)
        row1.pack(fill=tk.X, pady=6)
        ttk.Label(row1, text="Speaker to rename:", width=18).pack(side=tk.LEFT)
        
        old_name_var = tk.StringVar()
        old_combo = ttk.Combobox(row1, textvariable=old_name_var, values=sorted(list(speakers)), state="readonly", width=22)
        old_combo.pack(side=tk.LEFT, padx=(8, 0))
        if speakers:
            old_combo.current(0)
            
        # Row 2: New Name
        row2 = ttk.Frame(pad)
        row2.pack(fill=tk.X, pady=6)
        ttk.Label(row2, text="Rename to:", width=18).pack(side=tk.LEFT)
        
        contacts = self._get_mac_contacts()
        new_name_var = tk.StringVar()
        new_combo = ttk.Combobox(row2, textvariable=new_name_var, values=contacts, width=22)
        new_combo.pack(side=tk.LEFT, padx=(8, 0))
        new_combo.set("")
        
        # Row 3: Action Buttons
        row3 = ttk.Frame(pad)
        row3.pack(fill=tk.X, side=tk.BOTTOM, pady=(12, 0))
        
        def submit_rename():
            old_name = old_name_var.get().strip()
            new_name = new_name_var.get().strip()
            
            if not old_name:
                return
            if not new_name:
                messagebox.showerror("Error", "Please enter a valid name.", parent=dialog)
                return
                
            import re
            new_name_clean = re.sub(r'[^a-zA-Z0-9_\- ]', '', new_name)
            if not new_name_clean:
                messagebox.showerror("Error", "Invalid name. Use alphanumeric characters only.", parent=dialog)
                return
                
            # Perform Rename logic
            sherpa_available = False
            try:
                import sherpa_onnx
                model_path = Path.home() / ".config" / "whisper-gui" / "models" / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
                if model_path.is_file():
                    sherpa_available = True
            except ImportError:
                pass

            base_dir = Path.home() / ".config" / "whisper-gui" / "speakers"
            speakers_dir = base_dir / "sherpa" if sherpa_available else base_dir
            
            old_sig = speakers_dir / f"{old_name}.sig"
            new_sig = speakers_dir / f"{new_name_clean}.sig"
            
            if old_sig.is_file():
                try:
                    if new_sig.is_file():
                        confirm = messagebox.askyesno("Merge Speaker", f"Speaker '{new_name_clean}' already exists. Do you want to overwrite it with the voice footprint of '{old_name}'?", parent=dialog)
                        if not confirm:
                            return
                        os.remove(new_sig)
                    os.rename(old_sig, new_sig)
                except Exception as e:
                    messagebox.showerror("Error", f"Failed to rename signature file: {e}", parent=dialog)
                    return
                    
            # Replace in transcript file
            new_lines = []
            for line in lines:
                if line.startswith(f"{old_name}: "):
                    new_lines.append(line.replace(f"{old_name}: ", f"{new_name_clean}: ", 1))
                else:
                    new_lines.append(line)
                    
            new_content = "\n".join(new_lines)
            
            try:
                Path(self.browser_selected_path).write_text(new_content, encoding="utf-8")
                self._set_browser_text(new_content)
                self._refresh_speakers_list()
                self._parse_timestamps_in_browser_text(new_content)
                dialog.destroy()
                messagebox.showinfo("Success", f"Speaker '{old_name}' successfully renamed to '{new_name_clean}' and saved in system library.")
            except Exception as e:
                messagebox.showerror("Error", f"Failed to update transcript file: {e}", parent=dialog)
        
        ttk.Button(row3, text="Rename", command=submit_rename).pack(side=tk.RIGHT, padx=(6, 0))
        ttk.Button(row3, text="Cancel", command=dialog.destroy).pack(side=tk.RIGHT)

    def _on_audio_path_changed(self) -> None:
        path = self.audio_path.get().strip()
        if os.path.isfile(path):
            self._setup_preview_player(path)
        else:
            self._stop_preview_player()
            self.preview_play_btn.configure(state=tk.DISABLED)
            self.preview_slider.configure(state=tk.DISABLED)
            self.preview_time_lbl.configure(text="00:00 / 00:00")

    def _setup_preview_player(self, path: str) -> None:
        self._stop_preview_player()
        
        duration = self._get_audio_duration(path)
        if duration <= 0:
            duration = 100.0
            
        self.preview_duration = duration
        self.preview_elapsed = 0.0
        self.preview_is_paused = False
        
        self.preview_slider_updating = True
        self.preview_slider.configure(state=tk.NORMAL, to=duration)
        self.preview_slider.set(0)
        self.preview_slider_updating = False
        
        self.preview_play_btn.configure(state=tk.NORMAL, text="▶")
        self.preview_time_lbl.configure(text=f"00:00 / {self._format_time(duration)}")

    def _get_audio_duration(self, path: str) -> float:
        try:
            out = subprocess.check_output(["afinfo", path], stderr=subprocess.DEVNULL)
            out_str = out.decode("utf-8", errors="replace")
            import re
            m = re.search(r"duration:\s*([\d\.]+)", out_str)
            if m:
                return float(m.group(1))
        except Exception:
            pass
        return 0.0

    def _format_time(self, seconds: float) -> str:
        if seconds < 0 or seconds is None:
            return "00:00"
        total = int(seconds)
        mins = total // 60
        secs = total % 60
        return f"{mins:02d}:{secs:02d}"

    def _play_pause_preview(self) -> None:
        if not self.audio_path.get():
            return
            
        path = self.audio_path.get()
        if not os.path.isfile(path):
            return
            
        if self.preview_proc and self.preview_proc.poll() is None:
            if self.preview_is_paused:
                import signal
                try:
                    self.preview_proc.send_signal(signal.SIGCONT)
                except Exception:
                    pass
                self.preview_is_paused = False
                self.preview_play_btn.configure(text="❚❚")
                self._start_preview_timer()
            else:
                import signal
                try:
                    self.preview_proc.send_signal(signal.SIGSTOP)
                except Exception:
                    pass
                self.preview_is_paused = True
                self.preview_play_btn.configure(text="▶")
                self._stop_preview_timer()
        else:
            self._stop_browser_player()
            try:
                self.preview_proc = subprocess.Popen(
                    ["afplay", path],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                self.preview_is_paused = False
                self.preview_elapsed = 0.0
                self.preview_play_btn.configure(text="❚❚")
                self._start_preview_timer()
            except Exception as e:
                self._append_log(f"Failed to play preview: {e}\n")

    def _seek_preview(self, val) -> None:
        if self.preview_slider_updating:
            return
        self.preview_slider_updating = True
        self.preview_slider.set(self.preview_elapsed)
        self.preview_slider_updating = False

    def _start_preview_timer(self) -> None:
        self._stop_preview_timer()
        self._tick_preview_player()
        
    def _stop_preview_timer(self) -> None:
        if self.preview_timer_id:
            self.after_cancel(self.preview_timer_id)
            self.preview_timer_id = None
            
    def _tick_preview_player(self) -> None:
        if self.preview_proc:
            if self.preview_proc.poll() is not None:
                self._stop_preview_player()
                return
                
            if not self.preview_is_paused and not self.preview_slider_updating:
                self.preview_elapsed += 0.1
                if self.preview_elapsed > self.preview_duration:
                    self.preview_elapsed = self.preview_duration
                
                self.preview_slider_updating = True
                self.preview_slider.set(self.preview_elapsed)
                self.preview_slider_updating = False
                
                self.preview_time_lbl.configure(
                    text=f"{self._format_time(self.preview_elapsed)} / {self._format_time(self.preview_duration)}"
                )
                
        self.preview_timer_id = self.after(100, self._tick_preview_player)

    def _stop_preview_player(self) -> None:
        self._stop_preview_timer()
        if self.preview_proc:
            try:
                self.preview_proc.terminate()
                self.preview_proc.wait(timeout=0.2)
            except Exception:
                pass
            self.preview_proc = None
        self.preview_is_paused = False
        self.preview_play_btn.configure(text="▶")
        self.preview_time_lbl.configure(text=f"00:00 / {self._format_time(self.preview_duration)}")
        self.preview_slider_updating = True
        self.preview_slider.set(0)
        self.preview_slider_updating = False

    def _autocomplete_tags(self, event) -> None:
        if event.keysym in ("BackSpace", "Delete", "Escape", "Left", "Right", "Up", "Down", "Shift_L", "Shift_R", "Control_L", "Control_R", "Alt_L", "Alt_R", "Meta_L", "Meta_R"):
            return
            
        text = self.tags_entry.get()
        cursor_pos = self.tags_entry.index(tk.INSERT)
        
        prefix = text[:cursor_pos]
        parts = prefix.split(",")
        if not parts:
            return
        last_part = parts[-1]
        trimmed_part = last_part.lstrip()
        
        if not trimmed_part:
            return
            
        for option in self.tag_options:
            if option.lower().startswith(trimmed_part.lower()):
                suffix = option[len(trimmed_part):]
                if not suffix:
                    continue
                    
                new_last = last_part + suffix
                new_parts = parts[:-1] + [new_last]
                completed_text = ",".join(new_parts) + text[cursor_pos:]
                
                self.tags_str.set(completed_text)
                self.tags_entry.icursor(cursor_pos)
                self.tags_entry.select_range(cursor_pos, cursor_pos + len(suffix))
                break

    def _setup_browser_player(self, content: str) -> None:
        self._stop_browser_player()
        self.timestamp_ranges.clear()
        
        audio_path = None
        for line in content.splitlines():
            trimmed = line.strip()
            if trimmed.startswith("File: "):
                audio_path = trimmed.replace("File: ", "", 1).strip()
            elif trimmed.startswith("Path: "):
                audio_path = trimmed.replace("Path: ", "", 1).strip()
            elif trimmed.startswith("source_file: "):
                audio_path = trimmed.replace("source_file: ", "", 1).strip().strip('"')
                
        if audio_path and os.path.isfile(audio_path):
            self.browser_audio_path = audio_path
            duration = self._get_audio_duration(audio_path)
            if duration <= 0:
                duration = 100.0
                
            self.browser_duration = duration
            self.browser_elapsed = 0.0
            self.browser_is_paused = False
            
            self.browser_slider_updating = True
            self.browser_slider.configure(state=tk.NORMAL, to=duration)
            self.browser_slider.set(0)
            self.browser_slider_updating = False
            
            self.browser_play_btn.configure(state=tk.NORMAL, text="▶")
            filename = os.path.basename(audio_path)
            if len(filename) > 15:
                filename = filename[:12] + "..."
            self.browser_time_lbl.configure(text=f"{filename} [00:00 / {self._format_time(duration)}]")
            
            self._parse_timestamps_in_browser_text(content)
        else:
            self._disable_browser_player()

    def _disable_browser_player(self) -> None:
        self._stop_browser_player()
        self.browser_play_btn.configure(state=tk.DISABLED)
        self.browser_slider.configure(state=tk.DISABLED)
        self.browser_time_lbl.configure(text="No active audio loaded")

    def _parse_timestamps_in_browser_text(self, content: str) -> None:
        self.timestamp_ranges.clear()
        import re
        
        pat_log = r"\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?(?:\s*->\s*(\d{2}):(\d{2})(?:\.(\d{2,3}))?)?\]"
        pat_srt = r"(\d{2}):(\d{2}):(\d{2})[,\.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,\.](\d{3})"
        pat_vtt_short = r"(\d{2}):(\d{2})[,\.](\d{3})\s*-->\s*(\d{2}):(\d{2})[,\.](\d{3})"
        
        lines = content.splitlines()
        for idx, line in enumerate(lines):
            line_num = idx + 1
            
            # Try Pattern 1 (Whisper log)
            m = re.search(pat_log, line)
            if m:
                start_min = m.group(1)
                start_sec = m.group(2)
                start_ms = m.group(3)
                start_time = self._parse_time_value(start_min, start_sec, start_ms)
                
                if m.group(4) and m.group(5):
                    end_min = m.group(4)
                    end_sec = m.group(5)
                    end_ms = m.group(6)
                    end_time = self._parse_time_value(end_min, end_sec, end_ms)
                else:
                    end_time = start_time + 3.0
                self.timestamp_ranges.append((start_time, end_time, line_num))
                continue
                
            # Try Pattern 2 (SRT/VTT full format)
            m = re.search(pat_srt, line)
            if m:
                start_hr = float(m.group(1))
                start_min = float(m.group(2))
                start_sec = float(m.group(3))
                start_ms = float(m.group(4))
                start_time = start_hr * 3600.0 + start_min * 60.0 + start_sec + start_ms * 0.001
                
                end_hr = float(m.group(5))
                end_min = float(m.group(6))
                end_sec = float(m.group(7))
                end_ms = float(m.group(8))
                end_time = end_hr * 3600.0 + end_min * 60.0 + end_sec + end_ms * 0.001
                
                self.timestamp_ranges.append((start_time, end_time, line_num))
                continue
                
            # Try Pattern 3 (VTT short format)
            m = re.search(pat_vtt_short, line)
            if m:
                start_min = float(m.group(1))
                start_sec = float(m.group(2))
                start_ms = float(m.group(3))
                start_time = start_min * 60.0 + start_sec + start_ms * 0.001
                
                end_min = float(m.group(4))
                end_sec = float(m.group(5))
                end_ms = float(m.group(6))
                end_time = end_min * 60.0 + end_sec + end_ms * 0.001
                
                self.timestamp_ranges.append((start_time, end_time, line_num))

    def _parse_time_value(self, mins: str, secs: str, ms: Optional[str]) -> float:
        m = float(mins) if mins else 0.0
        s = float(secs) if secs else 0.0
        milli = float(ms) if ms else 0.0
        milli_factor = 0.01 if ms and len(ms) == 2 else 0.001
        return m * 60.0 + s + milli * milli_factor

    def _play_pause_browser(self) -> None:
        if not self.browser_audio_path:
            return
            
        path = self.browser_audio_path
        if not os.path.isfile(path):
            return
            
        if self.browser_proc and self.browser_proc.poll() is None:
            if self.browser_is_paused:
                import signal
                try:
                    self.browser_proc.send_signal(signal.SIGCONT)
                except Exception:
                    pass
                self.browser_is_paused = False
                self.browser_play_btn.configure(text="❚❚")
                self._start_browser_timer()
            else:
                import signal
                try:
                    self.browser_proc.send_signal(signal.SIGSTOP)
                except Exception:
                    pass
                self.browser_is_paused = True
                self.browser_play_btn.configure(text="▶")
                self._stop_browser_timer()
        else:
            self._stop_preview_player()
            try:
                self.browser_proc = subprocess.Popen(
                    ["afplay", path],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                self.browser_is_paused = False
                self.browser_elapsed = 0.0
                self.browser_play_btn.configure(text="❚❚")
                self._start_browser_timer()
            except Exception as e:
                self._append_log(f"Failed to play browser audio: {e}\n")

    def _seek_browser(self, val) -> None:
        if self.browser_slider_updating:
            return
        self.browser_slider_updating = True
        self.browser_slider.set(self.browser_elapsed)
        self.browser_slider_updating = False

    def _start_browser_timer(self) -> None:
        self._stop_browser_timer()
        self._tick_browser_player()
        
    def _stop_browser_timer(self) -> None:
        if self.browser_timer_id:
            self.after_cancel(self.browser_timer_id)
            self.browser_timer_id = None
            
    def _tick_browser_player(self) -> None:
        if self.browser_proc:
            if self.browser_proc.poll() is not None:
                self._stop_browser_player()
                return
                
            if not self.browser_is_paused and not self.browser_slider_updating:
                self.browser_elapsed += 0.1
                if self.browser_elapsed > self.browser_duration:
                    self.browser_elapsed = self.browser_duration
                    
                self.browser_slider_updating = True
                self.browser_slider.set(self.browser_elapsed)
                self.browser_slider_updating = False
                
                filename = os.path.basename(self.browser_audio_path)
                if len(filename) > 15:
                    filename = filename[:12] + "..."
                self.browser_time_lbl.configure(
                    text=f"{filename} [{self._format_time(self.browser_elapsed)} / {self._format_time(self.browser_duration)}]"
                )
                
                self._highlight_active_timestamp_line()
                
        self.browser_timer_id = self.after(100, self._tick_browser_player)

    def _stop_browser_player(self) -> None:
        self._stop_browser_timer()
        if self.browser_proc:
            try:
                self.browser_proc.terminate()
                self.browser_proc.wait(timeout=0.2)
            except Exception:
                pass
            self.browser_proc = None
        self.browser_is_paused = False
        self.browser_play_btn.configure(text="▶")
        if self.browser_audio_path:
            filename = os.path.basename(self.browser_audio_path)
            if len(filename) > 15:
                filename = filename[:12] + "..."
            self.browser_time_lbl.configure(text=f"{filename} [00:00 / {self._format_time(self.browser_duration)}]")
        self.browser_slider_updating = True
        self.browser_slider.set(0)
        self.browser_slider_updating = False
        self.browser_text.tag_remove("active_highlight", "1.0", tk.END)
        self.browser_current_highlighted_line = None

    def _highlight_active_timestamp_line(self) -> None:
        time = self.browser_elapsed
        matched = None
        for start, end, line_num in self.timestamp_ranges:
            if start <= time <= end:
                matched = line_num
                break
                
        if matched is not None and matched != self.browser_current_highlighted_line:
            # Clear previous active highlight range only
            if self.browser_current_highlighted_line is not None:
                prev = self.browser_current_highlighted_line
                self.browser_text.tag_remove("active_highlight", f"{prev}.0", f"{prev}.end")
                
            self.browser_current_highlighted_line = matched
            
            # Retrieve active line content to determine speaker
            try:
                line_content = self.browser_text.get(f"{matched}.0", f"{matched}.end")
                speaker = self._extract_speaker(line_content)
                bg_color, active_color = self._get_speaker_colors(speaker)
            except Exception:
                active_color = "#ffffd0" # Default fallback
                
            self.browser_text.tag_add("active_highlight", f"{matched}.0", f"{matched}.end")
            self.browser_text.tag_configure("active_highlight", background=active_color)
            self.browser_text.tag_raise("active_highlight")
            self.browser_text.see(f"{matched}.0")

    def _browser_text_clicked(self, event) -> None:
        try:
            line_idx = int(self.browser_text.index(tk.INSERT).split('.')[0])
            for start, end, line_num in self.timestamp_ranges:
                if line_num == line_idx:
                    self.status.configure(text=f"Timestamp: {self._format_time(start)}")
                    break
        except Exception:
            pass

    def _on_close(self) -> None:
        self._stop_preview_player()
        self._stop_browser_player()
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
            except Exception:
                pass
        self.destroy()


def main() -> None:
    try:
        app = WhisperGui()
    except tk.TclError as exc:
        print(f"GUI failed to start: {exc}", file=sys.stderr)
        sys.exit(1)
    app.mainloop()


if __name__ == "__main__":
    main()
