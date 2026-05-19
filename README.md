# technas-workflows

Reusable GitHub Actions workflows shared across all Technas products (BeautyGo, Rede, FarmCover, FleetPro, WashPro, OilDispatching, GMFitness, …).

This repo holds **workflow definitions only**. Each product repo references them from its own `.github/workflows/` via `uses:`.

## i18n workflows

Backed by the [`technas-i18n` Python package](https://nexus.technas.fr/repository/technas-pypi-hosted/) (CLI `technas-i18n {check,push,pull,bootstrap}`). The workflows install the CLI from Nexus and run it against the calling repo.

### `i18n-check.yml` — validate FR + warn on parity gaps

```yaml
# <product-repo>/.github/workflows/i18n-check.yml
name: i18n-check
on:
  push:
    paths: ['**/translations/**.json']
  pull_request:
    paths: ['**/translations/**.json']
jobs:
  check:
    uses: Technas-Organization/technas-workflows/.github/workflows/i18n-check.yml@main
    with:
      strict: false  # set true to fail CI on parity divergence
    secrets: inherit
```

### `i18n-push.yml` — sync FR → POEditor on commit

```yaml
# <product-repo>/.github/workflows/i18n-push.yml
name: i18n-push
on:
  push:
    branches: [main]
    paths: ['**/translations/fr.json']
jobs:
  push:
    uses: Technas-Organization/technas-workflows/.github/workflows/i18n-push.yml@main
    with:
      scopes: |
        packages/technas_i18n/:${{ vars.POEDITOR_PROJECT_ID_CORE }}
        BeautyGoApp/:${{ vars.POEDITOR_PROJECT_ID_CLIENT }}
        beauty_go_stylist/:${{ vars.POEDITOR_PROJECT_ID_STYLIST }}
        packages/:${{ vars.POEDITOR_PROJECT_ID_PACKAGES }}
      bot-actor: beautygo-poeditor-bot
    secrets: inherit
```

The `scopes` input maps a path prefix to a POEditor project id. First match wins (top-to-bottom), so put the most specific prefix first and the catch-all (`packages/`) last.

### `i18n-pull.yml` — sync POEditor → en/pt/es daily

```yaml
# <product-repo>/.github/workflows/i18n-pull.yml
name: i18n-pull
on:
  schedule: [{ cron: '0 4 * * *' }]
  workflow_dispatch:
jobs:
  pull:
    uses: Technas-Organization/technas-workflows/.github/workflows/i18n-pull.yml@main
    with:
      scopes: |
        packages/technas_i18n/assets/translations:${{ vars.POEDITOR_PROJECT_ID_CORE }}
        BeautyGoApp/assets/translations:${{ vars.POEDITOR_PROJECT_ID_CLIENT }}
        beauty_go_stylist/assets/translations:${{ vars.POEDITOR_PROJECT_ID_STYLIST }}
      package-scopes: |
        packages/technas_chat:${{ vars.POEDITOR_PROJECT_ID_PACKAGES }}
        packages/technas_alerts:${{ vars.POEDITOR_PROJECT_ID_PACKAGES }}
        packages/technas_inspiration:${{ vars.POEDITOR_PROJECT_ID_PACKAGES }}
      bot-actor: beautygo-poeditor-bot
      bot-email: poeditor-bot@beautygo.local
    secrets: inherit
```

`scopes` lists scopes where translations live directly under the path. `package-scopes` is a shortcut for shared packages where translations live under `<pkg>/assets/translations/`.

## Required secrets (org-level, inherited by all callers)

- `POEDITOR_API_TOKEN` — POEditor account API token.
- `POEDITOR_BOT_TOKEN` — PAT of the i18n bot account, with `repo` write on each product repo **and** each submodule.
- `NEXUS_USER`, `NEXUS_PASSWORD` — credentials for `nexus.technas.fr` (to install `technas-i18n` from the Technas PyPI index).

## Required repo variables (one set per product, defined in the calling repo)

- `POEDITOR_PROJECT_ID_CORE`
- `POEDITOR_PROJECT_ID_CLIENT`
- `POEDITOR_PROJECT_ID_STYLIST`
- `POEDITOR_PROJECT_ID_PACKAGES`

(Or whatever subset of POEditor projects the product actually has — pass them in `scopes`.)

## See also

- [`technas-i18n` package source](https://github.com/Technas-Organization/technas-i18n-python) (Python CLI)
- [`I18N_WORKFLOW.md`](https://github.com/Technas-Organization/technas-workspace/blob/main/docs/I18N_WORKFLOW.md) — generic i18n workflow guide
- [`I18N_AI_RULES.md`](https://github.com/Technas-Organization/technas-workspace/blob/main/docs/I18N_AI_RULES.md) — anti-overwrite rules for AI assistants
