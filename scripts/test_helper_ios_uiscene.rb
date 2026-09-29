# Test de TechnasIosHelper#technas_verifier_cycle_de_vie_scene! sans fastlane
# (macOS : plutil). Lancer : ruby scripts/test_helper_ios_uiscene.rb
#
# Fastlane est simulé au strict nécessaire (lane_context, UI, sh) : ce qu'on
# teste, c'est que la méthode trouve l'app DANS L'ARCHIVE et bloque la suite
# de la lane — donc l'upload TestFlight qui la suit — sur un binaire SDK 27 sans
# scène. Le script shell appelé est le vrai.
require 'fileutils'
require 'tmpdir'
require 'open3'

module Fastlane
  module Actions
    module SharedValues
      XCODEBUILD_ARCHIVE = :XCODEBUILD_ARCHIVE
    end

    def self.lane_context
      @lane_context ||= {}
    end
  end
end

module FastlaneCore
  class Interface
    class FastlaneError < StandardError; end
  end

  module UI
    def self.user_error!(message)
      raise FastlaneCore::Interface::FastlaneError, message
    end
  end
end

require_relative '../fastlane/TechnasIosHelper'

class Lane
  include TechnasIosHelper

  def sh(*args)
    _out, statut = Open3.capture2e(*args)
    raise "sh a échoué (#{statut.exitstatus}) : #{args.join(' ')}" unless statut.success?
  end
end

def archive(dossier, sdk:, scene:)
  app = File.join(dossier, 'Runner.xcarchive', 'Products', 'Applications', 'Runner.app')
  FileUtils.mkdir_p(app)
  plist = File.join(app, 'Info.plist')
  File.write(plist, <<~XML)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>DTSDKName</key><string>#{sdk}</string></dict></plist>
  XML
  if scene
    system('plutil', '-insert', 'UIApplicationSceneManifest', '-json',
           '{"UISceneConfigurations":{"UIWindowSceneSessionRoleApplication":[{"UISceneDelegateClassName":"FlutterSceneDelegate"}]}}',
           plist, exception: true)
  end
  system('plutil', '-convert', 'binary1', plist, exception: true)
  File.join(dossier, 'Runner.xcarchive')
end

echecs = 0
cas = lambda do |libelle, sdk:, scene:, bloque:, sans_archive: false|
  Dir.mktmpdir do |d|
    Fastlane::Actions.lane_context[Fastlane::Actions::SharedValues::XCODEBUILD_ARCHIVE] =
      sans_archive ? File.join(d, 'absente.xcarchive') : archive(d, sdk: sdk, scene: scene)
    begin
      Lane.new.technas_verifier_cycle_de_vie_scene!
      bloque_obtenu = false
    rescue FastlaneCore::Interface::FastlaneError
      bloque_obtenu = true
    end
    if bloque_obtenu == bloque
      puts "  ok  #{libelle}"
    else
      puts "  KO  #{libelle} : #{bloque_obtenu ? 'bloqué' : 'laissé passer'}"
      echecs += 1
    end
  end
end

cas.call('SDK 27 sans scène → la lane s\'arrête avant l\'upload', sdk: 'iphoneos27.0', scene: false, bloque: true)
cas.call('SDK 27 avec scène → continue', sdk: 'iphoneos27.0', scene: true, bloque: false)
cas.call('SDK 26.5 sans scène → continue (toléré)', sdk: 'iphoneos26.5', scene: false, bloque: false)
cas.call('archive introuvable → arrêt (rien ne prouve le binaire)', sdk: 'iphoneos27.0', scene: true, bloque: true, sans_archive: true)

# Et l'appel est bien SUR LE CHEMIN : après build_app, avant la sortie
# anticipée de build_only et avant upload_to_testflight. Une méthode correcte
# que personne n'appelle ne bloque rien.
source = File.read(File.expand_path('../fastlane/TechnasIosHelper.rb', __dir__), encoding: 'UTF-8')
corps = source[/def technas_release_ios\b.*?\n  ensure\n/m].to_s
code = corps.lines.reject { |l| l.strip.start_with?('#') }.join
i_build = code.index('build_app(')
i_ctrl = code.index('technas_verifier_cycle_de_vie_scene!')
i_skip = code.index('unless upload')
i_up = code.index('upload_to_testflight(')
if [i_build, i_ctrl, i_skip, i_up].all? && i_build < i_ctrl && i_ctrl < i_skip && i_ctrl < i_up
  puts '  ok  technas_release_ios contrôle l\'archive entre build_app et la publication'
else
  puts "  KO  technas_release_ios : contrôle absent ou mal placé (build=#{i_build.inspect} contrôle=#{i_ctrl.inspect} build_only=#{i_skip.inspect} upload=#{i_up.inspect})"
  echecs += 1
end

if echecs.positive?
  puts "KO — #{echecs} cas en échec"
  exit 1
end
puts 'OK — technas_verifier_cycle_de_vie_scene! : 4 cas + placement dans technas_release_ios'
