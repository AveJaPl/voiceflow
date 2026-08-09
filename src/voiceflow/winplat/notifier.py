"""Desktop notifications on Windows, matching the notify-send contract.

This exists because the Windows daemon runs with no console: when recording or
injection fails, a log line nobody will read is the only trace. On Linux the
same failure raises a notify-send banner that persists in the tray, and the
port is not honest without an equivalent.

Toasts go through the WinRT ``Windows.UI.Notifications`` API driven by
PowerShell — the one route that needs no third-party package and lands in the
Action Center, where an error stays readable after the banner fades. Delivery
is best-effort and always off the calling thread: a notification must never
delay a dictation, and must never be the thing that takes the daemon down.
"""

from __future__ import annotations

import logging
import subprocess
import threading

from voiceflow.config import NotificationsConfig

LOGGER = logging.getLogger(__name__)

#: Toasts must be attributed to a registered AppUserModelID or they never
#: appear. PowerShell's own is present on every Windows 10/11 install, so it is
#: what a script-driven toast can safely borrow.
_APP_ID = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"

_SCRIPT = """
$ErrorActionPreference = 'Stop'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($env:VOICEFLOW_TOAST_XML)
$toast = New-Object Windows.UI.Notifications.ToastNotification $xml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($env:VOICEFLOW_TOAST_APPID).Show($toast)
"""

#: Keeps a spawned PowerShell from flashing a console window over whatever the
#: user is typing into. Defined by the Win32 process-creation flags.
_CREATE_NO_WINDOW = 0x08000000


def _escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def build_toast_xml(message: str, *, urgency: str = "normal") -> str:
    """Build the toast payload. Pure, so the escaping is testable anywhere."""
    # Errors get the long duration so a failed dictation is still on screen when
    # the user looks up from the keyboard; routine notices use the default.
    duration = ' duration="long"' if urgency == "critical" else ""
    return (
        f'<toast{duration}><visual><binding template="ToastGeneric">'
        f"<text>voiceflow</text><text>{_escape(message)}</text>"
        f"</binding></visual></toast>"
    )


class WinNotifier:
    """Best-effort Windows toasts; failures degrade to a log line."""

    def __init__(self, config: NotificationsConfig) -> None:
        self.enabled = config.enabled

    def send(self, message: str, *, urgency: str = "normal", expire_ms: int | None = None) -> None:
        """Show a notification without blocking or raising.

        ``expire_ms`` is accepted for parity with the Linux notifier; Windows
        controls toast dwell time itself and only distinguishes long from short.
        """
        if not self.enabled:
            return
        xml = build_toast_xml(message, urgency=urgency)
        threading.Thread(
            target=self._show, args=(xml,), name="voiceflow-toast", daemon=True
        ).start()

    def _show(self, xml: str) -> None:  # pragma: no cover - needs a Windows session
        import os

        environment = dict(os.environ, VOICEFLOW_TOAST_XML=xml, VOICEFLOW_TOAST_APPID=_APP_ID)
        try:
            result = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    _SCRIPT,
                ],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=15,
                shell=False,
                creationflags=_CREATE_NO_WINDOW,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            LOGGER.warning("Nie udało się wysłać powiadomienia: %s", exc)
            return
        if result.returncode != 0:
            detail = result.stderr.decode(errors="replace").strip().splitlines()
            LOGGER.warning(
                "Powiadomienie odrzucone przez system: %s",
                detail[0] if detail else f"kod {result.returncode}",
            )
