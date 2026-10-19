# UsageBar

A native macOS menu bar app for checking Claude and Codex subscription usage together. Click the bar-chart icon or press **Control–Option–U** to open it.

Usage checks happen **only when you open the panel or press Refresh**. There is no polling, scheduled refresh, login item, or usage-history database. The menu bar app stays idle between requests so its icon and global shortcut remain available. Closing the panel cancels pending requests and stops the temporary Codex subprocess.

## Build and run

Requires macOS 14 or later and Apple's Command Line Tools with Swift 6 or later (`xcode-select --install`). There are no third-party package dependencies.

```sh
bash scripts/build-app.sh
open dist/UsageBar.app
```

The app runs without a Dock icon. Open its gear menu to change the global shortcut to Command–Shift–U or disable it. A shortcut conflict is reported without replacing a working shortcut. Use the Quit button to stop the app completely. To keep the app, copy `dist/UsageBar.app` to Applications; it does not automatically start at login.

## Sign-in and usage sources

- **Codex:** install the Codex CLI and run `codex login` with your ChatGPT subscription account. UsageBar locates `codex` in PATH, Homebrew, `~/.local/bin`, or the Codex app bundle. It passes those same search paths to the subprocess so npm installations can find Node.js when launched from Finder. It starts a temporary `codex app-server`, completes the protocol handshake, reads `account/rateLimits/read`, and stops the process. No conversation or model generation is started. The returned window durations determine the labels; windows that are unavailable are not invented.
- **Claude:** sign in to Claude Code using `claude` and `/login`. On request, UsageBar reads the existing `Claude Code-credentials` macOS Keychain entry and queries `https://api.anthropic.com/api/oauth/usage`. macOS may ask you to allow keychain access. UsageBar does not modify credentials or refresh Claude's tokens; if the login expires, open Claude Code to renew it. Only the normal Claude Code keychain service is supported in this first version.

The app displays percentages **used**, each window's next reset in your local time, and the last successful check time. Previous readings remain visible if a subsequent refresh fails, with an error and their original timestamp. Unknown or missing data is never displayed as zero.

Claude's usage endpoint is **undocumented and may change or rate-limit requests**. There are no automatic retries. Codex's app-server protocol can also evolve; the installed CLI must support `account/rateLimits/read`. This initial app reads Claude's overall five-hour and weekly limits, rather than additional per-model limits. API billing accounts are separate from subscription usage.

## Check

```sh
bash scripts/test.sh
dist/UsageBar.app/Contents/MacOS/UsageBar --check-live
```

Tests use synthetic responses and local fake processes. The explicit `--check-live` command performs a single real check of each provider, prints usage or an actionable error, and exits with a nonzero status if either provider fails. It does not print credentials.

## Privacy and distribution

Credentials stay in the providers' existing stores; Claude's access token is used in memory for its HTTPS usage request. The app has no telemetry, disk cache, or usage logs, and redirects are rejected for the Claude request. Codex app-server is launched with analytics and the OpenTelemetry exporter disabled; the CLI may still maintain its own local files. The app makes no provider requests at startup.

The build is ad-hoc signed for local use, without an Apple Developer certificate or notarization. Rebuilding can require granting keychain access again. Cross-Mac distribution and App Store packaging are not configured.

## Implementation references

- [Official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server), including initialization and `account/rateLimits/read`.
- [Claude's subscription usage limits](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan).
- [Claude usage endpoint report in Anthropic's tracker](https://github.com/anthropics/claude-code/issues/30930) (an implementation reference, not a supported public API contract).
