# Arch runtime and redistribution contract (experimental)

The complete bundle stays in `/usr/lib/fqapp` with `$ORIGIN/lib` on the
executable and `$ORIGIN` on bundled libraries. The launcher only execs that
absolute binary, forwarding arguments. No installation hooks, sudo launcher,
profile rewrites, keyring changes or data deletion are included.

- ELF: GTK3/GLib, Pango/Cairo/gdk-pixbuf/ATK, HarfBuzz, zlib, fontconfig,
  libsecret, epoxy/GL/EGL/X11 and glibc/libgcc/libstdc++. The native speech
  bridge directly links libspeechd.so.2 (`libspeechd`). `elf-report.txt` checks
  every ELF's architecture, loader paths and ldd closure; missing libraries fail.
- dlopen: media_kit uses system libmpv, supplied by Arch **mpv**. Codecs,
  TLS and audio/display libraries follow the system package dependency closure.
- CLI: locked path_provider_linux → xdg_directories invokes `xdg-user-dir`
  during Documents lookup at startup. **xdg-user-dirs** is required;
  xdg-utils alone does not supply this helper.
- Session: encrypted storage requires an available, unlocked
  `org.freedesktop.secrets` provider and D-Bus session. Choose your desktop's
  provider; the package never forces GNOME or changes a user's keyring.
  URL opening uses xdg-utils; portals need the backend matching your desktop.
- Speech: libspeechd is a hard library dependency. For audible system speech,
  run/configure Speech Dispatcher and a voice backend (e.g. espeak-ng) in your
  own session. The app does not start or reconfigure the daemon. Missing daemon
  remains an explicit speech error. A dependency list cannot prove voice quality.
- No account/WebKit or Java feature is added. The locked optional JNI plugin
  builds libdartjni only if a JDK is discoverable; packaging rejects that
  accidental build input. The packaging toolchain disables optional JNI discovery.

Licenses carried: root GPL text, generated Flutter asset NOTICES.Z,
Flutter engine notices from the exact SDK, bundled fonts' OFL and asset notices.
The source archive carries tracked third_party and native notices plus both
lockfiles. `license-inventory.txt` lists available source notices. System mpv,
FFmpeg, GTK and speech packages retain Arch's corresponding source/notices.
The simple book SVG is covered by the repository license. Existing third-party
images/animations still require a rights audit; root GPL does not confer those
rights. These artifacts are experimental evidence, not redistribution approval,
an AUR submission or a formal Release. Preserve source and build manifest.

Official references (verify current package metadata when updating the snapshot):
- https://docs.flutter.dev/platform-integration/linux/building
- https://man.archlinux.org/man/PKGBUILD.5.en
- https://archlinux.org/packages/extra/x86_64/mpv/
- https://archlinux.org/packages/extra/x86_64/xdg-user-dirs/
- https://archlinux.org/packages/extra/x86_64/libspeechd/
