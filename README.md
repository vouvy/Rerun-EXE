# This program was made for a client

# Rerun EXE

Rerun EXE is a Windows-only Python console utility that keeps selected desktop applications running on a timed restart schedule. It can watch any executable path, restart all matching processes before relaunching, and react to real-time configuration updates without leaving the console UI.

## Highlights

- Disables Quick Edit and locks the console window to prevent accidental freezes or resizing.
- Real-time `rerun_exe_config.json` reload while the tool is running.
- Unlimited program entries with per-app delay timers and behaviors.
- Arrow-key navigation with on-screen toggles, manual restart, reload, and quit controls.
- Comprehensive process cleanup using `taskkill /F /T` before every launch.
- Automatic recovery if a monitored program disappears unexpectedly.

## Requirements

- Windows 10 or Windows 11.
- Python 3.10 or later.
- Console must be launched with standard user privileges (elevated rights only if your targets require them).

## Configuration

The supervisor looks for `rerun_exe_config.json` in the same folder as `rerun_exe.py`. If the file is missing, it is created automatically with an empty program list. Edit the file at any time; changes apply instantly.

```json
{
  "programs": [
    {
      "name": "ExampleInterval",
      "path": "C:/Path/To/Application.exe",
      "delay_seconds": 3600,
      "behavior": "scheduled-only",
      "enabled": true
    },
    {
      "name": "ExampleKeepalive",
      "path": "C:/Path/To/Another.exe",
      "delay_seconds": 900,
      "behavior": "resilient-keepalive",
      "enabled": false
    }
  ]
}
```

### Fields

| Field | Description |
| --- | --- |
| `name` | Display name; must be unique. |
| `path` | Absolute or relative path to the program. Environment variables (e.g. `%PROGRAMFILES%`) are allowed. |
| `delay_seconds` | Interval before a scheduled restart (minimum 5 seconds). |
| `behavior` | `scheduled-only` or `resilient-keepalive` (see below). |
| `enabled` | `true` to manage the program immediately; `false` leaves the entry off but editable from the UI. |
| `process_image` *(optional)* | Override for the process name to terminate/monitor (e.g. `python.exe`, `powershell.exe`). Helpful for scripts that run through an interpreter. |

### Behaviors

| Short name | Key | Description |
| --- | --- | --- |
| Interval | `scheduled-only` | Launch once at startup, then wait for the full delay before force-closing all matching processes and relaunching. If the program exits early, the supervisor waits until the timer expires before restarting. |
| Keepalive | `resilient-keepalive` | Launch at startup, restart immediately if the process disappears, and still perform the scheduled refresh at the configured delay. |

## Console Controls

- `↑` / `↓`: Move between entries.
- `Enter`: Toggle enable/disable for the selected entry.
- `R`: Force an immediate restart of the selected entry (kills first, then starts).
- `C`: Reload the configuration file on demand.
- `Q`: Quit the supervisor.

Status lines show the active PIDs (if detected) and countdown to the next scheduled restart. Errors (missing files, launch failures, termination timeouts) appear inline with the corresponding entry.

## Process Handling

- Every restart (scheduled, manual, or recovery) calls `taskkill /PID <pid> /F /T` for *all* processes matching the monitored image name.
- The supervisor waits up to 10 seconds for processes to disappear before trying to relaunch. Failures back off and retry automatically.
- Launch attempts support executables, batch files, PowerShell scripts, Python scripts, and arbitrary files; for non-executables, provide a `process_image` override so termination targets the correct interpreter (for example, `python.exe`).

## Running

### Option 1: `run.bat` (recommended)

`run.bat` handles the full bootstrap: it checks for Python 3.11, installs it if missing, verifies pip, and then launches `rerun_exe.py`. Run it from File Explorer or PowerShell:

```powershell
.\run.bat
```

Pass `--no-pause` if you want the window to close automatically after exit. Any other arguments are forwarded to `rerun_exe.py`.

### Option 2: Direct Python

