"""Command-line interface for the voiceflow daemon and thin client."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections.abc import Sequence
from typing import Any

from voiceflow.config import Config, load_config
from voiceflow.daemon import DaemonAlreadyRunning, VoiceflowDaemon, send_request
from voiceflow.notifier import build_notifier

LOGGER = logging.getLogger(__name__)

_WINDOWS = os.name == "nt"

MODELS: tuple[tuple[str, str], ...] = (
    ("tiny", "~75 MB"),
    ("base", "~145 MB"),
    ("small", "~466 MB"),
    ("medium", "~1.5 GB"),
    ("large-v2", "~3.1 GB"),
    ("large-v3", "~3.1 GB"),
    ("large-v3-turbo", "~1.6 GB"),
    ("distil-large-v3", "~1.5 GB"),
)


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line argument parser."""
    parser = argparse.ArgumentParser(
        prog="voiceflow",
        description="Lokalne dyktowanie głosowe (Linux/Wayland i Windows)",
        add_help=False,
    )
    parser._optionals.title = "opcje"  # argparse does not expose this title publicly.
    parser.add_argument("-h", "--help", action="help", help="pokaż tę pomoc i zakończ")
    subparsers = parser.add_subparsers(dest="command", required=True, title="komendy")
    subparsers.add_parser("daemon", help="uruchom demona na pierwszym planie")
    subparsers.add_parser("toggle", help="rozpocznij lub zakończ nagrywanie")
    subparsers.add_parser("start", help="rozpocznij nagrywanie")
    subparsers.add_parser("stop", help="zakończ nagrywanie i transkrybuj")
    subparsers.add_parser("cancel", help="anuluj bieżące nagranie")
    subparsers.add_parser("quit", help="zatrzymaj działającego demona")
    subparsers.add_parser("status", help="pokaż stan i diagnostykę")
    subparsers.add_parser("models", help="pokaż dostępne modele")
    last = subparsers.add_parser("last", help="pokaż ostatnie dyktowania (ratunek po wklejce w złe okno)")
    last.add_argument("-n", type=int, default=1, metavar="N", help="ile ostatnich wpisów pokazać")
    last.add_argument("--copy", action="store_true", help="skopiuj najnowszy tekst do schowka")
    subparsers.add_parser("update", help="sprawdź, czy jest nowsza wersja")
    room = subparsers.add_parser("room", help="wspólny pokój dyktowania")
    room_sub = room.add_subparsers(dest="room_command", required=True)
    room_create = room_sub.add_parser("create", help="utwórz pokój i zacznij sesję")
    room_create.add_argument("--server", default="wss://rooms.pbdevs.com")
    room_create.add_argument("--as", dest="display_name", required=True, help="Twoja nazwa w rankingu")
    room_create.add_argument("--name", default=None, help="nazwa pokoju")
    room_join = room_sub.add_parser("join", help="dołącz do istniejącego pokoju")
    room_join.add_argument("code", help="sześcioznakowy kod pokoju")
    room_join.add_argument("--server", default="wss://rooms.pbdevs.com")
    room_join.add_argument("--as", dest="display_name", required=True, help="Twoja nazwa w rankingu")
    room_sub.add_parser("leave", help="wyjdź z pokoju (wyłącza go w konfiguracji)")
    subparsers.add_parser(
        "download-model", help="pobierz model mowy z paskiem postępu (używane przez instalator)"
    )
    return parser


def _configure_logging(config: Config) -> None:
    level = getattr(logging, config.log_level, logging.INFO)
    handlers: list[logging.Handler] = []
    # Under pythonw.exe — how the Windows daemon is launched, so no console
    # flashes over the user's work — sys.stderr is None and a StreamHandler
    # would raise on the first log record written.
    if sys.stderr is not None:
        handlers.append(logging.StreamHandler())
    if _WINDOWS:
        # The Windows daemon is launched hidden (no console), so stderr goes
        # nowhere - a log file is the only way to diagnose anything.
        from voiceflow.paths import data_dir

        try:
            data_dir().mkdir(parents=True, exist_ok=True)
            handlers.append(
                logging.FileHandler(data_dir() / "daemon.log", encoding="utf-8")
            )
        except OSError:
            pass
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        handlers=handlers,
    )


def _platform_injector(config: Config) -> Any:
    """Build the injector this OS actually uses, for offline diagnostics."""
    if _WINDOWS:
        from voiceflow.winplat.injector import WinInjector

        return WinInjector(config.inject)
    from voiceflow.injector import Injector

    return Injector(config.inject)


