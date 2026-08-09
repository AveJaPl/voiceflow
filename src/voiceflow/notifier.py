"""Best-effort desktop notifications through notify-send."""

from __future__ import annotations

import logging
import shutil
import subprocess

from voiceflow.config import NotificationsConfig

LOGGER = logging.getLogger(__name__)
NOTIFICATION_ID = "87341"


class Notifier:
    """Send replaceable desktop notifications without making them fatal."""

    def __init__(self, config: NotificationsConfig) -> None:
        self.enabled = config.enabled
        self._binary = shutil.which("notify-send")
        if self.enabled and self._binary is None:
            LOGGER.info("notify-send nie jest dostępny; powiadomienia są wyłączone")

    def send(self, message: str, *, urgency: str = "normal", expire_ms: int | None = None) -> None:
        """Display a notification, or quietly log a delivery failure.

        ``expire_ms`` should outlast the caller's refresh interval. Without it the
        shell hides the banner on its own schedule, so a replacement slides in as
        a visibly new notification instead of updating the one already on screen.
        """
        if not self.enabled or self._binary is None:
            return
        command = [
            self._binary,
            "--app-name=voiceflow",
            f"--replace-id={NOTIFICATION_ID}",
            f"--urgency={urgency}",
        ]
        if expire_ms is not None:
            command.append(f"--expire-time={expire_ms}")
        command += [
            "voiceflow",
            message,
        ]
        try:
            result = subprocess.run(command, check=False, timeout=3, shell=False)
            if result.returncode != 0:
                LOGGER.warning("notify-send zakończył się kodem %d", result.returncode)
        except (OSError, subprocess.TimeoutExpired) as exc:
            LOGGER.warning("Nie udało się wysłać powiadomienia: %s", exc)

