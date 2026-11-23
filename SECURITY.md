# Security policy

## Supported versions

Only the latest release of each platform receives security fixes: the newest `v*`
release for Linux and Windows, and the newest `mac-v*` release for macOS. Android
and iOS are build-from-source alphas.

## Scope

Reports are especially welcome for:

- the installers: `install.sh` (run as `curl | bash`) and `windows/install.ps1`
  (run as `irm | iex`), and the update flow;
- access to the microphone and the clipboard (voiceflow records audio, writes the
  clipboard and restores its previous contents);
- the optional HTTP server (`voiceflow serve`), which requires a Bearer token;
- shared dictation rooms ([rooms/](rooms/README.md)) and the remote microphone
  relay ([relay/](relay/README.md)).

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**
(<https://github.com/AveJaPl/voiceflow/security/advisories/new>).

Include the affected version and platform, steps to reproduce, and the impact you
expect. You will get a reply in the advisory thread; once a fix is released, the
advisory is published with credit to you unless you prefer otherwise.
