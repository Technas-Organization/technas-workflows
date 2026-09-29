#!/usr/bin/env bash
# Tests de check_ios_uiscene.sh (macOS : plutil). Lancer : bash scripts/test_check_ios_uiscene.sh
#
# Chaque cas fabrique un Info.plist minimal et vérifie le CODE DE SORTIE — pas
# une sous-chaîne du message : une garde qui imprime « OK » en sortant 0 sur un
# binaire fautif serait verte ici sinon.
set -uo pipefail

ICI="$(cd "$(dirname "$0")" && pwd)"
GARDE="$ICI/check_ios_uiscene.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echecs=0

plist() { # $1 = fichier, $2 = DTSDKName ('' = absent), $3 = avec_scene|sans_scene, $4 = xml|binary1
  local f="$1"
  cat > "$f" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fr.test.app</string>
</dict></plist>
EOF
  [ -n "$2" ] && plutil -insert DTSDKName -string "$2" "$f"
  if [ "$3" = avec_scene ]; then
    plutil -insert UIApplicationSceneManifest -json \
      '{"UIApplicationSupportsMultipleScenes":false,"UISceneConfigurations":{"UIWindowSceneSessionRoleApplication":[{"UISceneClassName":"UIWindowScene","UISceneDelegateClassName":"FlutterSceneDelegate","UISceneConfigurationName":"flutter"}]}}' "$f"
  fi
  [ "${4:-xml}" = binary1 ] && plutil -convert binary1 "$f"
  return 0
}

attendu() { # $1 = libellé, $2 = code attendu, $3… = commande
  local libelle="$1" code="$2"; shift 2
  "$@" > "$TMP/out" 2>&1
  local rc=$?
  if [ "$rc" = "$code" ]; then
    echo "  ok  $libelle (rc=$rc)"
  else
    echo "  KO  $libelle : rc=$rc, attendu $code"; sed 's/^/        /' "$TMP/out"
    echecs=$((echecs + 1))
  fi
}

plist "$TMP/a.plist" iphoneos27.0 sans_scene binary1
attendu "SDK 27 (DTSDKName, plist binaire) sans manifeste → échec" 1 bash "$GARDE" "$TMP/a.plist"

plist "$TMP/b.plist" iphoneos27.0 avec_scene binary1
attendu "SDK 27 avec manifeste → succès" 0 bash "$GARDE" "$TMP/b.plist"

plist "$TMP/c.plist" iphoneos26.5 sans_scene
attendu "SDK 26.5 sans manifeste → toléré (avertissement)" 0 bash "$GARDE" "$TMP/c.plist"

plist "$TMP/d.plist" '' sans_scene
attendu "Info.plist des SOURCES + SDK 27.0 passé en argument → échec" 1 bash "$GARDE" "$TMP/d.plist" 27.0

plist "$TMP/e.plist" '' avec_scene
attendu "Info.plist des sources avec manifeste + SDK 28.1 → succès" 0 bash "$GARDE" "$TMP/e.plist" 28.1

plist "$TMP/f.plist" iphonesimulator27.0 sans_scene
attendu "build simulateur SDK 27 sans manifeste → échec" 1 bash "$GARDE" "$TMP/f.plist"

plist "$TMP/g.plist" '' sans_scene
attendu "SDK illisible → erreur d'entrée (2), jamais un succès" 2 bash "$GARDE" "$TMP/g.plist"

attendu "Info.plist inexistant → erreur d'entrée (2)" 2 bash "$GARDE" "$TMP/absent.plist"

if [ "$echecs" -gt 0 ]; then
  echo "KO — $echecs cas en échec"
  exit 1
fi
echo "OK — check_ios_uiscene.sh : 8 cas"
