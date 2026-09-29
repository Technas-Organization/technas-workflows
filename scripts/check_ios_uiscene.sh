#!/usr/bin/env bash
# Un binaire iOS compilé avec le SDK iOS 27 (ou plus) DOIT déclarer le cycle
# de vie UIScene — sinon UIKit le tue au lancement sur iOS 27.
#
# 🔴 28/09/2026 — Apple refuse BeautyGo 1.7.105 et BeautyGo Pro 1.7.84 :
# « The app crashed on launch » (test automatique sur le dernier iOS). Le Mac
# de CI (Mac-Mini-Builder) compile en Xcode 27 / SDK iOS 27 depuis le 15/09 ;
# les deux Info.plist n'avaient pas de `UIApplicationSceneManifest`. Sur iOS 27,
# UIKit s'arrête dans `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`
# (EXC_BREAKPOINT, « UIScene life cycle is required for apps built with this
# SDK ») avant la moindre ligne de Dart. Flutter l'annonçait à chaque build
# (« UIScene lifecycle support will soon be required ») et le build passait au
# vert : aucune étape ne transformait cet avertissement en échec.
#
# Usage :
#   check_ios_uiscene.sh <Info.plist> [version du SDK]
#
# - <Info.plist> : celui de l'app ARCHIVÉE (…/Products/Applications/X.app/Info.plist,
#   binaire ou XML) ou celui des sources (ios/Runner/Info.plist).
# - [version du SDK] : ex. 27.0. Absente, elle est lue dans `DTSDKName`
#   (`iphoneos27.0`), que Xcode écrit dans le plist de l'app compilée.
#
# Code de sortie : 0 si conforme (ou SDK < 27), 1 si le manifeste manque avec
# un SDK >= 27, 2 si l'entrée est illisible.
set -euo pipefail

PLIST="${1:-}"
SDK="${2:-}"
SEUIL=27

if [ -z "$PLIST" ] || [ ! -f "$PLIST" ]; then
  echo "::error::check_ios_uiscene : Info.plist introuvable : '${PLIST}'"
  exit 2
fi

if [ -z "$SDK" ]; then
  NOM_SDK="$(plutil -extract DTSDKName raw -o - "$PLIST" 2>/dev/null || true)"
  SDK="${NOM_SDK#iphoneos}"
  SDK="${SDK#iphonesimulator}"
fi
MAJEURE="${SDK%%.*}"
if ! [[ "$MAJEURE" =~ ^[0-9]+$ ]]; then
  echo "::error::check_ios_uiscene : version du SDK illisible ('${SDK}') pour ${PLIST}"
  exit 2
fi

if plutil -extract UIApplicationSceneManifest json -o /dev/null "$PLIST" >/dev/null 2>&1; then
  DELEGUE="$(plutil -extract UIApplicationSceneManifest.UISceneConfigurations.UIWindowSceneSessionRoleApplication.0.UISceneDelegateClassName raw -o - "$PLIST" 2>/dev/null || echo '?')"
  echo "check_ios_uiscene : OK — SDK ${SDK}, UIApplicationSceneManifest présent (délégué : ${DELEGUE}) — ${PLIST}"
  exit 0
fi

if [ "$MAJEURE" -ge "$SEUIL" ]; then
  echo "::error::SDK iOS ${SDK} sans UIApplicationSceneManifest dans ${PLIST}"
  echo "Cette app sera TUÉE au lancement sur iOS ${SEUIL}+ (UIKit : « UIScene life cycle is"
  echo "required for apps built with this SDK ») — refus Apple assuré, et crash chez tout"
  echo "utilisateur en iOS ${SEUIL}. Adopter UIScene : Info.plist UIApplicationSceneManifest +"
  echo "FlutterSceneDelegate (https://docs.flutter.dev/release/breaking-changes/uiscenedelegate)."
  exit 1
fi

echo "::warning::SDK iOS ${SDK} sans UIApplicationSceneManifest (${PLIST}) — toléré sous iOS ${SEUIL}, mais l'app ne démarrera plus dès qu'elle sera compilée avec le SDK ${SEUIL}."
exit 0
