#!/usr/bin/env python3
"""Minimal control panel for WiFiScan: rolling log view + start/stop buttons."""
import os
import subprocess
import threading
import time
import tkinter as tk
from tkinter import scrolledtext, messagebox

APP_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(APP_DIR, "WiFiScan.sh")
LOG_DIR = os.path.join(os.path.expanduser("~"), "wifi-logs")
LOG_FILE = os.path.join(LOG_DIR, "wifiscan.out")
PID_FILE = os.path.join(LOG_DIR, "wifiscan.pid")


class WiFiScanGUI:
    def __init__(self, root):
        self.root = root
        root.title("WiFiScan Control Panel")
        root.geometry("900x600")

        self.text = scrolledtext.ScrolledText(
            root, state="disabled", bg="black", fg="#33ff33", font=("monospace", 10)
        )
        self.text.pack(fill="both", expand=True, padx=6, pady=6)

        btn_frame = tk.Frame(root)
        btn_frame.pack(fill="x", padx=6, pady=6)

        self.start_btn = tk.Button(btn_frame, text="Start (Passive)", command=self.start_passive)
        self.start_btn.pack(side="left", padx=4)

        self.start_active_btn = tk.Button(btn_frame, text="Start (Active)", command=self.start_active)
        self.start_active_btn.pack(side="left", padx=4)

        self.stop_btn = tk.Button(btn_frame, text="Stop", command=self.stop, state="disabled")
        self.stop_btn.pack(side="left", padx=4)

        self.status = tk.Label(btn_frame, text="Idle", anchor="e")
        self.status.pack(side="right", padx=4)

        self._tail_pos = 0
        self._stop_tail = False
        threading.Thread(target=self._tail_log, daemon=True).start()

        root.protocol("WM_DELETE_WINDOW", self.on_close)

    def _append(self, text):
        self.text.configure(state="normal")
        self.text.insert("end", text)
        self.text.see("end")
        self.text.configure(state="disabled")

    def _tail_log(self):
        # Log file doesn't exist until the scan starts, so poll for it rather than failing.
        while not self._stop_tail:
            try:
                if os.path.exists(LOG_FILE):
                    with open(LOG_FILE, "r", errors="replace") as f:
                        f.seek(self._tail_pos)
                        chunk = f.read()
                        self._tail_pos = f.tell()
                    if chunk:
                        self.root.after(0, self._append, chunk)
            except OSError:
                pass
            time.sleep(1)

    def _launch(self, extra_args):
        os.makedirs(LOG_DIR, exist_ok=True)
        cmd = ["pkexec", "bash", SCRIPT_PATH, "-o", LOG_DIR] + extra_args
        try:
            subprocess.Popen(cmd)
        except FileNotFoundError:
            messagebox.showerror("WiFiScan", "pkexec not found — install policykit-1.")
            return
        self.status.configure(text="Running")
        self.start_btn.configure(state="disabled")
        self.start_active_btn.configure(state="disabled")
        self.stop_btn.configure(state="normal")

    def start_passive(self):
        self._launch([])

    def start_active(self):
        self._launch(["--active"])

    def stop(self):
        if not os.path.exists(PID_FILE):
            messagebox.showinfo("WiFiScan", "No PID file found — scan may not be running.")
        else:
            try:
                with open(PID_FILE) as f:
                    pid = f.read().strip()
                subprocess.run(["pkexec", "kill", pid], check=False)
            except OSError as e:
                messagebox.showerror("WiFiScan", str(e))
        self.status.configure(text="Idle")
        self.start_btn.configure(state="normal")
        self.start_active_btn.configure(state="normal")
        self.stop_btn.configure(state="disabled")

    def on_close(self):
        self._stop_tail = True
        self.root.destroy()


def main():
    root = tk.Tk()
    WiFiScanGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()