def _client_command(command: str, config: Config) -> int:
    try:
        response = send_request(command, timeout=1.5)
    except RuntimeError as exc:
        message = f"Błąd: {exc}"
        print(message, file=sys.stderr)
        notifier = build_notifier(config.notifications)
        notifier.send(f"❌ {exc}", urgency="critical")
        notifier.flush()
        return 1
    stream = sys.stdout if response.get("ok") else sys.stderr
    print(response.get("message", json.dumps(response, ensure_ascii=False)), file=stream)
    return 0 if response.get("ok") else 1


def _yes_no(value: Any) -> str:
    return "tak" if value else "nie"


def _print_injection_details(injection: dict[str, Any]) -> None:
    """Print whichever backend's diagnostics this platform reported."""
    if _WINDOWS:
        print(f"  schowek: {_yes_no(injection.get('clipboard'))}")
        print(f"  skrót wklejania: {_yes_no(injection.get('send_input'))}")
        return
    print(f"  ydotool: {_yes_no(injection.get('ydotool_binary'))}")
    responding = "odpowiada" if injection.get("ydotool_socket_responding") else "nie odpowiada"
    print(f"  socket: {injection.get('ydotool_socket', '?')} ({responding})")
    print(f"  /dev/uinput zapisywalny: {_yes_no(injection.get('uinput_writable'))}")
    print(
        f"  wl-copy / wl-paste: {_yes_no(injection.get('wl_copy_binary'))}"
        f" / {_yes_no(injection.get('wl_paste_binary'))}"
    )


def _print_status(config: Config) -> int:
    try:
        response = send_request("status", timeout=2.0)
    except RuntimeError as exc:
        print(f"Demon: nie działa ({exc})")
        probe = _platform_injector(config).probe()
        print(f"Wstrzykiwanie: {probe.summary}")
        print(f"Model (konfiguracja): {config.model.name}, {config.model.device}/{config.model.compute_type}")
        if _WINDOWS:
            print(f"Skrót (konfiguracja): {config.hotkey.binding}")
        return 1
    print(f"Demon: działa, stan {response.get('state', '?')}")
    print(
        "Model: "
        f"{response.get('model', '?')}, {response.get('device', '?')}/{response.get('compute_type', '?')}"
    )
    if response.get("hotkey"):
        print(f"Skrót: {response['hotkey']}")
    injection: Any = response.get("injection", {})
    summary = injection.get("summary", "brak danych") if isinstance(injection, dict) else "brak danych"
    print(f"Wstrzykiwanie: {summary}")
    if isinstance(injection, dict):
        _print_injection_details(injection)
    return 0


def _print_models() -> int:
    print("Dostępne modele faster-whisper (przybliżony rozmiar pobierania):")
    for name, size in MODELS:
        marker = " (domyślny)" if name == "large-v3-turbo" else ""
        print(f"  {name:<18} {size}{marker}")
    return 0


def _print_last(count: int, copy: bool) -> int:
    from voiceflow.history import read_records

    records = [r for r in read_records(limit=max(count, 1) * 3) if r.text]
    if not records:
        print("Historia jest pusta (albo history.store_text jest wyłączone).")
        return 1
    for record in records[-count:]:
        print(f"[{record.timestamp}] ({record.words} słów)")
        print(f"  {record.text}")
    if copy:
        return _copy_to_clipboard(records[-1].text)
    return 0


def _copy_to_clipboard(text: str) -> int:
    """Put recovered text back on the clipboard, per platform."""
    if _WINDOWS:
        from voiceflow.config import DEFAULT_PASTE_KEY
        from voiceflow.winplat.injector import _set_clipboard_text

        try:
            _set_clipboard_text(text)
        except OSError as exc:
            print(f"Nie mogę skopiować do schowka: {exc}", file=sys.stderr)
            return 1
        print(f"Skopiowano najnowszy tekst do schowka — wklej {DEFAULT_PASTE_KEY.title()}.")
        return 0

    import shutil as _shutil
    import subprocess as _subprocess

    wl_copy = _shutil.which("wl-copy")
    if wl_copy is None:
        print("Brak wl-copy — nie mogę skopiować.", file=sys.stderr)
        return 1
    process = _subprocess.Popen(
        [wl_copy],
        stdin=_subprocess.PIPE,
        stdout=_subprocess.DEVNULL,
        stderr=_subprocess.DEVNULL,
        shell=False,
    )
    assert process.stdin is not None
    process.stdin.write(text.encode("utf-8"))
    process.stdin.close()
    process.wait(timeout=3)
    print("Skopiowano najnowszy tekst do schowka — wklej Ctrl+Shift+V.")
    return 0


