BoraMin styled subtitles dependencies

SwiftAssRenderer 1.3.1: https://github.com/mihai8804858/swift-ass-renderer
SwiftLibass 1.4.0: https://github.com/mihai8804858/swift-libass
Exact package revisions, including CombineSchedulers/ConcurrencyExtras/IssueReporting,
are pinned in BoraMin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved.

SwiftLibass supplies libass 0.17.3, FreeType 2.13.2, HarfBuzz 8.5.0,
FriBidi 1.0.14, Fontconfig 2.15.0 and libpng 1.6.43.
Corresponding notices are included in this folder.

Upstream component sources:
https://github.com/libass/libass/tree/0.17.3
https://github.com/freetype/freetype/tree/VER-2-13-2
https://github.com/harfbuzz/harfbuzz/tree/8.5.0
https://github.com/fribidi/fribidi/tree/v1.0.14
https://github.com/fontconfig/fontconfig/tree/2.15.0
https://github.com/pnggroup/libpng/tree/v1.6.43

BoraMin uses libass's public incremental Matroska-event API and SwiftAssRenderer's
bitmap pipeline. No external player UI source was copied. No libVLC is linked.
