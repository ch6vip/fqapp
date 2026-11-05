# Wenku8 UI adaptation notes

Source: `mikufoxxx/Wenku8_Flutter`, commit
`ebcd7f1891b54a92fc045c372974d70ec829f10a`.

The following source files are copied or closely adapted into `src/`:

- `archive_motion.dart`
- `archive_icons.dart`
- `archive_icon_art.dart`
- `archive_icon_fold_art.dart`
- `archive_icon_motion.dart`
- `easy_glass.dart`
- `glass_optics.dart` (the current renderer's refractive-index constant only)
- `dock_layout.dart`
- `performance_preferences.dart`

Non-identical mechanical substitutions:

- `NativeBackdrop` / `NativeGlassGroup` are replaced by the vendored
  `liquid_glass_easy` shader lens, its batch widget, and
  `LiquidGlassScrollEdgeGroup`. No Wenku Android method channel is referenced.
- `scroll_edge_blur.dart` is not imported. `FrostedHeader` drives the package's
  live scroll-edge blur directly while retaining the upstream black shade
  gradient and plateau.
- `app_text.dart` returns Chinese input unchanged; the upstream locale lookup,
  OpenCC conversion, and language persistence are intentionally absent.
- `app_haptics.dart` maps the upstream cues to Flutter `HapticFeedback`; the
  upstream persisted haptics settings service is intentionally absent.
- `wenku_archive.dart` uses fqapp's existing
  `assets/images/app_logo.webp`.
- `WenkuPage` owns the page scaffold and overlays the upstream frosted header.
  The upstream `LibraryWorkspace`/reflow master-detail shell is outside this
  shared UI slice.
- E-ink/high-contrast headers omit the transparent feather's height when using
  an opaque plate, so that plate cannot hide the first content row.
- Toggle/slider adapters and the retired optical reflection painter are not
  carried into this batch. `wenku_segments.dart` carries `AppGlassSegments`,
  `GlassChoiceGroup` and upstream `AppControls.segments` as `WenkuControls`.
- `glass_dock.dart` is upstream `glass_dock.dart` with `NovelMotion` renamed to
  `WenkuMotion`. `lib/widgets/shell_dock.dart` hosts it with upstream's
  `DockUnderlay` geometry; the bottom blur uses the vendored scroll-edge pass
  in place of `NativeBackdrop`. Over the short-drama video feed and on OLED
  black it uses the upstream lightweight (non-refractive) plate.
- `wenku_loading.dart` (`loading_ui.dart`), `wenku_reveal.dart`
  (`LoadedContentSequence`/`LoadedContentItem`/`RevealFromTop` from
  `motion_ui.dart`) and `book_collection_layout.dart`
  (`book_collection_layout.dart`, `book_collection_mode.dart`,
  `book_grid_density.dart`) are ported with their file headers listing each
  substitution. The collection takes an item builder instead of `Novel`.
- Search is a route, not the upstream in-shell overlay. `SearchRoute` keeps
  the upstream 420ms `ArchivePlaneTransition` diagonal entrance.
- Search covers continue to use fqapp's existing media/cover pipeline. The
  upstream `NovelCover` and `StoryCover` widgets are not part of this slice.
