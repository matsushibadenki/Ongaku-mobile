# Shared by standalone effect audits. These do not use Xcode/SwiftPM's native
# source registration, so explicitly link the same prototype AU as the apps.
prepare_spectral_transient_audit() {
 local spectral_audit_dir="$1"
 local spectral_file
 local spectral_desktop_root="${ONGAKU_DESKTOP_ROOT:-../Ongaku-desktop}"
 if [[ -d "$spectral_desktop_root/Sources/OngakuAudioDSP" ]]; then
  for spectral_file in SpectralTransientDSP.hpp SpectralTransientAudioUnit.mm; do
   cmp "audio/$spectral_file" "$spectral_desktop_root/Sources/OngakuAudioDSP/$spectral_file"
  done
  cmp audio/SpectralTransientAudioUnit.h "$spectral_desktop_root/Sources/OngakuAudioDSP/include/SpectralTransientAudioUnit.h"
  cmp audio/effects/SpectralTransientAudioEffect.swift "$spectral_desktop_root/Sources/OngakuDesktop/SpectralTransientAudioEffect.swift"
 fi
 xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -c audio/SpectralTransientAudioUnit.mm -o "$spectral_audit_dir/SpectralTransient.o"
 spectral_native_flags=(-import-objc-header "$PWD/audio/OngakuAudio-Bridging-Header.h" "$spectral_audit_dir/SpectralTransient.o" -Xlinker -lc++)
}
