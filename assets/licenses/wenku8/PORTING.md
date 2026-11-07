# Wenku8 Flutter UI provenance

Source: https://github.com/mikufoxxx/Wenku8_Flutter
Revision: ebcd7f1891b54a92fc045c372974d70ec829f10a
Source revision date: 2026-11-03
Adapted for fqapp: 2026-11-05

The presentation code in `lib/widgets/wenku/` is extracted and adapted from
the upstream archive artwork/motion, glass surfaces, navigation headers,
search field, feature cards, glass dock, segmented controls, loading
skeletons, loaded-content reveal and book-collection layout. The search views in `lib/widgets/search/`
adapt the upstream search and book-collection presentation to fqapp media
items. `lib/pages/mine_page.dart` adapts the upstream `MyPage` layout.

The adaptations keep fqapp navigation, data models, search services, local
storage and accessibility preferences. No Wenku8 account, cloud sync,
repository, reader engine or network implementation is included. Original
application branding is not copied.

The misc feature pages port the upstream archive shell and chart vocabulary:
`reading_statistics_page.dart` (overview/rhythm/calendar/most-read sections
that fqapp's local read-time data can fill), `mine_summary.dart`,
`mine_heatmap.dart`, `mine_top_books.dart`, the offline cache list/empty
shells (`cached_books_page.dart`, `cached_dramas_page.dart`), the backup and
legacy-import shells (`library_backup_page.dart`,
`fanqie_history_import_page.dart`) and the about/licence shell
(`about_page.dart`). Upstream-only statistics dimensions, account, cloud and
update services are not synthesised.

The original upstream NOTICE, root LICENSE (GNU GPL version 2 text), and
assets/licenses/GPL-3.0.txt are retained verbatim in this directory. The
upstream NOTICE refers to both license texts. This notice neither resolves
that ambiguity nor changes the upstream license terms or copyrights.

`third_party/liquid_glass_easy/` is the upstream vendored Liquid Glass Easy
5.0.0, including Wenku8 patches. Copyright (c) 2025 Ahmed Gamil, MIT License.
Its original LICENSE and PATCHES.md remain with its runtime sources. The
app uses its real lens and scroll-edge rendering, not a painted imitation.

The public Wenku8 source snapshot is not independently buildable and omits
some referenced feature modules. Only available UI sources used by this
batch are ported; omitted modules are not replaced with fictitious features.
