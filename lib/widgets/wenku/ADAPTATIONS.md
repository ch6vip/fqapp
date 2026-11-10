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
- `app_haptics.dart` maps the upstream cues to Flutter `HapticFeedback`, gated
  by fqapp's `HapticPreferences` (`haptics_enabled`, default on). On Android,
  both UI styles share Settings -> Appearance -> Haptic feedback. It also gates
  the activity decor view so implicit Material long presses respect the choice;
  system keyboard feedback is unchanged. The upstream settings service is not
  imported.
- `wenku_archive.dart` uses fqapp's existing
  `assets/images/app_logo.webp`.
- `WenkuPage` owns the page scaffold and overlays the upstream frosted header.
  The upstream `LibraryWorkspace`/reflow master-detail shell is outside this
  shared UI slice.
  fqapp supplies the default system-bar colors above the Navigator so pushed
  archive pages update with the theme; reader/video annotations retain priority.
- E-ink/high-contrast headers omit the transparent feather's height when using
  an opaque plate, so that plate cannot hide the first content row.
- `glass_controls.dart` carries upstream `AppGlassSlider` and
  `AppControls.toggle` / `slider` as `GlassControls`, plus the reader's compact
  `chip`. The reader and settings units originally vendored prefixed copies
  (`reader_glass_controls.dart`, `settings_glass_controls.dart`); this is the
  single shared copy. Archive surfaces use the `WenkuTonalColors` palette;
  reader surfaces pass their paper palette explicitly and opt into the
  plain-switch fallback. The retired optical reflection painter is still not
  carried. `wenku_segments.dart` carries `AppGlassSegments`,
  `GlassChoiceGroup`, the single shared `AppGlassSwitch` (with the settings
  line's `optimistic` / `semanticLabel` additions) and upstream
  `AppControls.segments` as `WenkuControls`; the shelf's
  `WenkuControls.toggle` is the archive-palette adapter over that switch.
- `setting_menu.dart` carries upstream `setting_menu.dart` as
  `GlassSettingMenu` (including fqapp's `valueLabel`). Its vendored
  `GlassMenuAnchor` / `showGlassMenu` / `GlassMenuItem` /
  `_GlassMenuPlacement` copies were removed; those classes come from the
  single `wenku_overlay.dart` implementation, which keeps the desktop focus
  ring, keyboard activation and traversal.
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
- `reading_charts.dart` carries upstream `reading_statistics_charts.dart`
  (`ReadingRhythmChart`) and `reading_statistics_shared_charts.dart`
  (`ReadingActivityRing`). The integration pass dropped the temporary `Misc`
  class prefix and the `misc_reading_charts.dart` filename.
- Search is a route, not the upstream in-shell overlay. `SearchRoute` keeps
  the upstream 420ms `ArchivePlaneTransition` diagonal entrance for the archive
  style; the classic style delegates to the platform `PageTransitionsTheme`
  builder and duration ([`SearchRoute.open`] resolves it at push time).
- Search covers continue to use fqapp's existing media/cover pipeline. The
  upstream `NovelCover` and `StoryCover` widgets are not part of this slice.

## Shelf port (U3–U6)

The shelf batch adds the following upstream files. Each file header records
its own mechanical substitutions; this list is the index.

- `wenku_overlay.dart` — upstream `app_ui.dart` `showJellySheet` /
  `showGlassMenu` / `GlassMenuAnchor` / `GlassMenuItem` /
  `GlassOverlaySurface` / `GlassMenuSource` / `GlassMenuSurface` and
  `confirmNovelAction` (as `confirmArchiveAction`). `GlassMenuItem` gains a
  fqapp desktop extension: `FocusableActionDetector` + Enter/Space
  activation + arrow-key traversal + a visible focus ring. The confirmation
  keeps the upstream jelly sheet but exposes `confirmKey`/`cancelKey` and a
  one-function seam back to `showDialog`. The same popup route now follows the
  live `AppUiScope`: archive keeps the glass/morph, classic uses a Material
  bottom panel, anchored menu and confirmation dialog, and the caller's content
  keeps one element (and State) across the style switch. Captured reader paper
  is preserved while only `AppStyleTokens` is refreshed from the live style.
- `src/glass_overlay_motion.dart` — upstream `motion_ui.dart` overlay
  transition (`GlassMenuStretch` / `GlassMenuContents` /
  `GlassOverlayTransition`).
- `src/glass_morph.dart` — upstream `glass_morph.dart`, renamed
  `WenkuGlassMorph` to avoid the page-level `GlassMorph` name.
- `archive_shelf.dart` — upstream `archive_wave.dart` `ArchiveFileCarousel`
  and its render objects. `Novel` + `LibraryState` are flattened into
  `ArchiveShelfEntry`; `NovelCover` becomes `ShelfCoverImage`; long-press
  recognisers live inside the volume so `ArchiveBoxDepthRender.hitTest`
  still sees the projected cap; edit mode adds `interactive`/`selecting`/
  `selected`.
- `src/archive_shelf_entry.dart` — fqapp row model for the carousel
  (identity, progress, source label, file code).
- `src/archive_shelf_geometry.dart`, `src/archive_scroll_simulation.dart`,
  `src/archive_shelf_loading.dart`, `src/archive_spine_title.dart` —
  verbatim/near-verbatim upstream helpers.
- `shelf_toolbar.dart` — upstream `library_toolbar.dart`,
  `book_collection_region_toolbar.dart` and the today-reading pill.
  `NativeGlassGroup` maps to the vendored `LiquidGlassBatch`; the compact
  main-page scope is a constant false; `ShelfToolbar.leading` hosts fqapp's
  today-reading pill.
- `shelf_options_sheet.dart` — upstream `book_collection_view_options.dart`
  and `book_grid_density_controls.dart`. The follow-collection toggle is
  intentionally absent (decisions #9); `ShelfViewTarget` is the fqapp
  three-target enum.
- `book_source_badge.dart` — upstream `book_source_badge.dart`.
- `../shelf/shelf_cover_image.dart` — fqapp's single `PosterCache` cover
  pipeline (file/svg/e-ink), replacing upstream `NovelCover`.
- `../shelf/shelf_performance_scope.dart` — merges the persisted 立体书架
  switch with e-ink and reduced-motion signals inside the page body.
- `../shelf/book_collection_tiles.dart` — upstream `NovelRow`,
  `BookGridTile`, `BookGridFailure` and the archive selection mark.
  `Novel` becomes `MediaItem`; `NovelCover` becomes `ShelfCoverImage`;
  `ArchiveDesign.fileCode` uses fqapp's FQ-/SQ- convention.
- `../shelf/shelf_collection_view.dart` — upstream
  `BookCollectionView.builder` composition with a region toolbar and an
  optional carousel as leading slivers; an empty collection renders a plain
  `CustomScrollView` because the shared builder asserts
  `itemCount >= leadingCount + trailingCount`.
- `../shelf/shelf_groups_sheet.dart` — upstream `book_categories.dart`.
  `LocalLibraryPreferences` becomes `ShelfGroupStore`; `showJellySheet` /
  `confirmNovelAction` become `showJellySheet` / `confirmArchiveAction`;
  a not-ready store renders a read-only notice (never writes a fallback
  category back to disk).

The shelf page itself (`lib/pages/library_page*.dart`) keeps fqapp's
three-tab data model, edit/undo, history confirmation, direct-read routing,
offline cache, update detection, local import, pull-to-refresh, edit-mode
back interception and hidden-tab retention. Its visual grammar is the
upstream archive page: `WenkuPage`/`WenkuScope`, `ArchiveMasthead`,
`WenkuControls.segments`, `ShelfToolbar`, `ArchiveFileCarousel`,
`ShelfNovelRow`/`ShelfBookGridTile`, `showJellySheet`, `GlassMenuAnchor` and
`confirmArchiveAction`.

MuMu follow-up: the three-tab edit bar connects `chooseShelfCategory` to
`ShelfGroupStore.assignKeys` using source-qualified content keys. Cancelling
keeps the selection and assignments unchanged. Author-work entries carry the
profile name, and detail-page shelf writes retain resolved metadata without
replacing the entry's identity or source. The short-drama cache page groups its
bulk actions in a shared glass menu instead of crowding the route title; action
availability and destructive confirmation are unchanged.

