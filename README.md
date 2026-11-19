# Codex SubRouter

Codex SubRouter is a macOS menu-bar app that switches Codex Desktop between your
**ChatGPT subscription** and **OpenRouter**. It remembers one model per route,
uses your existing Codex home, and lets you restart Codex when you're ready.

[Quick start](#quick-start) · [OpenRouter setup](#set-up-openrouter-for-desktop) ·
[Setup for agents](#setup-for-agents) · [Troubleshooting](#troubleshooting)

## Quick start

You need macOS 14 or later, Xcode Command Line Tools, and the official Codex
desktop app (named Codex or ChatGPT, depending on the build). The bundled Codex
executable needs to support `app-server --print-startup-config`. Open Codex once
with your subscription so you have an existing user-level `config.toml`.

1. **Build from source.** If `xcode-select -p` reports that developer tools are
   missing, run `xcode-select --install` and finish the macOS installer first.

   ```sh
   git clone https://github.com/NaxAlpha/codex-subrouter.git
   cd codex-subrouter
   ./scripts/build.sh
   ```

2. **Set up OpenRouter in Codex.** If your user-level config already has a
   working `openrouter` provider, keep it. Otherwise, follow
   [Set up OpenRouter for Desktop](#set-up-openrouter-for-desktop).

3. **Save a model for each route.** When the app opens, it remembers the
   active provider's explicit root `model` from `config.toml`. For any other
   route, or if the config uses an implicit default, save a model you choose.

   ```sh
   bin="dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter"
   "$bin" --set-model openrouter '<provider>/<model>'
   "$bin" --set-model openai '<subscription-model-id>'
   ```

   Replace the placeholders with actual IDs. OpenRouter IDs include the
   provider prefix. Pick one from the [OpenRouter model catalog](https://openrouter.ai/models).
   Use an ID available to your Codex subscription for `openai`. These commands
   save model preferences without changing the active route.

4. **Open the menu-bar app.** For a custom `CODEX_HOME`, use the
   [custom home launch command](#custom-codex-home).

   ```sh
   open "dist/Codex SubRouter.app"
   ```

   Look for the two-arrow icon in the macOS menu bar. The label shows `Sub`
   for subscription or `OR` for OpenRouter. To launch the helper at login, add
   the built app under **System Settings → General → Login Items**.

Use the same Codex home for the helper, the configuration steps, and the
desktop app. If you use `CODEX_HOME`, follow the
[custom home instructions](#custom-codex-home).

## Set up OpenRouter for Desktop

Use this setup when the user-level Codex config has no working `openrouter`
definition. The default config path is `~/.codex/config.toml`. Keep a private
backup and add the following tables once. Leave the existing root `model` and
`model_provider` entries in place so Codex stays on its current route. If
`model_providers` is already an inline table, merge the new provider into it.

```toml
[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
wire_api = "responses"

[model_providers.openrouter.auth]
command = "/usr/bin/security"
args = ["find-generic-password", "-s", "codex-subrouter-openrouter", "-w"]
```

Create an [OpenRouter API key](https://openrouter.ai/settings/keys). On the Mac
that runs Codex, enter the key at the hidden macOS Terminal prompt. Keep `-w`
at the end of the command to prompt for the value.

```sh
/usr/bin/security add-generic-password -U -a "$(id -un)" -s codex-subrouter-openrouter -w
```

Keep the key in Keychain. If macOS prompts for access when Codex first uses
OpenRouter, approve the request from the configured `security` command. For
an existing provider that uses a different Keychain item or credential
helper, use its existing settings.

Command-backed auth lets Codex load OpenRouter's model catalog on supported
versions. SubRouter keeps your saved model choices and lets Codex handle its
own model picker. See [Codex provider settings](https://learn.chatgpt.com/docs/config-file/config-advanced#custom-model-providers)
and [OpenRouter's Codex guide](https://openrouter.ai/blog/tutorials/codex-cli-openrouter/).

## Switch providers

1. Choose **Switch to OpenRouter** or **Switch to Subscription**.
2. Wait for the menu label to update. The `*` means the selection is saved
   and waiting for a restart. SubRouter validated the config and saved a backup.
3. Finish any active work, quit Codex normally, and reopen it. **Open Codex**
   in the SubRouter menu opens or focuses the app on demand.
4. To confirm routing, start a fresh chat. For OpenRouter, send a small test
   prompt and check [OpenRouter Activity](https://openrouter.ai/activity) for
   the selected model. Requests through OpenRouter are billed separately
   under your OpenRouter account.

SubRouter edits the root `model` and `model_provider` in the same config file.
Your project folders, local chats, and subscription sign-ins stay in their
existing home. Codex controls which chats you can see or continue under
each provider or account. Keep using CodexBar or your usual account workflow
to switch between subscription accounts. SubRouter switches between routes.

## Setup for agents

Use this checklist when asked to install Codex SubRouter on someone's Mac.
You can hand an agent this README with the prompt below.

> Set up Codex SubRouter on this Mac using the checklist in its README.
> Keep my current Codex route and any working provider settings. Ask me to
> enter credentials in Terminal and to choose any missing model IDs.

1. **Check the Mac and find the config.** Use `sw_vers` and `xcode-select -p`.
   Confirm the official Codex desktop app is installed. Find the existing
   user-level `config.toml` in the home that desktop uses, usually `~/.codex`.
   For remote or cloud agents, report which steps require the user's Mac.
2. **Clone and build.** Run the build commands in [Quick start](#quick-start)
   and verify that the build's self-tests pass. Ask the user to finish the
   macOS installer if developer tools are missing.
3. **Preserve the live configuration.** Check for an existing `openrouter`
   definition and explicit root model. If a provider definition is needed,
   back up the config privately, then merge just the new tables from
   [OpenRouter setup](#set-up-openrouter-for-desktop). Preserve the active
   provider, model, other settings, and any config symlink.
4. **Resolve user inputs locally.** If a new API key is needed, have the
   user enter it at the hidden Terminal prompt. Avoid printing API keys,
   raw config contents, or credential files. Reuse saved model preferences
   and the current route's explicit model. For missing choices, ask for the
   actual model IDs and save them with `--set-model`.
5. **Validate and launch.** Run the command below with the same Codex home.
   Check the result for each route. Codex SubRouter skips an inactive route
   without a saved model and an active route that uses an implicit default.
   If the check succeeds, open the built app and tell the user where to
   find its menu. Use the [custom home launch command](#custom-codex-home)
   when needed. Leave the active route and running Codex session as they
   are unless the user asks you to switch.

   ```sh
   "dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" --validate-current
   open "dist/Codex SubRouter.app"
   ```

The command runs Codex's startup configuration check. It validates config
loading and administrator requirements. A successful check does not establish
that credentials, billing, or a model request work. Use a fresh test chat for
that check when the user wants to verify live routing.

## Custom Codex home

Set `CODEX_HOME` consistently for the build's CLI commands and for the app at
launch. An absolute path is recommended because the app resolves relative
paths from its launch directory. Finder and Login Items generally do not
inherit variables exported in Terminal.

```sh
export CODEX_HOME="/absolute/path/to/codex-home"
bin="dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter"
"$bin" --validate-current
"$bin"
```

Quit any existing SubRouter instance before launching it for a different home.
After switching routes, quit Codex and choose **Open Codex** from SubRouter to
pass the custom home to the desktop app. When the correct home has reopened,
choose **Dismiss Restart Reminder**.

## Troubleshooting

| What you see | What to check |
| --- | --- |
| **Switch to OpenRouter** is disabled | Check that the user-level config defines `model_providers.openrouter` and that an OpenRouter model is saved. |
| **Switch to Subscription** is disabled | Save an available subscription model with `--set-model openai` or **Open Model Settings…**. |
| Codex cannot validate the selection | Check that the current official desktop app is installed, the config loads in Codex, and administrator policy permits the route. Then run `--validate-current` again. |
| OpenRouter returns an authentication or model error | Check Keychain access, your OpenRouter account or credits, and the exact model slug. Confirm that you reopened the intended Codex home. |
| The menu shows the right route but the chat behaves differently | Start a new chat and check for project or profile overrides. The menu reflects the saved global config. |

Use **Open Model Settings…** to edit the per-home `provider-switcher.json`
file. The `models` object uses `openai` and `openrouter` as keys. To recover a
previous selection, choose **Show Configuration Backups**, then restore the
previous root `model` and `model_provider` values in your current config and
restart Codex. Backups are stored in
`~/Library/Application Support/Codex SubRouter/Backups/<home-scope>/`.
They may contain private configuration. See [Privacy and security](SECURITY.md).

## Development

```sh
./scripts/build.sh
"dist/Codex SubRouter.app/Contents/MacOS/CodexSubRouter" --self-test
./scripts/package.sh
```

The project uses Swift and AppKit with no third-party runtime dependencies.
Builds use an ad-hoc signature for local use. The package script creates a
local ZIP in `dist/`. Distributing a downloadable app for the standard
Gatekeeper flow requires Developer ID signing and notarization.

Set `BUILD_ARCH=arm64` or `BUILD_ARCH=x86_64` to cross-compile and
`APP_BUNDLE_ID` to customize the bundle ID. Run the self-tests on a matching
system after cross-compiling. To migrate older helper preferences, use
`--import-preferences "/path/to/old-switcher-preferences.plist"`. The import
keeps existing model choices and imports only missing model IDs.

Codex SubRouter is an independent utility, licensed under [MIT](LICENSE).