def _download_model(config: Config) -> int:
    """Fetch the configured model up front, with visible progress.

    Called at the end of installation so the first dictation is instant —
    a silent background download of 1.6 GB was rightly rejected as bad UX.
    huggingface_hub renders tqdm progress bars in a terminal by itself.
    """
    from faster_whisper import download_model

    name = config.model.name
    print(f"Pobieranie modelu mowy: {name}")
    print("(pliki i pasek postępu poniżej; pobrane raz, używane lokalnie)")
    try:
        path = download_model(name)
    except Exception as exc:
        print(f"Nie udało się pobrać modelu: {exc}", file=sys.stderr)
        print("Model pobierze się automatycznie przy pierwszym dyktowaniu.", file=sys.stderr)
        return 1
    print(f"Model gotowy: {path}")
    return 0


def _print_update() -> int:
    import os

    from voiceflow.updates import check, installed_version

    from voiceflow.config import UpdatesConfig

    info = check(UpdatesConfig(), force=True)
    current = installed_version()
    if info is None:
        print(f"Zainstalowana wersja: {current}. Nie udało się sprawdzić GitHuba (offline?).")
        return 1
    if not info.newer:
        print(f"Masz najnowszą wersję ({current}).")
        return 0
    print(f"Dostępna nowa wersja: {info.latest} (masz {current})")
    print(f"Co się zmieniło: {info.url}")
    if os.name == "nt":
        print("Aktualizacja: uruchom ponownie voiceflow-install.bat")
    else:
        print(
            "Aktualizacja: curl -fsSL "
            "https://raw.githubusercontent.com/AveJaPl/voiceflow/main/install.sh | bash"
        )
    return 0


def _room_command(args) -> int:
    """Create or join a room and write the result into config.yaml."""
    from voiceflow.config import load_config
    from voiceflow.paths import config_dir
    from voiceflow.roomsetup import RoomSetupError, create_room, join_room, save_to_config

    if args.room_command == "leave":
        config = load_config()
        save_to_config(config.room.server, config.room.code, config.room.token)
        path = config_dir() / "config.yaml"
        text = path.read_text(encoding="utf-8").replace("  enabled: true\n  server:", "  enabled: false\n  server:")
        path.write_text(text, encoding="utf-8")
        print("Wyszedłeś z pokoju. Dyktowanie działa dalej, lokalnie.")
        print("Zrestartuj demona: systemctl --user restart voiceflow")
        return 0

    existing = load_config().room.token
    try:
        if args.room_command == "create":
            result = create_room(args.server, args.name, args.display_name, existing)
        else:
            result = join_room(args.server, args.code, args.display_name, existing)
        save_to_config(args.server, result["code"], result["token"])
    except RoomSetupError as exc:
        print(f"Nie udało się: {exc}", file=sys.stderr)
        return 1

    web = args.server.replace("wss://", "https://").replace("ws://", "http://").rstrip("/")
    print(f"Pokój: {result['code']}")
    print(f"Ranking na tablecie: {web}/room/{result['code']}")
    print("Podaj ten kod drugiej osobie: voiceflow room join "
          f"{result['code']} --as ImieNazwa")
    print("Zrestartuj demona, żeby dołączyć: systemctl --user restart voiceflow")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run the voiceflow command-line interface."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.command == "models":
        return _print_models()
    if arguments.command == "last":
        return _print_last(arguments.n, arguments.copy)
    if arguments.command == "update":
        return _print_update()
    if arguments.command == "room":
        return _room_command(arguments)
    try:
        config = load_config()
    except RuntimeError as exc:
        print(f"Błąd konfiguracji: {exc}", file=sys.stderr)
        return 2
    _configure_logging(config)
    if arguments.command == "download-model":
        return _download_model(config)
    if arguments.command == "daemon":
        notifier = build_notifier(config.notifications)
        try:
            VoiceflowDaemon(config).run()
        except DaemonAlreadyRunning:
            # The Start Menu icon and the autostart shortcut run this same
            # command, so this is a user clicking the icon on a healthy system.
            # Silence here reads as "the app won't open"; say it is running and
            # remind them how to use it, because there is no window to show.
            message = f"voiceflow już działa — wciśnij {config.hotkey.binding} i mów"
            LOGGER.info("%s", message)
            print(message)
            notifier.send(message)
            notifier.flush()
            return 0
        except (RuntimeError, OSError) as exc:
            LOGGER.error("Nie można uruchomić demona: %s", exc)
            notifier.send(f"❌ Nie można uruchomić demona: {exc}", urgency="critical")
            # Without this the process exits and takes the toast thread with it.
            notifier.flush()
            return 1
        return 0
    if arguments.command == "status":
        return _print_status(config)
    # `quit` reads better than the wire-level name for the one command whose
    # job is ending a background process the user never explicitly started.
    command = "shutdown" if arguments.command == "quit" else arguments.command
    return _client_command(command, config)


if __name__ == "__main__":
    raise SystemExit(main())
