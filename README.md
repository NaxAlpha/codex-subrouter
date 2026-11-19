# Codex SubRouter

A small macOS menu-bar app for selecting **Codex subscription access or
OpenRouter**, using your existing Codex configuration. Restart Codex manually
when you are ready. No model-entry dialogs, account vault, gateway, or history
migration service.

Codex SubRouter is an independent utility for Codex and OpenRouter.

## Requirements

- macOS 14 or later. The self-tests have run on Apple Silicon in both native
  and Intel (Rosetta) builds.
- The Codex desktop app with a bundled executable that supports
  `app-server --print-startup-config`. The menu reports when Codex needs an
  update before switching.
- An existing Codex configuration. The subscription route uses provider ID
  `openai`; the OpenRouter route uses `openrouter`.
- OpenRouter must already be registered and authenticated in Codex. The helper
  does not create provider definitions, sign you in, or supply API keys. See
  [Codex custom-provider configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers).

## Build and run

With Xcode command-line tools installed, from the repository root:

```sh
./scripts/build.sh
open "dist/Codex SubRouter.app"
```

The app has no window or Dock icon. Open its menu-bar icon to switch providers,
open Codex, edit model settings, or view configuration backups. To start it at
login, add it in **System Settings → General → Login Items**.

The build uses the current Mac's architecture. Set `BUILD_ARCH=arm64` or
`BUILD_ARCH=x86_64` to cross-compile. Cross-compiled executables are not run by
the build script; test them on a matching Mac before releasing them. Set
`APP_BUNDLE_ID` at build time if you want a publisher-specific bundle identifier.

Build the app locally from this repository. The build script uses an ad-hoc
signature for local development. Distributing a downloadable app requires a
Developer ID signature and notarization for the standard Gatekeeper flow.

## Models: your choices, no built-in defaults

The app remembers the model currently saved in Codex for the selected provider.
It does not hardcode model IDs or replace Codex's model catalog.

For a provider you have not used with the helper yet, choose its model once via
**Open Model Settings…** or the command below. A switch remains disabled until
that provider has a saved model; the app never guesses a model or prompts in a
dialog. Previously selected models remain the defaults until you change them.

```sh
"dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" \
  --set-model openrouter YOUR_OPENROUTER_MODEL_ID
```

Replace the final argument with a real model ID from your provider. Use `openai`
instead of `openrouter` to save a subscription model. This command changes only
the helper's model preference, not the Codex provider or config.

Preferences live in `provider-switcher.json` inside the selected Codex home.
Its format is shown here using **synthetic placeholders, not real model IDs**:

```json
{
  "models": {
    "openai": "subscription-test-model",
    "openrouter": "vendor/test-model"
  }
}
```

When Codex saves a different root model for the currently selected provider, the
helper remembers that model. It does not depend on version-specific model lists.

### Importing preferences from an older helper build

If an older build stored model choices in a macOS preferences plist, import it
explicitly:

```sh
"dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" \
  --import-preferences "/path/to/old-switcher-preferences.plist"
```

Only `model.openai` and `model.openrouter` are considered. Existing model choices
win. Account data, other preferences, and credentials are ignored. Do not copy
your entire preferences folder into this repository.

## Switching and manual restart

1. Choose **Switch to OpenRouter** or **Switch to Subscription**.
2. The app validates and saves the selection, keeps a config backup, and shows
   `*` plus **Quit and reopen Codex to apply**.
3. Finish your work, quit the desktop app normally, and reopen it yourself. The
   host may be named ChatGPT or Codex, depending on the installed desktop build.

Provider changes take effect after you quit and reopen Codex. With the default
home, the reminder clears when a newer desktop process appears. **Open Codex**
opens or focuses the app on demand.

The menu label reflects saved configuration. Codex project/profile settings,
environment overrides, or administrator policies may affect the effective route.
Only the global config's root fields are edited. Existing chats keep their
original context; continuing a chat across accounts/providers is a separate
compatibility question. This app does not rewrite chat metadata or repair
project layouts. Use a current desktop build for upstream project-preservation
fixes.

For switching between subscription accounts, keep using CodexBar or your normal
account workflow. This helper selects subscription **versus** OpenRouter; it does
not switch individual subscription accounts or access their credential stores.

## Codex homes and backups

By default the helper uses `~/.codex`. Set `CODEX_HOME` to select a different home;
the menu app and command-line tools use the same resolver. Absolute paths are
recommended. Relative paths resolve from the launching process's working
directory; `~/` resolves from the current user's home.

Finder and Login Items generally do not inherit your shell's environment. For a
custom home, quit an existing helper instance and launch the executable with the
desired environment, or use a LaunchAgent that supplies `CODEX_HOME`:

```sh
CODEX_HOME="/absolute/path/to/codex-home" \
  "dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter"
```

Model settings and restart reminders are isolated by Codex home. Private config
backups are stored under:

```text
~/Library/Application Support/Codex SubRouter/Backups/<home-scope>/
```

For a custom home, quit Codex manually and use **Open Codex** in SubRouter to
launch it with the selected `CODEX_HOME`. Once you've reopened the correct
home, use **Dismiss Restart Reminder**. A newly launched desktop process alone
cannot establish which home it loaded.

Backups are complete configs and may contain private project paths or inline
credentials you put in your config. Keep them local. **Copy Error Details** may
also include local paths; redact reports before sharing them. See [SECURITY.md](SECURITY.md).

## Checks and release packaging

```sh
"dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" --self-test
"dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" --validate-current
./scripts/package.sh
```

Self-tests use temporary synthetic data and need no credentials or installed
Codex. Validation verifies the OpenAI signatures of the desktop app and bundled
executable. It runs Codex's startup check in the selected Codex home with
command-line overrides for each saved model and provider. This keeps relative
configuration paths and local administrator requirements in scope. Providers
without a saved model are reported as skipped. The helper leaves the config
file untouched during validation, strips provider-key environment variables
from the subprocess, and stops the check after a timeout. Network activity
during startup depends on the installed Codex version and configuration.

Config saves verify the original file and symlink target after validation and
preserve ownership, permissions, ACLs, and extended attributes. Configs with
hard links or special file flags require a manual edit. The app uses an atomic
exchange on supported volumes such as APFS. If another edit reaches disk during
the exchange, SubRouter restores it when possible. If further writes prevent
recovery, the error gives the path of the preserved file.

The package script builds a fresh app and archives only the expected release
files and the README, license, and security policy. It generates an app ZIP in `dist/` without resource forks,
extended attributes, `.DS_Store`, or `__MACOSX` entries. Source control excludes
all generated release artifacts, real configs, backups, and chat data. The
workflow builds/tests on macOS and scans source for secrets. Release signing and
publishing are separate steps.

## Development scope

The source is plain Swift/AppKit with no third-party runtime dependencies. Model
choices are local configuration, not a maintained model catalog. The project
intentionally stays focused on two routes and manual restart.

Licensed under [MIT](LICENSE).
