# UsageBar

A native macOS menu bar app for checking Claude, Codex, and Antigravity subscription usage together. Click the bar-chart icon or press **Control–Option–U** to open it.

Usage checks happen **only when you open the panel or press Refresh**. There is no polling, scheduled refresh, login item, or usage-history database. The menu bar app stays idle between requests so its icon and global shortcut remain available. Closing the panel cancels pending requests and stops temporary CLI subprocesses.

## Build and run

Requires macOS 14 or later and Apple's Command Line Tools with Swift 6 or later (`xcode-select --install`). There are no third-party package dependencies.

```sh
bash scripts/build-app.sh
open dist/UsageBar.app
```

The app runs without a Dock icon. Open its gear menu to change the global shortcut to Command–Shift–U or disable it. A shortcut conflict is reported without replacing a working shortcut. Use the Quit button to stop the app completely. To keep the app, copy `dist/UsageBar.app` to Applications; it does not automatically start at login.

## Sign-in and usage sources

- **Codex:** install the Codex CLI and run `codex login` with your ChatGPT subscription account. UsageBar locates `codex` in PATH, Homebrew, `~/.local/bin`, or the Codex app bundle. It passes those same search paths to the subprocess so npm installations can find Node.js when launched from Finder. It starts a temporary `codex app-server`, completes the protocol handshake, reads `account/rateLimits/read`, and stops the process. No conversation or model generation is started. The returned window durations determine the labels; Business/Enterprise accounts without rolling windows show their `individualLimit` spend-control limit instead. Windows that are unavailable are not invented.
- **Claude:** sign in to Claude Code using `claude` and `/login`. On request, UsageBar reads the existing `Claude Code-credentials` macOS Keychain entry through `/usr/bin/security`, the same tool Claude Code uses to store it, and queries `https://api.anthropic.com/api/oauth/usage`. Because that tool is already trusted by the entry, macOS does not ask for keychain access, including after rebuilds. Each Claude Code config directory keeps its own login, so to watch several Claude organizations, sign in to each one from its own directory (e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude`, then `/login`). UsageBar shows one card for the default `~/.claude` login and one for every `~/.claude-*` directory that has credentials, labeled with that directory's organization name. UsageBar does not modify credentials or refresh Claude's tokens; if the login expires, open Claude Code to renew it. Only the normal Claude Code keychain service is supported in this first version.
- **Antigravity:** install the Antigravity CLI (`agy` 1.1.11 or later) and run `agy` to sign in. On request, UsageBar runs `agy -p /usage --output-format json` in a private temporary directory with auto-updates disabled and browser sign-in popups blocked, then parses the returned Gemini and Claude/GPT 5-hour and weekly quota buckets. No model turn is started.

The app displays percentages **used**, each window's next reset in your local time, and the last successful check time. Previous readings remain visible if a subsequent refresh fails, with an error and their original timestamp. Unknown or missing data is never displayed as zero.

Claude's usage endpoint is **undocumented and may change or rate-limit requests**. There are no automatic retries. Codex's app-server protocol can also evolve; the installed CLI must support `account/rateLimits/read`. UsageBar reads Claude's overall five-hour and weekly limits, plus any model-specific weekly limit the plan has (such as Fable), which appears as an extra row. API billing accounts are separate from subscription usage.

## Multiple Claude organizations

Claude Code stores one organization login per config directory, so switching organizations with `/login` in default `claude` replaces the previous login. To track multiple Claude organizations or subscriptions side by side in UsageBar:

1. Keep your primary organization signed in on the default `~/.claude`:
   ```sh
   claude
   ```
   Run `/login`, choose your primary organization, then `/exit`.

2. Sign in to each additional organization using its own `~/.claude-*` directory:
   ```sh
   CLAUDE_CONFIG_DIR=~/.claude-work claude
   ```
   Run `/login`, choose the second organization, then `/exit`.

3. Open UsageBar and click **Refresh**. UsageBar automatically lists the default `~/.claude` card first, followed by one card per `~/.claude-*` directory with credentials, labeled with each organization's name.

Optional shell alias in `~/.zshrc` for launching the secondary organization from the terminal:
```sh
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
```

If a secondary organization's token later expires, open Claude Code once with the same `CLAUDE_CONFIG_DIR` to renew it, then refresh UsageBar.

## Check

```sh
bash scripts/test.sh
dist/UsageBar.app/Contents/MacOS/UsageBar --check-live
```

Tests use synthetic responses and local fake processes. The explicit `--check-live` command performs a single real check of each provider, prints usage or an actionable error, and exits with a nonzero status if either provider fails. It does not print credentials.

## Privacy and distribution

Credentials stay in the providers' existing stores; Claude's access token is used in memory for its HTTPS usage request. The app has no telemetry, disk cache, or usage logs, and redirects are rejected for the Claude request. Codex app-server is launched with analytics and the OpenTelemetry exporter disabled; the CLI may still maintain its own local files. The app makes no provider requests at startup.

The build is ad-hoc signed for local use, without an Apple Developer certificate or notarization. Cross-Mac distribution and App Store packaging are not configured.

## Implementation references

- [Official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server), including initialization and `account/rateLimits/read`.
- [Claude's subscription usage limits](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan).
- [Claude usage endpoint report in Anthropic's tracker](https://github.com/anthropics/claude-code/issues/30930) (an implementation reference, not a supported public API contract).
- [Antigravity CLI changelog](https://antigravity.google/changelog) (non-interactive `agy -p /usage --output-format json` introduced in 1.1.11).
