"""Command-line interface for the voiceflow daemon and thin client."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from collections.abc import Sequence
from typing import Any

from voiceflow.config import Config, load_config
from voiceflow.daemon import VoiceflowDaemon, send_request
from voiceflow.injector import Injector
from voiceflow.notifier import Notifier

LOGGER = logging.getLogger(__name__)

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
        description="Lokalne dyktowanie głosowe dla Linuxa/Wayland",
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
    subparsers.add_parser("status", help="pokaż stan i diagnostykę")
    subparsers.add_parser("models", help="pokaż dostępne modele")
    last = subparsers.add_parser("last", help="pokaż ostatnie dyktowania (ratunek po wklejce w złe okno)")
    last.add_argument("-n", type=int, default=1, metavar="N", help="ile ostatnich wpisów pokazać")
    last.add_argument("--copy", action="store_true", help="skopiuj najnowszy tekst do schowka")
    return parser


def _configure_logging(config: Config) -> None:
    level = getattr(logging, config.log_level, logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _client_command(command: str, config: Config) -> int:
    try:
        response = send_request(command, timeout=1.5)
    except RuntimeError as exc:
        message = f"Błąd: {exc}"
        print(message, file=sys.stderr)
        Notifier(config.notifications).send(f"❌ {exc}", urgency="critical")
        return 1
    stream = sys.stdout if response.get("ok") else sys.stderr
    print(response.get("message", json.dumps(response, ensure_ascii=False)), file=stream)
    return 0 if response.get("ok") else 1


def _print_status(config: Config) -> int:
    try:
        response = send_request("status", timeout=2.0)
    except RuntimeError as exc:
        print(f"Demon: nie działa ({exc})")
        probe = Injector(config.inject).probe()
        print(f"Wstrzykiwanie: {probe.summary}")
        print(f"Model (konfiguracja): {config.model.name}, {config.model.device}/{config.model.compute_type}")
        return 1
    print(f"Demon: działa, stan {response.get('state', '?')}")
    print(
        "Model: "
        f"{response.get('model', '?')}, {response.get('device', '?')}/{response.get('compute_type', '?')}"
    )
    injection: Any = response.get("injection", {})
    summary = injection.get("summary", "brak danych") if isinstance(injection, dict) else "brak danych"
    print(f"Wstrzykiwanie: {summary}")
    if isinstance(injection, dict):
        print(f"  ydotool: {'tak' if injection.get('ydotool_binary') else 'nie'}")
        print(f"  socket: {injection.get('ydotool_socket', '?')} ({'odpowiada' if injection.get('ydotool_socket_responding') else 'nie odpowiada'})")
        print(f"  /dev/uinput zapisywalny: {'tak' if injection.get('uinput_writable') else 'nie'}")
        print(f"  wl-copy / wl-paste: {'tak' if injection.get('wl_copy_binary') else 'nie'} / {'tak' if injection.get('wl_paste_binary') else 'nie'}")
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
        process.stdin.write(records[-1].text.encode("utf-8"))  # type: ignore[union-attr]
        process.stdin.close()
        process.wait(timeout=3)
        print("Skopiowano najnowszy tekst do schowka — wklej Ctrl+Shift+V.")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    """Run the voiceflow command-line interface."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    if arguments.command == "models":
        return _print_models()
    if arguments.command == "last":
        return _print_last(arguments.n, arguments.copy)
    try:
        config = load_config()
    except RuntimeError as exc:
        print(f"Błąd konfiguracji: {exc}", file=sys.stderr)
        return 2
    _configure_logging(config)
    if arguments.command == "daemon":
        try:
            VoiceflowDaemon(config).run()
        except (RuntimeError, OSError) as exc:
            LOGGER.error("Nie można uruchomić demona: %s", exc)
            Notifier(config.notifications).send(f"❌ Nie można uruchomić demona: {exc}", urgency="critical")
            return 1
        return 0
    if arguments.command == "status":
        return _print_status(config)
    return _client_command(arguments.command, config)


if __name__ == "__main__":
    raise SystemExit(main())
