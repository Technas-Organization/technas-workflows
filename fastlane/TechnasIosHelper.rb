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
require 'openssl'

module TechnasIosHelper
  def technas_update_version
    version = sh("cd ../.. && sh get_flutter_version.sh").strip.split('+')
    plist_path = "Runner/Info.plist"
    sh "cd .. && plutil -replace CFBundleShortVersionString -string '#{version[0]}' #{plist_path}"
    sh "cd .. && plutil -replace CFBundleVersion -string '#{version[1].strip}' #{plist_path}"
    sh('cd .. && /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Runner/Info.plist')
    sh('cd .. && /usr/libexec/PlistBuddy -c "Print CFBundleVersion" Runner/Info.plist')
  end

  def technas_release_ios(app_identifier:, app_name: 'App', match_readonly: true, skip_waiting: true)
    technas_update_version
    setup_ci(force: true)

    api_key = app_store_connect_api_key(
      key_id: ENV["APP_STORE_API_KEY_ID"],
      issuer_id: ENV["APP_STORE_ISSUER_ID"],
      key_filepath: ENV["APP_STORE_KEY_FILEPATH"],
      duration: 1200,
      in_house: false
    )

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
    match(
      type: "appstore",
      readonly: force_refresh ? false : match_readonly,
      force: force_refresh,
      force_for_new_devices: force_refresh,
      api_key: api_key,
      git_url: ENV["MATCH_GIT_URL"],
      app_identifier: [app_identifier].flatten
    )

    team_id = ENV["sigh_#{app_identifier}_appstore_team-id"]
    keychain_path = "#{ENV['HOME']}/Library/Keychains/fastlane_tmp_keychain-db"

    sh("security list-keychains -d user -s '#{keychain_path}'")
    sh("security default-keychain -s '#{keychain_path}'")

    profile_path = ENV["sigh_#{app_identifier}_appstore_profile-path"]
    profile_name = ENV["sigh_#{app_identifier}_appstore_profile-name"]

    if profile_path
      update_project_provisioning(
        xcodeproj: "Runner.xcodeproj",
        profile: profile_path,
        target_filter: "Runner",
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
        targets: ["Runner"]
      )
    end

    build_app(
      workspace: "Runner.xcworkspace",
      scheme: "Runner",
      export_method: "app-store",
      disable_xcpretty: true,
      xcargs: "DEVELOPMENT_TEAM=#{team_id} OTHER_CODE_SIGN_FLAGS='--keychain #{keychain_path}'"
    )

    upload_to_testflight(
      api_key: api_key,
      skip_waiting_for_build_processing: skip_waiting,
      notify_external_testers: false,
      beta_app_review_info: {
        contact_email: (ENV["APP_STORE_CONTACT_EMAIL"].to_s.strip.empty? ? "contact@technas.fr" : ENV["APP_STORE_CONTACT_EMAIL"].to_s.strip),
        contact_first_name: (ENV["APP_STORE_CONTACT_FIRST_NAME"].to_s.strip.empty? ? app_name : ENV["APP_STORE_CONTACT_FIRST_NAME"].to_s.strip),
        contact_last_name: (ENV["APP_STORE_CONTACT_LAST_NAME"].to_s.strip.empty? ? "Team" : ENV["APP_STORE_CONTACT_LAST_NAME"].to_s.strip),
        contact_phone: (ENV["APP_STORE_CONTACT_PHONE"].to_s.strip.empty? ? "+33 603740256" : ENV["APP_STORE_CONTACT_PHONE"].to_s.strip),
        notes: (ENV["APP_STORE_REVIEW_NOTES"].to_s.strip.empty? ? "Build automatique pour #{app_name}" : ENV["APP_STORE_REVIEW_NOTES"].to_s.strip)
      },
      team_id: ENV["APP_STORE_TEAM_ID"]
    )
  end
end
