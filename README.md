# technas-workflows

Reusable GitHub Actions workflows shared across all Technas products (BeautyGo, Éclat d'Or, Rede, FarmCover, FleetPro, WashPro, OilDispatching, GMFitness, …).

This repo holds the **shared CI definitions and their build assets**. Each product repo references the workflows from its own `.github/workflows/` via `uses:` and stays a thin caller.

## Repository layout

```
.github/workflows/    reusable workflows (on: workflow_call)
  i18n-{check,pull,push}.yml      — translation sync (POEditor ↔ repo)
  deploy-flutter-web.yml          — Flutter web → BuildKit image → k8s rollout
  flutter-apk-smoke.yml           — debug APK build (per-push smoke test)
  deploy-flutter-android.yml      — signed AAB → Google Play
  deploy-flutter-ios.yml          — iOS → TestFlight (Match)
docker/mobile/Dockerfile          — single-source Flutter+JDK+AndroidSDK+Ruby builder image
fastlane/                         — single-source Fastlane helpers
  TechnasAndroidHelper.rb         — Play Store auth + upload + APK distribute
  TechnasIosHelper.rb             — Match signing + build + TestFlight upload
scripts/check_aab_16kb_alignment.sh — Play Store 16 KB ELF-alignment guard
```

### How the Flutter app workflows reuse these assets

The native/web workflows do **not** require apps to vendor a `Dockerfile`, the
Fastlane helpers, or the alignment script. Each reusable job checks out **two**
repos onto the runner:

1. the **caller** app at the workspace root (so `app_dir` like `flutter_app/` resolves), and
2. **technas-workflows** under `.technas-workflows/` for the shared Dockerfile / helpers / scripts.

The Android + iOS jobs export the shared Fastlane dir to the per-app `Fastfile`
via the **`TECHNAS_FASTLANE_HELPERS`** env var. A per-app `Fastfile` therefore
loads the helper with:

```ruby
helper = ENV['TECHNAS_FASTLANE_HELPERS'] ||
         File.expand_path('../../../.github-org/fastlane', __dir__) # legacy fallback
require File.join(helper, 'TechnasAndroidHelper')   # or TechnasIosHelper
```

The app keeps only the bits that are genuinely app-specific:

- Android: `android/fastlane/{Appfile,Fastfile}`, `android/Gemfile`, and the
  `android/app/build.gradle.kts` signing config that loads `key.properties`
  (the workflow writes `key.properties` + the keystore from secrets at runtime).
- iOS: `ios/fastlane/{Appfile,Fastfile,Matchfile}`, `ios/Gemfile`, and
  `get_flutter_version.sh` at the app root.

## Flutter app workflows

### `deploy-flutter-web.yml`

Builds `flutter build web --release --pwa-strategy none` on `build_runner`, wraps
`build/web` in `<app_dir>/<dockerfile>`, pushes to `docker.technas.fr`
(provenance/sbom **off** — Nexus mirror corrupts attestation blobs), then rolls
out the k8s Deployment on `rollout_runner`.

```yaml
# <app>/.github/workflows/deploy-app-web.yml
name: Deploy App Web
on:
  push: { branches: [main], paths: ['flutter_app/**','packages/**','k8s-deployments/<app>-web/**','.github/workflows/deploy-app-web.yml'] }
  workflow_dispatch: {}
permissions: { contents: read, packages: write }
jobs:
  web:
    uses: Technas-Organization/technas-workflows/.github/workflows/deploy-flutter-web.yml@main
    with:
      app_dir: flutter_app
      image_name: docker.technas.fr/technas/<app>-web
      k8s_namespace: technas-choir
      k8s_deployment: <app>-web
      dart_defines: "TENANT=<tenant>,API_BASE_URL=https://api-<app>.technas.fr"
      # build_runner/rollout_runner default to "technas-backend-build" / "technas-web-build".
      manifest_paths: k8s-deployments/<app>-web/<app>-web.yaml
      pre_build_script: "dart run tool/generate_version.dart || true"
    secrets: inherit
```

Inputs: `app_dir`, `image_name`, `k8s_namespace`, `k8s_deployment`, `dart_defines`,
`build_runner`, `rollout_runner` (all per the task) + `dockerfile`, `manifest_paths`,
`registry`, `flutter_version`, `flutter_channel`, `pre_build_script`, `env_copy_from`,
`submodules`, `rollout_timeout`.
Secrets (caller passes via `secrets: inherit`): `TECHNAS_REGISTRY_USER`/`TECHNAS_REGISTRY_PASSWORD`
**or** `DOCKER_REGISTRY_USER`/`DOCKER_REGISTRY_PASSWORD`, optional `PACKAGES_PAT`.

> `build_runner`/`rollout_runner`/`android_runner`/`macos_runner` are passed to
> `fromJSON`, so the value must be **valid JSON**: a quoted single label
> (`'"technas-backend-build"'`) **or** a JSON array
> (`'["self-hosted","Linux","X64","technas-android-build"]'`). The defaults already
> cover the standard runners, so most callers never set these.

### `flutter-apk-smoke.yml`

Builds a **debug** APK inside the shared mobile image on the Android runner — a
cheap per-push guard that an Android build still compiles.

```yaml
jobs:
  smoke:
    uses: Technas-Organization/technas-workflows/.github/workflows/flutter-apk-smoke.yml@main
    with:
      app_dir: flutter_app
      app_id: fr.technas.<app>
      dart_defines: "TENANT=<tenant>"
    secrets: inherit
```

Inputs: `app_dir`, `app_id`, `dart_defines` (+ `env_copy_from`, `android_runner`, `submodules`, `workflows_ref`).
Secrets: optional `PACKAGES_PAT`.

### `deploy-flutter-android.yml`

Signs + builds the AAB inside the shared mobile image, runs the 16 KB alignment
guard, then uploads to Google Play via the shared Fastlane helper.

```yaml
jobs:
  android:
    uses: Technas-Organization/technas-workflows/.github/workflows/deploy-flutter-android.yml@main
    with:
      app_dir: flutter_app
      app_id: fr.technas.<app>
      track: internal
      dart_defines: "TENANT=<tenant>"
    secrets: inherit
```

Inputs: `app_dir`, `app_id`, `track`, `dart_defines` (+ `env_copy_from`, `skip_play_store`,
`check_16kb_alignment`, `android_runner`, `submodules`, `workflows_ref`).
Required secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_PASSWORD`, `ANDROID_KEY_ALIAS`. The Google Play upload also needs
`PLAY_STORE_JSON_KEY` (or `PLAY_STORE_JSON_KEY_OVERRIDE`, which wins — see below)
unless `skip_play_store: true`. Optional `PACKAGES_PAT`.

> **Multi-variant apps** (one repo shipping a second app with its own Play
> listing — e.g. BeautyGo client + partenaire) call this reusable once per
> variant. The second variant **cannot** use `secrets: inherit` (it must route a
> *different* Play key), so it passes an explicit `secrets:` map with the four
> `ANDROID_*` secrets + `PLAY_STORE_JSON_KEY_OVERRIDE: ${{ secrets.<ITS_KEY> }}`
> (the override wins over `PLAY_STORE_JSON_KEY`). `env_copy_from` copies a file
> (relative to `app_dir`) to `<app_dir>/.env` before the build — needed when the
> app declares `.env` as a pubspec asset (e.g. `env_copy_from: config/env.mobile`).

### `deploy-flutter-ios.yml`

Builds + uploads to TestFlight via Fastlane Match on the macOS runner.

```yaml
jobs:
  ios:
    uses: Technas-Organization/technas-workflows/.github/workflows/deploy-flutter-ios.yml@main
    with:
      app_dir: flutter_app
      app_id: fr.technas.<app>
    secrets: inherit
```

Inputs: `app_dir`, `app_id`, `track` (unused — TestFlight only), `fastlane_lane`,
`env_copy_from`, `match_force_refresh` (+ `macos_runner`, `submodules`, `workflows_ref`).
Required secrets: `AUTH_KEY_CONTENT`, `APP_STORE_CONNECT_API_KEY_CONTENT_BASE64`,
`APP_STORE_API_KEY_ID`, `APP_STORE_ISSUER_ID`, `APP_STORE_TEAM_ID`, `MATCH_PASSWORD`;
optional `MATCH_GIT_URL[_GITHUB]`, `MATCH_GIT_BASIC_AUTHORIZATION[_GITHUB]`,
`APP_STORE_CONTACT_*`, `APP_STORE_REVIEW_NOTES`, `PACKAGES_PAT`.

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