```powershell
python rerun_exe.py
```

Replace `python` with the absolute path to your interpreter if it is not on `PATH`.

The console locks resizing, so use the provided window; the on-screen menu updates in real time.

## Tips

- Add as many entries as you want; the UI scrolls vertically.
- Store the supervisor alongside deployment assets so relative paths resolve correctly.
- If you edit the config and make a mistake, the UI reports the JSON error and keeps the last good configuration.
- Combine with Task Scheduler or a service wrapper if you need the supervisor to boot automatically with Windows.

## Example Code

```py
import ctypes, json, os, subprocess, sys, time, msvcrt
from enum import Enum
from pathlib import Path

try:
    from ctypes import wintypes
except ImportError:

    class _WinTypes:
        HANDLE = ctypes.c_void_p
        DWORD = ctypes.c_ulong
        BOOL = ctypes.c_int
        LONG = ctypes.c_long
        ULONG = ctypes.c_ulong
        WCHAR = ctypes.c_wchar

    wintypes = _WinTypes()

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
user32 = ctypes.WinDLL("user32", use_last_error=True)

if ctypes.sizeof(ctypes.c_void_p) == 8:
    ULONG_PTR = ctypes.c_ulonglong
else:
    ULONG_PTR = ctypes.c_ulong

BASE_DIR = Path(__file__).resolve().parent
CONFIG_FILENAME = "rerun_exe_config.json"

kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
kernel32.Process32FirstW.restype = wintypes.BOOL
kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
kernel32.Process32NextW.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


def disable_quick_edit():
    try:
        GetStdHandle = kernel32.GetStdHandle
        GetConsoleMode = kernel32.GetConsoleMode
        SetConsoleMode = kernel32.SetConsoleMode
        STD_INPUT_HANDLE = -10
        hStdin = GetStdHandle(STD_INPUT_HANDLE)
        mode = ctypes.c_uint()
        if GetConsoleMode(hStdin, ctypes.byref(mode)):
            ENABLE_QUICK_EDIT = 0x40
            new_mode = mode.value & ~ENABLE_QUICK_EDIT
            SetConsoleMode(hStdin, new_mode)
    except Exception:
        pass


def lock_console_resize():
    try:
        GetConsoleWindow = kernel32.GetConsoleWindow
        hwnd = GetConsoleWindow()
        if not hwnd:
            return
        GWL_STYLE = -16
        GWL_EXSTYLE = -20
        WS_MAXIMIZEBOX = 0x00010000
        WS_SIZEBOX = 0x00040000
        GetWindowLongW = user32.GetWindowLongW
        SetWindowLongW = user32.SetWindowLongW
        style = GetWindowLongW(hwnd, GWL_STYLE)
        if style:
            style &= ~WS_MAXIMIZEBOX
            style &= ~WS_SIZEBOX
            SetWindowLongW(hwnd, GWL_STYLE, style)
        GetSystemMenu = user32.GetSystemMenu
        RemoveMenu = user32.RemoveMenu
        DrawMenuBar = user32.DrawMenuBar
        SC_SIZE = 0xF000
        SC_MAXIMIZE = 0xF030
        hMenu = GetSystemMenu(hwnd, False)
        if hMenu:
            RemoveMenu(hMenu, SC_SIZE, 0x0000)
            RemoveMenu(hMenu, SC_MAXIMIZE, 0x0000)
            DrawMenuBar(hwnd)
    except Exception:
        pass


def set_console_geometry(cols=110, lines=38):
    try:
        os.system(f"mode con: cols={cols} lines={lines}")
    except Exception:
        pass


def set_console_title(title: str):
    try:
        kernel32.SetConsoleTitleW(title)
    except Exception:
        pass


class Behavior(Enum):
    SCHEDULED_ONLY = "scheduled-only"
    RESILIENT_KEEPALIVE = "resilient-keepalive"

    @property
    def short_name(self) -> str:
        if self is Behavior.SCHEDULED_ONLY:
            return "Interval"
        return "Keepalive"

    @property
    def description(self) -> str:
        if self is Behavior.SCHEDULED_ONLY:
            return "Restart only when the timer expires"
        return "Restart if missing and on timer"

    @staticmethod
    def from_value(value: str) -> "Behavior":
        try:
            normalized = (value or "").strip().lower()
            for option in Behavior:
                if option.value == normalized:
                    return option
        except Exception:
            pass
        return Behavior.SCHEDULED_ONLY


class ProcessInspector:
    TH32CS_SNAPPROCESS = 0x00000002
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

    class PROCESSENTRY32(ctypes.Structure):
        _fields_ = [
            ("dwSize", wintypes.DWORD),
            ("cntUsage", wintypes.DWORD),
            ("th32ProcessID", wintypes.DWORD),
            ("th32DefaultHeapID", ULONG_PTR),
            ("th32ModuleID", wintypes.DWORD),
            ("cntThreads", wintypes.DWORD),
            ("th32ParentProcessID", wintypes.DWORD),
            ("pcPriClassBase", wintypes.LONG),
            ("dwFlags", wintypes.DWORD),
            ("szExeFile", wintypes.WCHAR * 260),
        ]

    @classmethod
    def image_pids(cls, image_name: str) -> set[int]:
        results: set[int] = set()
        if not image_name:
            return results
        snapshot = kernel32.CreateToolhelp32Snapshot(cls.TH32CS_SNAPPROCESS, 0)
        if snapshot == cls.INVALID_HANDLE_VALUE:
            return results
        try:
            entry = cls.PROCESSENTRY32()
            entry.dwSize = ctypes.sizeof(cls.PROCESSENTRY32)
            success = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
            target = image_name.lower()
            while success:
                if entry.szExeFile.lower() == target:
                    results.add(int(entry.th32ProcessID))
                success = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
        finally:
            kernel32.CloseHandle(snapshot)
        return results

    @staticmethod
    def terminate_tree(pid: int) -> bool:
        if pid <= 0:
            return True
        try:
            result = subprocess.run(
                ["taskkill", "/PID", str(pid), "/F", "/T"],
                capture_output=True,
                text=True,
                timeout=10,
                shell=False,
            )
            if result.returncode == 0:
                return True
            if (
                "not found" in result.stdout.lower()
                or "not found" in result.stderr.lower()
            ):
                return True
        except Exception:
            return False
        return False


def format_duration(seconds: int | float | None) -> str:
    if seconds is None:
        return "unknown"
    remaining = max(0, int(seconds))
    hours, remainder = divmod(remaining, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def ensure_config(path: Path) -> None:
    if path.exists():
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    template = {"programs": []}
    path.write_text(json.dumps(template, indent=2), encoding="utf-8")


class ConfigError(Exception):
    pass


def load_configuration(path: Path) -> list[dict]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Invalid JSON: {exc}") from exc
    except Exception as exc:
        raise ConfigError(str(exc)) from exc
    programs = data.get("programs")
    if not isinstance(programs, list):
        raise ConfigError("Field 'programs' must be a list")
    cleaned: list[dict] = []
    seen_names: set[str] = set()
    for entry in programs:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name", "")).strip()
        if not name or name.lower() in seen_names:
            continue
        seen_names.add(name.lower())
        payload = {
            "name": name,
            "path": str(entry.get("path", "")).strip(),
            "delay_seconds": entry.get("delay_seconds", 60),
            "behavior": entry.get("behavior", Behavior.SCHEDULED_ONLY.value),
            "enabled": bool(entry.get("enabled", True)),
        }
        override_image = (
            entry.get("process_image")
            or entry.get("process_name")
            or entry.get("image_name")
        )
        if override_image:
            payload["process_image"] = str(override_image).strip()
        cleaned.append(payload)
    return cleaned


class ProgramEntry:
    def __init__(self, payload: dict):
        self.name = ""
        self.path = Path()
        self.delay_seconds = 60
        self.behavior = Behavior.SCHEDULED_ONLY
        self.enabled = True
        self.image_name = ""
        self.working_directory = None
        self.process_image_override = ""
        self.original_path_input = ""
        self.last_launch_time: float | None = None
        self.next_restart_time: float | None = None
        self.last_launch_attempt: float = 0.0
        self.next_retry_after: float = 0.0
        self.awaiting_confirmation_until: float = 0.0
        self.pending_restart = False
        self.launch_failures = 0
        self.last_error = ""
        self.status_line = "Waiting"
        self.detail_line = ""
        self.observed_pids: set[int] = set()
        self.apply(payload)

    def apply(self, payload: dict) -> None:
        self.name = payload["name"]
        raw_input_path = str(payload["path"])
        self.original_path_input = raw_input_path
        expanded = os.path.expandvars(raw_input_path)
        raw_path = Path(expanded).expanduser()
        if not raw_path.is_absolute():
            raw_path = (BASE_DIR / raw_path).resolve()
        self.path = raw_path
        self.working_directory = str(raw_path.parent) if raw_path.parent else None
        try:
            self.delay_seconds = max(5, int(payload.get("delay_seconds", 60)))
        except Exception:
            self.delay_seconds = 60
        self.behavior = Behavior.from_value(payload.get("behavior"))
        self.enabled = bool(payload.get("enabled", True))
        override = str(payload.get("process_image", "")).strip()
        self.process_image_override = override
        self.image_name = self._determine_image_name()
        if self.last_launch_time and self.delay_seconds:
            self.next_restart_time = self.last_launch_time + self.delay_seconds

    def to_payload(self) -> dict:
        payload = {
            "name": self.name,
            "path": self.original_path_input or str(self.path),
            "delay_seconds": self.delay_seconds,
            "behavior": self.behavior.value,
            "enabled": self.enabled,
        }
        if self.process_image_override:
            payload["process_image"] = self.process_image_override
        return payload

    def toggle_enabled(self) -> None:
        self.enabled = not self.enabled
        if not self.enabled:
            self.status_line = "Disabled"
            self.detail_line = ""

    def _determine_image_name(self) -> str:
        if self.process_image_override:
            return Path(self.process_image_override).name or self.process_image_override
        suffix = self.path.suffix.lower()
        if suffix in {".bat", ".cmd"}:
            return "cmd.exe"
        if suffix == ".ps1":
            return "powershell.exe"
        if suffix == ".py":
            if sys.executable:
                return Path(sys.executable).name
            return "python.exe"
        name = self.path.name
        return name

    def force_restart(self) -> None:
        if self.enabled:
            self.pending_restart = True

    def tick(self, now: float) -> None:
        self.observed_pids = ProcessInspector.image_pids(self.image_name)
        running = bool(self.observed_pids)
        if not self.enabled:
            self.status_line = "Disabled"
            self.detail_line = self._compose_process_state(running, now)
            self.pending_restart = False
            return
        if self.pending_restart:
            if self._restart(now, "manual"):
                self.observed_pids = ProcessInspector.image_pids(self.image_name)
                running = bool(self.observed_pids)
            self.pending_restart = False
        if self.last_launch_time is None and now >= self.next_retry_after:
            if self._start(now, "startup"):
                self.observed_pids = ProcessInspector.image_pids(self.image_name)
                running = bool(self.observed_pids)
        if (
            self.behavior is Behavior.RESILIENT_KEEPALIVE
            and not running
            and now >= self.next_retry_after
            and self.last_launch_time is not None
        ):
            if self._restart(now, "keepalive"):
                self.observed_pids = ProcessInspector.image_pids(self.image_name)
                running = bool(self.observed_pids)
        if self.next_restart_time and now >= self.next_restart_time:
            if self._restart(now, "scheduled"):
                self.observed_pids = ProcessInspector.image_pids(self.image_name)
                running = bool(self.observed_pids)
        self._refresh_status(now, running)

    def _start(self, now: float, reason: str) -> bool:
        if not self._terminate_all(now):
            return False
        return self._launch(now, reason)

    def _restart(self, now: float, reason: str) -> bool:
        if not self._terminate_all(now):
            return False
        return self._launch(now, reason)

    def _launch(self, now: float, reason: str) -> bool:
        if not self.path.exists():
            self.status_line = "Missing path"
            self.detail_line = str(self.path)
            self.last_error = "File not found"
            self.next_retry_after = now + min(
                300, 30 * max(1, self.launch_failures + 1)
            )
            self.launch_failures += 1
            return False
        command = self._build_command()
        try:
            subprocess.Popen(
                command,
                cwd=self.working_directory,
                creationflags=self._creation_flags(command),
                shell=isinstance(command, str),
            )
        except Exception as exc:
            if hasattr(os, "startfile"):
                try:
                    os.startfile(str(self.path))
                except Exception as start_exc:
                    self.status_line = "Launch failed"
                    self.detail_line = str(start_exc)
                    self.last_error = str(start_exc)
                    self.next_retry_after = now + min(
                        300, 30 * max(1, self.launch_failures + 1)
                    )
                    self.launch_failures += 1
                    return False
            else:
                self.status_line = "Launch failed"
                self.detail_line = str(exc)
                self.last_error = str(exc)
                self.next_retry_after = now + min(
                    300, 30 * max(1, self.launch_failures + 1)
                )
                self.launch_failures += 1
                return False
        self.last_launch_time = now
        self.next_restart_time = now + self.delay_seconds
        self.last_launch_attempt = now
        self.awaiting_confirmation_until = now + 20
        self.next_retry_after = now + 5
        self.launch_failures = 0
        self.last_error = ""
        self.status_line = f"Launching ({reason})"
        self.detail_line = "Waiting for process"
        return True

    def _build_command(self) -> list[str] | str:
        suffix = self.path.suffix.lower()
        path_str = str(self.path)
        if suffix in {".bat", ".cmd"}:
            return ["cmd.exe", "/c", path_str]
        if suffix == ".ps1":
            return [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                path_str,
            ]
        if suffix == ".py":
            python_exe = sys.executable or "python"
            return [python_exe, path_str]
        if self.path.is_dir():
            return f'start "" "{path_str}"'
        return [path_str]

    def _creation_flags(self, command: list[str] | str) -> int:
        CREATE_NEW_CONSOLE = 0x00000010
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        if isinstance(command, str):
            return CREATE_NEW_CONSOLE
        return CREATE_NEW_PROCESS_GROUP

    def _terminate_all(self, now: float) -> bool:
        active = ProcessInspector.image_pids(self.image_name)
        if not active:
            return True
        success = True
        for pid in list(active):
            if not ProcessInspector.terminate_tree(pid):
                success = False
        if not success:
            deadline = now + 10
            while time.time() < deadline:
                if not ProcessInspector.image_pids(self.image_name):
                    return True
                time.sleep(0.5)
            self.status_line = "Terminate timeout"
            self.detail_line = "Process still running"
            self.next_retry_after = time.time() + 10
            return False
        deadline = now + 10
        while time.time() < deadline:
            if not ProcessInspector.image_pids(self.image_name):
                return True
            time.sleep(0.25)
        self.status_line = "Terminate timeout"
        self.detail_line = "Process still running"
        self.next_retry_after = time.time() + 10
        return False

    def _refresh_status(self, now: float, running: bool) -> None:
        if running:
            self.status_line = "Running"
            self.detail_line = self._compose_process_state(True, now)
            self.awaiting_confirmation_until = 0.0
            return
        if self.awaiting_confirmation_until and now < self.awaiting_confirmation_until:
            remaining = int(self.awaiting_confirmation_until - now)
            self.status_line = "Launching"
            self.detail_line = f"Waiting {remaining}s for process"
            return
        if self.last_error:
            self.status_line = "Error"
            self.detail_line = self.last_error
            return
        if self.behavior is Behavior.SCHEDULED_ONLY and self.next_restart_time:
            remaining = int(self.next_restart_time - now)
            self.status_line = "Waiting"
            self.detail_line = f"Restart in {format_duration(remaining)}"
            return
        self.status_line = "Stopped"
        self.detail_line = "Idle"

    def _compose_process_state(self, running: bool, now: float) -> str:
        if not running:
            remaining = None
            if self.next_restart_time:
                remaining = self.next_restart_time - now
            return f"Restart in {format_duration(remaining)}"
        pid_block = ", ".join(str(pid) for pid in sorted(self.observed_pids))
        remaining = None
        if self.next_restart_time:
            remaining = self.next_restart_time - now
        return f"PID {pid_block} | restart in {format_duration(remaining)}"


class EditCancelled(Exception):
    pass


def write_configuration(path: Path, entries: list[ProgramEntry]) -> float:
    payload = {"programs": [entry.to_payload() for entry in entries]}
    serialized = json.dumps(payload, indent=2)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    temp_suffix = path.suffix + ".tmp" if path.suffix else ".tmp"
    temp_path = path.with_suffix(temp_suffix)
    try:
        temp_path.write_text(serialized, encoding="utf-8")
        os.replace(temp_path, path)
    except Exception:
        try:
            path.write_text(serialized, encoding="utf-8")
        except Exception as exc:
            raise ConfigError(f"Unable to write configuration: {exc}") from exc
    try:
        return path.stat().st_mtime
    except FileNotFoundError:
        return time.time()


def prompt_with_default(
    label: str, default: str | None, *, allow_empty: bool = False, validator=None
) -> str:
    while True:
        prompt = f"{label}"
        if default not in (None, ""):
            prompt += f" [{default}]"
        prompt += ": "
        raw = input(prompt).strip()
        if raw.lower() == "!cancel":
            raise EditCancelled()
        if not raw:
            if default not in (None, ""):
                raw = default or ""
            elif allow_empty:
                return ""
            else:
                print("This value is required. Type !cancel to abort.")
                continue
        if validator is None:
            return raw
        try:
            return validator(raw)
        except ValueError as exc:
            print(exc)


def prompt_behavior(default: Behavior) -> Behavior:
    mapping = {
        "1": Behavior.SCHEDULED_ONLY,
        "interval": Behavior.SCHEDULED_ONLY,
        "scheduled-only": Behavior.SCHEDULED_ONLY,
        "2": Behavior.RESILIENT_KEEPALIVE,
        "keepalive": Behavior.RESILIENT_KEEPALIVE,
        "resilient-keepalive": Behavior.RESILIENT_KEEPALIVE,
    }
    while True:
        raw = prompt_with_default(
            "Behavior (1=Interval, 2=Keepalive)", default.short_name
        )
        normalized = raw.strip().lower()
        if not normalized:
            return default
        result = mapping.get(normalized)
        if result:
            return result
        print("Enter 1, 2, interval, or keepalive.")


def prompt_yes_no(label: str, default: bool) -> bool:
    default_token = "Y" if default else "N"
    while True:
        raw = prompt_with_default(f"{label} (Y/N)", default_token)
        normalized = raw.strip().lower()
        if not normalized:
            return default
        if normalized in {"y", "yes", "1", "true", "on"}:
            return True
        if normalized in {"n", "no", "0", "false", "off"}:
            return False
        print("Enter Y or N.")


def prompt_delay(default: int) -> int:
    def validator(raw: str) -> str:
        try:
            value = int(raw)
        except ValueError as exc:
            raise ValueError("Delay must be a whole number of seconds.") from exc
        if value < 5:
            raise ValueError("Delay must be at least 5 seconds.")
        return str(value)

    result = prompt_with_default(
        "Restart delay (seconds)", str(default), validator=validator
    )
    return int(result)


def prompt_name(entries: list[ProgramEntry], existing: ProgramEntry | None) -> str:
    def validator(raw: str) -> str:
        value = raw.strip()
        if not value:
            raise ValueError("Name cannot be empty.")
        for other in entries:
            if other is existing:
                continue
            if other.name.lower() == value.lower():
                raise ValueError("Name must be unique.")
        return value

    default = existing.name if existing else None
    return prompt_with_default("Display name", default, validator=validator)


def prompt_path(existing: ProgramEntry | None) -> str:
    default_path = None
    if existing:
        default_path = existing.original_path_input or str(existing.path)
    while True:
        value = prompt_with_default("Executable path", default_path)
        if value:
            return value
        print("Executable path is required.")


def prompt_process_image(existing: ProgramEntry | None) -> str:
    default_value = existing.process_image_override if existing else ""
    return prompt_with_default(
        "Process image override (optional)", default_value, allow_empty=True
    )


def edit_entry_dialog(
    entries: list[ProgramEntry], existing: ProgramEntry | None
) -> dict | None:
    os.system("cls")
    mode = "Edit" if existing else "Add"
    print(f"{mode} configuration entry")
    print("Type !cancel at any prompt to abort.")
    print("")
    try:
        name = prompt_name(entries, existing)
        path_value = prompt_path(existing)
        delay_value = prompt_delay(existing.delay_seconds if existing else 3600)
        behavior_value = prompt_behavior(
            existing.behavior if existing else Behavior.SCHEDULED_ONLY
        )
        enabled_value = prompt_yes_no("Enabled", existing.enabled if existing else True)
        process_image_value = prompt_process_image(existing)
    except EditCancelled:
        return None
    payload = {
        "name": name,
        "path": path_value,
        "delay_seconds": delay_value,
        "behavior": behavior_value.value,
        "enabled": enabled_value,
    }
    if process_image_value.strip():
        payload["process_image"] = process_image_value.strip()
    return payload


def confirm_delete(entry: ProgramEntry) -> bool:
    os.system("cls")
    print(f"Delete entry '{entry.name}'?")
    print(f"Path: {entry.original_path_input or entry.path}")
    print("Type YES to confirm or press Enter to cancel.")
    response = input("Confirm delete: ").strip().lower()
    return response in {"y", "yes", "delete"}


def build_display(
    entries: list[ProgramEntry], selected: int, global_message: str | None
) -> str:
    lines: list[str] = []
    lines.append("Rerun EXE")
    lines.append("")
    lines.append(
        "Controls: ↑/↓ navigate | Enter toggle | R restart | A add | E edit | D delete | C reload | Q quit"
    )
    if global_message:
        lines.append(global_message)
    if not entries:
        lines.append("No programs configured. Press A to add a program.")
        return "\n".join(lines)
    lines.append("")
    for index, entry in enumerate(entries):
        marker = ">" if index == selected else " "
        enabled_flag = "ON" if entry.enabled else "OFF"
        behavior_flag = entry.behavior.short_name
        lines.append(f"{marker} [{enabled_flag}] {entry.name} ({behavior_flag})")
        lines.append(f"    Path: {entry.path}")
        lines.append(f"    Status: {entry.status_line}")
        if entry.detail_line:
            lines.append(f"    Detail: {entry.detail_line}")
        lines.append("")
    return "\n".join(lines)


def read_key() -> str | None:
    if not msvcrt.kbhit():
        return None
    key = msvcrt.getwch()
    if key in ("\x00", "\xe0"):
        second = msvcrt.getwch()
        return key + second
    return key


def main() -> None:
    if os.name != "nt":
        print("This supervisor runs on Windows 10 or Windows 11 only.")
        return
    config_path = BASE_DIR / CONFIG_FILENAME
    ensure_config(config_path)
    disable_quick_edit()
    lock_console_resize()
    set_console_geometry()
    set_console_title("Rerun EXE")
    entries: list[ProgramEntry] = []
    selected_index = 0
    global_message = None
    message_until = 0.0
    last_render = 0.0
    last_config_mtime = 0.0

    def set_message(text: str, duration: float = 4.0) -> None:
        nonlocal global_message, message_until
        global_message = text
        message_until = time.time() + duration

    def save_entries(success_text: str) -> None:
        nonlocal last_config_mtime
        try:
            last_config_mtime = write_configuration(config_path, entries)
            set_message(success_text)
        except ConfigError as exc:
            set_message(f"Save failed: {exc}", 10.0)

    try:
        raw = load_configuration(config_path)
        entries = [ProgramEntry(item) for item in raw]
        try:
            last_config_mtime = config_path.stat().st_mtime
        except FileNotFoundError:
            last_config_mtime = 0.0
    except ConfigError as exc:
        global_message = f"Config error: {exc}"
        set_message(f"Config error: {exc}", 10.0)
        try:
            last_config_mtime = config_path.stat().st_mtime
        except FileNotFoundError:
            last_config_mtime = 0.0
    running = True
    while running:
        now = time.time()
        try:
            current_mtime = config_path.stat().st_mtime
        except FileNotFoundError:
            ensure_config(config_path)
            current_mtime = config_path.stat().st_mtime
        if current_mtime != last_config_mtime:
            try:
                payload = load_configuration(config_path)
                updated: list[ProgramEntry] = []
                existing = {entry.name.lower(): entry for entry in entries}
                for item in payload:
                    key = item["name"].lower()
                    if key in existing:
                        entry = existing[key]
                        entry.apply(item)
                        updated.append(entry)
                    else:
                        updated.append(ProgramEntry(item))
                entries = updated
                if selected_index >= len(entries):
                    selected_index = max(0, len(entries) - 1)
                set_message("Configuration reloaded", 5.0)
            except ConfigError as exc:
                set_message(f"Config error: {exc}", 10.0)
            last_config_mtime = current_mtime
        for entry in entries:
            entry.tick(now)
        key = read_key()
        if key:
            if key == "\xe0H":
                selected_index = (
                    (selected_index - 1) % max(1, len(entries)) if entries else 0
                )
            elif key == "\xe0P":
                selected_index = (
                    (selected_index + 1) % max(1, len(entries)) if entries else 0
                )
            elif key in ("\r", "\n") and entries:
                entry = entries[selected_index]
                entry.toggle_enabled()
                state = "enabled" if entry.enabled else "disabled"
                save_entries(f"{entry.name} {state}")
            elif key in ("r", "R") and entries:
                entries[selected_index].force_restart()
                set_message(f"Restart requested for {entries[selected_index].name}")
            elif key in ("a", "A"):
                payload = edit_entry_dialog(entries, None)
                if payload is None:
                    set_message("Add cancelled", 3.0)
                else:
                    new_entry = ProgramEntry(payload)
                    entries.append(new_entry)
                    selected_index = len(entries) - 1
                    save_entries(f"Added {new_entry.name}")
            elif key in ("e", "E") and entries:
                target = entries[selected_index]
                payload = edit_entry_dialog(entries, target)
                if payload is None:
                    set_message("Edit cancelled", 3.0)
                else:
                    target.apply(payload)
                    save_entries(f"Updated {target.name}")
            elif key in ("d", "D") and entries:
                target = entries[selected_index]
                if confirm_delete(target):
                    removed = entries.pop(selected_index)
                    if selected_index >= len(entries):
                        selected_index = max(0, len(entries) - 1)
                    save_entries(f"Deleted {removed.name}")
                else:
                    set_message("Delete cancelled", 3.0)
            elif key in ("c", "C"):
                last_config_mtime = 0.0
            elif key in ("q", "Q"):
                running = False
        if message_until and now > message_until:
            global_message = None
            message_until = 0.0
        if now - last_render > 0.25:
            os.system("cls")
            print(build_display(entries, selected_index, global_message))
            last_render = now
        time.sleep(0.1)
    os.system("cls")
    print("Rerun EXE exited.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        os.system("cls")
        print("Rerun EXE interrupted.")
```