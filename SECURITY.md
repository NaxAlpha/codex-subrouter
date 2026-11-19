# Privacy and security

The helper changes the root model/provider fields in your existing Codex config,
records local model choices, and creates local config backups. It does not read
authentication files or Keychain credentials directly, send telemetry, rewrite
chat history, manage subscription accounts, or patch Codex.

Validation verifies the desktop app and bundled executable against OpenAI's
Apple code-signing identity. It invokes Codex's startup check in the selected
Codex home with temporary command-line model and provider overrides and a
restricted environment. Codex startup can consult the selected home's
configuration, credential helpers, and administrator policies.

Full configuration backups may contain private project paths or inline secrets
from your configuration. Model preferences, reminders, and backups stay local.
Do not upload them, auth files, databases, or unredacted error details to issues.

Before filing a security report, remove tokens, account identifiers, local paths,
and chat content. Use the repository's private vulnerability-reporting feature
if enabled. Otherwise request a private contact route without posting the
vulnerability details publicly.

The project distributes source. The build script uses an ad-hoc signature for
local development builds.
