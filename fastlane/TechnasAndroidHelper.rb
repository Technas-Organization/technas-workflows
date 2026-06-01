# Shared Android Fastlane helper for ALL Technas Flutter apps.
#
# Single source of truth — hosted in Technas-Organization/technas-workflows and
# checked out next to the caller app by the reusable deploy-flutter-android.yml
# workflow, which exports its directory as TECHNAS_FASTLANE_HELPERS.
#
# Per-app Fastfile loads it like this (no vendored copy needed):
#
#   helper = ENV['TECHNAS_FASTLANE_HELPERS']
#   require File.join(helper, 'TechnasAndroidHelper')
#   # ... then inside a lane:
#   extend TechnasAndroidHelper
#   technas_deploy_android(package_name: 'fr.technas.xxx', track: 'internal')

require 'json'
require 'base64'
require 'fastlane_core'

# `UI` est une CONSTANTE résolue lexicalement : dans une méthode définie sous
# `module TechnasAndroidHelper`, `UI` est cherché en `TechnasAndroidHelper::UI`
# (puis top-level) — et `::UI` n'est pas garanti défini ici → NameError
# "uninitialized constant TechnasAndroidHelper::UI". On qualifie donc en
# `FastlaneCore::UI` (la vraie classe, toujours dispo via fastlane_core).
module TechnasAndroidHelper
  def process_json_key(env_var_name, output_file = 'play_config.json')
    content = ENV[env_var_name]
    FastlaneCore::UI.user_error!("Environment variable #{env_var_name} is not set!") if content.to_s.empty?

    3.times do |i|
      begin
        JSON.parse(content)
        FastlaneCore::UI.message("Valid JSON found after #{i} decode(s)")
        File.write(output_file, content)
        return File.expand_path(output_file)
      rescue JSON::ParserError
        begin
          content = Base64.decode64(content)
        rescue => e
          FastlaneCore::UI.user_error!("Failed to decode #{env_var_name}: #{e.message}")
        end
      end
    end

    FastlaneCore::UI.user_error!("Could not extract valid JSON from #{env_var_name} after multiple decodes")
  end

  def technas_deploy_android(package_name:, track: 'internal', aab_path: '../build/app/outputs/bundle/release/app-release.aab')
    json_key_path = process_json_key('PLAY_STORE_JSON_KEY')
    upload_to_play_store(
      package_name: package_name,
      track: track,
      aab: aab_path,
      skip_upload_apk: true,
      json_key: json_key_path,
      skip_upload_metadata: true,
      skip_upload_images: true,
      skip_upload_screenshots: true
    )
  end

  def technas_distribute_apk(apk_path:)
    FastlaneCore::UI.user_error!("APK path not provided") unless apk_path
    FastlaneCore::UI.user_error!("UPLOADS_SECRET_AUTH_TOKEN not set") unless ENV['UPLOADS_SECRET_AUTH_TOKEN']

    command = "curl --http1.1 -X POST '#{ENV['APP_DISTRIBUTION_URL']}/api/upload' \
      -H 'X-Auth-Token: #{ENV['UPLOADS_SECRET_AUTH_TOKEN']}' \
      -F 'app_file=@#{apk_path}' \
      -F 'platform=android'"
    sh(command)
    FastlaneCore::UI.success("Upload successful!")
  end
end
