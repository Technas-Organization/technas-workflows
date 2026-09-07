# Shared iOS Fastlane helper for ALL Technas Flutter apps.
#
# Single source of truth — hosted in Technas-Organization/technas-workflows and
# checked out next to the caller app by the reusable deploy-flutter-ios.yml
# workflow, which exports its directory as TECHNAS_FASTLANE_HELPERS.
#
# Per-app Fastfile loads it like this (no vendored copy needed):
#
#   helper = ENV['TECHNAS_FASTLANE_HELPERS']
#   require File.join(helper, 'TechnasIosHelper')
#   # ... then inside a lane:
#   extend TechnasIosHelper
#   technas_release_ios(app_identifier: 'fr.technas.xxx', app_name: 'MyApp')
#
# Assumes the app keeps `get_flutter_version.sh` at the Flutter app root (one dir
# above ios/) — used by technas_update_version to stamp the build number.

require 'base64'
require 'json'
require 'openssl'

module TechnasIosHelper
  def technas_update_version(extra_plists: [])
    version = sh("cd ../.. && sh get_flutter_version.sh").strip.split('+')
    # Build number = minutes since 2020-01-01 UTC. Strictly monotonic across
    # every CI run, so no human ever has to bump the pubspec `+build` again —
    # fixes TestFlight "bundle version must be higher than the previously
    # uploaded version". Kept < Android's 2.1e9 versionCode cap on purpose so
    # the Android reusable reuses the exact same scheme (--build-number).
    build_number = ((Time.now.to_i - 1_577_836_800) / 60).to_s
    # App extensions (extra_plists) MUST carry the same CFBundleShortVersionString
    # and CFBundleVersion as the containing app or App Store validation rejects
    # the build (e.g. the ImageNotification notification-service extension).
    (["Runner/Info.plist"] + extra_plists).each do |plist_path|
      sh "cd .. && plutil -replace CFBundleShortVersionString -string '#{version[0]}' #{plist_path}"
      sh "cd .. && plutil -replace CFBundleVersion -string '#{build_number}' #{plist_path}"
      sh(%(cd .. && /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" #{plist_path}))
      sh(%(cd .. && /usr/libexec/PlistBuddy -c "Print CFBundleVersion" #{plist_path}))
    end
  end

  # Clé App Store Connect — construite à l'IDENTIQUE par toutes les lanes qui
  # parlent à Apple (release, build_only, development). Extraite ici à la 2e
  # utilisation : dupliquer les 5 ENV c'est se garantir qu'un jour l'une des
  # copies aura un nom de variable en retard sur l'autre.
  def technas_cle_app_store_connect
    app_store_connect_api_key(
      key_id: ENV["APP_STORE_API_KEY_ID"],
      issuer_id: ENV["APP_STORE_ISSUER_ID"],
      key_filepath: ENV["APP_STORE_KEY_FILEPATH"],
      duration: 1200,
      in_house: false
    )
  end

  # Appareils de test d'un produit, lus depuis <app>/ios/fastlane/appareils_de_test.json
  # ({"iPhone de X": "<UDID>"}). Le fichier est VERSIONNÉ : ajouter un iPhone
  # est un commit, pas une manipulation manuelle dans le portail Apple qu'aucune
  # trace ne rattrape. Absent ou vide => aucun enregistrement, pas une erreur
  # (les produits mono-machine n'en ont pas besoin).
  def technas_appareils_de_test
    # Une lane s'exécute avec Dir.pwd = <app>/ios/fastlane (c'est pourquoi le
    # reste du helper fait `cd ..`). Le fichier est donc à côté du Fastfile.
    chemin = File.join(Dir.pwd, 'appareils_de_test.json')
    return {} unless File.exist?(chemin)

    appareils = JSON.parse(File.read(chemin))
    appareils.each do |nom, udid|
      # Un UDID mal formé est refusé par Apple avec un message qui ne désigne
      # PAS le fichier fautif. On échoue ici, en nommant l'entrée.
      next if udid =~ /\A[0-9A-Fa-f]{40}\z/ || udid =~ /\A[0-9]{8}-[0-9A-Fa-f]{16}\z/

      FastlaneCore::UI.user_error!("appareils_de_test.json : UDID invalide pour « #{nom} » (#{udid}). " \
                                   "Attendu 40 hexa (avant iPhone XS) ou 8 chiffres + '-' + 16 hexa.")
    end
    appareils
  end

  # Profils de DÉVELOPPEMENT — le chemin `flutter run` sur un iPhone PHYSIQUE.
  #
  # 🔴 Pourquoi une lane séparée et pas une option de `release` : les deux ne
  # signent pas la même chose. `release` produit un profil `appstore`, qui ne
  # contient AUCUN appareil et ne peut donc pas lancer l'app sur un iPhone
  # branché — c'est exactement ce qui manquait le 07/09/2026 (identité de
  # développement présente, 0 profil installé). Un profil `development` porte
  # la liste des appareils enregistrés ; il faut donc enregistrer AVANT de
  # (re)générer, et `force_for_new_devices` sans `register_devices` régénère un
  # profil identique, sans le nouvel iPhone.
  #
  # Aucun build ici : la lane fabrique et publie des profils dans le dépôt
  # Match, puis les installe sur la machine qui l'exécute. Elle est faite pour
  # tourner sur le Mac auquel l'iPhone est appairé.
  def technas_development_profiles(app_identifier:, extensions: [], readonly: false,
                                   cabler_le_projet: false)
    setup_ci(force: true) unless ENV["TECHNAS_MATCH_LOCAL"].to_s.downcase == "true"

    api_key = technas_cle_app_store_connect
    appareils = technas_appareils_de_test

    # readonly: aucune écriture chez Apple ni dans le dépôt Match — on ne fait
    # qu'installer les profils existants. C'est le mode d'un poste qui veut
    # juste lancer l'app ; l'enregistrement d'appareil n'y a pas sa place.
    register_devices(devices: appareils, api_key: api_key) if !readonly && !appareils.empty?

    match(
      type: "development",
      readonly: readonly,
      force_for_new_devices: !readonly,
      api_key: api_key,
      git_url: ENV["MATCH_GIT_URL"],
      app_identifier: ([app_identifier] + extensions.map { |e| e[:identifier] }).flatten
    )

    technas_cabler_signature_debug(app_identifier: app_identifier, extensions: extensions) if cabler_le_projet
  end

  # Écrit la signature MANUELLE de la configuration Debug sur les profils Match.
  #
  # 🔴 07/09/2026 — SANS ÇA, INSTALLER LES PROFILS NE SUFFIT PAS, ET LE MESSAGE
  # D'ERREUR DÉSIGNE LA MAUVAISE CAUSE.
  #
  # Le projet est en `CODE_SIGN_STYLE = Automatic`. Xcode y choisit alors
  # **l'identité la plus récente du chemin de trousseaux** et la confronte au
  # profil QU'IL gère lui-même — lequel porte l'ancien certificat :
  #
  #   Provisioning profile "iOS Team Provisioning Profile: …" doesn't include
  #   signing certificate "Apple Development: Created via API (…)".
  #
  # Autrement dit : plus le certificat Match est correctement installé, plus la
  # signature automatique casse. Les deux rails ne cohabitent pas.
  #
  # Laisser Xcode gagner n'est pas une option sur un Mac piloté en SSH : la clé
  # privée de SON certificat vit dans `login.keychain`, que la session SSH ne
  # peut ni ouvrir ni faire déverrouiller (aucune invite ne peut s'afficher).
  # `codesign` échoue en « Command CodeSign failed », sans jamais nommer le
  # trousseau. Le seul chemin qui tienne est donc : certificat Match dans un
  # trousseau à soi, déverrouillé, ET signature manuelle sur SES profils.
  #
  # Debug seulement : la configuration Release reste au rail `appstore` de
  # `technas_release_ios`, qui la réécrit à chaque build de toute façon.
  def technas_cabler_signature_debug(app_identifier:, extensions: [])
    ([{ identifier: app_identifier, target: "Runner" }] + extensions).each do |cible|
      update_code_signing_settings(
        path: "Runner.xcodeproj",
        targets: [cible[:target]],
        build_configurations: ["Debug"],
        use_automatic_signing: false,
        team_id: ENV["APP_STORE_TEAM_ID"],
        code_sign_identity: "Apple Development",
        profile_name: "match Development #{cible[:identifier]}"
      )
    end
  end

  # extensions: optional list of embedded app-extension targets, e.g.
  #   [{ identifier: 'fr.technas.beautygo.app.ImageNotification', target: 'ImageNotification' }]
  # Each gets: version stamped in <target>/Info.plist, its own Match appstore
  # profile fetched + wired on its Xcode target, and an explicit entry in the
  # export provisioningProfiles mapping. Default [] keeps single-target apps
  # (éclat, …) on the exact previous behaviour.
  # upload: false construit et signe SANS publier sur TestFlight — sert aux
  # vérifications de chaîne CI (lane `build_only`) qui ne doivent rien diffuser
  # aux testeurs. Défaut true : comportement inchangé pour tous les produits.
  def technas_release_ios(app_identifier:, app_name: 'App', match_readonly: true, skip_waiting: true, extensions: [], upload: true)
    technas_update_version(extra_plists: extensions.map { |e| "#{e[:target]}/Info.plist" })
    setup_ci(force: true)

    api_key = technas_cle_app_store_connect

    # clean install REQUIS : les runners Mac sont PARTAGÉS entre produits
    # (BeautyGo, éclat…). Réutiliser un Pods/ chaud y mélange les pods d'un autre
    # produit (vu : flutter_facebook_auth + Flutter.xcframework 3.16.1 périmé
    # tirés dans le link éclat → ARCHIVE FAILED). Le clean garantit un état pods
    # propre par build. (Tenté de l'enlever pour le cache 2026-06-02 → cassé le
    # build, re-mis. Le vrai cache Android/iOS passe par une isolation
    # per-produit du DerivedData/Pods, pas par la suppression du clean.)
    cocoapods(clean_install: true, podfile: "./Podfile")

    # MATCH_FORCE_REFRESH=true bypasses readonly + forces Match to re-sync the
    # App ID capabilities with what is in Runner.entitlements, regenerating the
    # provisioning profile and pushing it back to the match repo. Use this once
    # whenever an entitlement is added/removed in Xcode (e.g. Associated
    # Domains for Universal Links) — leave it off in steady state to avoid
    # rotating profiles on every release.
    force_refresh = ENV["MATCH_FORCE_REFRESH"].to_s.downcase == "true"
    all_identifiers = ([app_identifier] + extensions.map { |e| e[:identifier] }).flatten
    match(
      type: "appstore",
      readonly: force_refresh ? false : match_readonly,
      force: force_refresh,
      force_for_new_devices: force_refresh,
      api_key: api_key,
      git_url: ENV["MATCH_GIT_URL"],
      app_identifier: all_identifiers
    )

    team_id = ENV["sigh_#{app_identifier}_appstore_team-id"]
    keychain_path = "#{ENV['HOME']}/Library/Keychains/fastlane_tmp_keychain-db"

    sh("security list-keychains -d user -s '#{keychain_path}'")
    sh("security default-keychain -s '#{keychain_path}'")

    signable_targets = [{ identifier: app_identifier, target: "Runner" }] + extensions
    export_profiles = {}
    signable_targets.each do |t|
      profile_path = ENV["sigh_#{t[:identifier]}_appstore_profile-path"]
      profile_name = ENV["sigh_#{t[:identifier]}_appstore_profile-name"]

      if profile_path
        update_project_provisioning(
          xcodeproj: "Runner.xcodeproj",
          profile: profile_path,
          target_filter: t[:target],
          build_configuration: "Release"
        )
      end

      if profile_name
        update_code_signing_settings(
          use_automatic_signing: false,
          path: "Runner.xcodeproj",
          team_id: team_id,
          profile_name: profile_name,
          code_sign_identity: "Apple Distribution",
          targets: [t[:target]]
        )
        export_profiles[t[:identifier]] = profile_name
      end
    end

    build_options = {
      workspace: "Runner.xcworkspace",
      scheme: "Runner",
      export_method: "app-store",
      disable_xcpretty: true,
      xcargs: "DEVELOPMENT_TEAM=#{team_id} OTHER_CODE_SIGN_FLAGS='--keychain #{keychain_path}'"
    }
    # Explicit mapping: with an embedded extension, gym's auto-detection must
    # not guess — each bundle id exports with its own Match appstore profile.
    build_options[:export_options] = { provisioningProfiles: export_profiles } unless export_profiles.empty?
    build_app(**build_options)

    unless upload
      # `FastlaneCore::UI` qualifié, jamais `UI` nu : la constante est résolue
      # lexicalement en `TechnasIosHelper::UI` → NameError. Même piège que dans
      # TechnasAndroidHelper, où il est documenté depuis longtemps.
      FastlaneCore::UI.important("upload: false — build signé, publication TestFlight sautée.")
      return
    end

    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: skip_waiting,
      notify_external_testers: false,
      beta_app_review_info: {
        contact_email: (ENV["APP_STORE_CONTACT_EMAIL"].to_s.strip.empty? ? "contact@technas.fr" : ENV["APP_STORE_CONTACT_EMAIL"].to_s.strip),
        contact_first_name: (ENV["APP_STORE_CONTACT_FIRST_NAME"].to_s.strip.empty? ? app_name : ENV["APP_STORE_CONTACT_FIRST_NAME"].to_s.strip),
        contact_last_name: (ENV["APP_STORE_CONTACT_LAST_NAME"].to_s.strip.empty? ? "Team" : ENV["APP_STORE_CONTACT_LAST_NAME"].to_s.strip),
        contact_phone: (ENV["APP_STORE_CONTACT_PHONE"].to_s.strip.empty? ? "+33 422490105" : ENV["APP_STORE_CONTACT_PHONE"].to_s.strip),
        notes: (ENV["APP_STORE_REVIEW_NOTES"].to_s.strip.empty? ? "Build automatique pour #{app_name}" : ENV["APP_STORE_REVIEW_NOTES"].to_s.strip)
      },
      team_id: ENV["APP_STORE_TEAM_ID"]
    )
  end
end
