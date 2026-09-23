# The catalogs

Fluent message files (https://projectfluent.org, the `.ftl` syntax), one
file per app and locale, flat as every family is: `l10n/<app>.<tag>.ftl`.
Written by this repo, for this repo's example apps; there is no upstream and
nothing to regenerate — a translator edits the file. The core loads
`<app>.<locale>.ftl`, then the language alone, then identity.toml's
`default_locale` (docs/compliance-plan.md §2.4), resolves messages with
fluent-bundle, and formats every `{ $value }` through the platform's own
formatter. tools/check-l10n.py holds every key a guest names to exist in
every file an app ships.
