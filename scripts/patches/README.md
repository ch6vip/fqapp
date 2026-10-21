# Flutter Windows semantics backport

Flutter 3.44.6 can freeze its Windows accessibility tree after an OverlayPortal
anchor disappears during a route/tooltip transition. Subsequent native updates
can dereference an orphan parent and terminate the process. This was reproduced
in the packaged application with accessibility enabled.

`flutter-3.44.6-semantics.patch` backports the traversal lifecycle/serialization
fixes from Flutter's BSD-3-Clause source, adapted to the 3.44.6 method structure:

- <https://github.com/flutter/flutter/pull/193372>
- Source commit `c0c4d54eb50934aa3d97c5f25c7bbea5fe5d3a75`.
- The source also contains the preceding traversal-parent dirty notification
  fix associated with <https://github.com/flutter/flutter/issues/182444>.

This is optional. Normal builds and CI use an unmodified official SDK.
If the accessibility crash is reproduced, explicitly run
`scripts/prepare_flutter_windows.ps1 -FlutterRoot <dedicated SDK>` or pass
`-ApplySemanticsBackport` to the Windows build script. It checks the complete patch
before applying it, recognizes an already applied patch, and refuses a different
SDK. It does not disable accessibility. Use a dedicated project SDK because this
patch modifies that SDK's framework source. When upgrading Flutter, remove this
backport only after testing the official fix in the selected SDK.

`test/desktop_semantics_update_test.dart` retains the upstream semantics update
regression cases and BSD attribution. Flutter's license is included in the
portable application's `licenses` directory.

These framework-specific cases are opt-in so ordinary Android/Linux CI does not
require a Windows SDK patch. On the prepared SDK run:
`flutter test test/desktop_semantics_update_test.dart --no-pub --dart-define=FQAPP_FLUTTER_SEMANTICS_PATCH=true`.
The Windows build script enables them only with `-ApplySemanticsBackport`.
