# Third-party licences and acknowledgements

BoraMin uses the following third-party software. All three app targets include
this directory as a folder resource (`Licences` on iOS/tvOS and
`Contents/Resources/Licences` on macOS). The licence texts and upstream notices
are reproduced unchanged; this index identifies their components and sources.
Settings → Licences displays `ACKNOWLEDGEMENTS.txt` followed by the full `.txt`
notices, grouping identical texts under their component names. Keep the
acknowledgements and this index synchronized when updating dependency sources.

| Component | Version / source | Licence files |
| --- | --- | --- |
| AetherEngine | [814fef14d394c13c378869dc5c13963af8be9a0d](https://github.com/superuser404notfound/AetherEngine/tree/814fef14d394c13c378869dc5c13963af8be9a0d) | [LGPL v3 with Apple Store / DRM exception](AetherEngine-LICENSE.txt), [incorporated GPL v3](GPL-3.0.txt) |
| FFmpeg, private BoraMinMedia framework | [8.0.1](https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz) | [LGPL 2.1](FFmpeg-LICENSE.txt) |
| FFmpegBuild, including its FFmpeg build | [3.9.0](https://github.com/superuser404notfound/FFmpegBuild/tree/3b398c8f6340fe5fb4a7cb9a2a211a16677171e0), FFmpeg n8.1.3 with upstream build-package patches | [LGPL 2.1](FFmpegBuild-LICENSE.txt) |
| dav1d, via FFmpegBuild | [1.5.4](https://code.videolan.org/videolan/dav1d/-/tree/1.5.4) | [BSD-2-Clause](dav1d.BSD-2-Clause.txt) |
| zimg, via FFmpegBuild | [3.0.6](https://github.com/sekrit-twc/zimg/tree/release-3.0.6) | [WTFPL](zimg.WTFPL.txt) |
| libzvbi, via FFmpegBuild | [0.2.45](https://github.com/zapping-vbi/zvbi/tree/v0.2.45), modified by FFmpegBuild | [LGPL 2.1](libzvbi-LGPL-2.1.txt), [MIT notice for ure.c/ure.h](libzvbi-ure.MIT.txt) |
| AMSMB2 | [4.0.3 / 1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0](https://github.com/amosavian/AMSMB2/tree/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0) | [Upstream repository licence](AMSMB2-LICENSE.txt), [source copyright notices](SMB-source-notices.txt) |
| libsmb2 | [aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03](https://github.com/sahlberg/libsmb2/tree/aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03) | [Component licensing notice](libsmb2-COPYING.txt), [LGPL 2.1](libsmb2-LGPL-2.1.txt), [source copyright notices](SMB-source-notices.txt) |
| LibDovi packaging | [2.1.0](https://github.com/superuser404notfound/LibDovi/tree/0d7cce1d6836a30d13a3a2326e50a153af53f014) | [MIT](LibDovi-LICENSE.txt) |
| dolby_vision / libdovi, via LibDovi | [dovi_tool](https://github.com/quietvoid/dovi_tool), as packaged by LibDovi 2.1.0 | [MIT option](dolby_vision-LICENSE.txt) |
| SwiftAssRenderer | [1.3.1](https://github.com/mihai8804858/swift-ass-renderer/tree/28919f6b5ddd896d327b0283f8d97624902236e6) | [MIT](SwiftAssRenderer-LICENSE.txt) |
| SwiftLibass | [1.4.0](https://github.com/mihai8804858/swift-libass/tree/6513c488e377a26c06db327fb2acfc2653a041d5) | [MIT](SwiftLibass-LICENSE.txt) |
| libass | [0.17.3](https://github.com/libass/libass/tree/0.17.3) | [ISC](libass-COPYING.txt) |
| FreeType | [2.13.2](https://github.com/freetype/freetype/tree/VER-2-13-2) | [FreeType License option](FreeType-FTL.txt) |
| HarfBuzz | [8.5.0](https://github.com/harfbuzz/harfbuzz/tree/8.5.0) | [Old MIT](HarfBuzz-COPYING.txt) |
| FriBidi | [1.0.14](https://github.com/fribidi/fribidi/tree/v1.0.14) | [LGPL 2.1](FriBidi-COPYING.txt) |
| Fontconfig | [2.15.0](https://github.com/fontconfig/fontconfig/tree/2.15.0) | [Upstream permissive notices](Fontconfig-COPYING.txt) |
| libpng | [1.6.43](https://github.com/pnggroup/libpng/tree/v1.6.43) | [PNG licence](libpng-LICENSE.txt) |
| CombineSchedulers | [1.2.2](https://github.com/pointfreeco/combine-schedulers/tree/114354e8c1667a2edc4993700fb9fa4f90157b56) | [MIT](CombineSchedulers-LICENSE.txt) |
| ConcurrencyExtras | [1.4.3](https://github.com/pointfreeco/swift-concurrency-extras/tree/8a4260f7373493435bd21194585c95b72bfdd401) | [MIT](ConcurrencyExtras-LICENSE.txt) |
| IssueReporting / XCTestDynamicOverlay | [1.13.1](https://github.com/pointfreeco/xctest-dynamic-overlay/tree/d9308ad679143c26a30dec52daefe82f54af2b82) | [MIT](XCTestDynamicOverlay-LICENSE.txt) |

## Acknowledgements

This software uses code of [FFmpeg](https://ffmpeg.org), licensed under the
GNU Lesser General Public License version 2.1 or later. Its corresponding
upstream sources are linked above. The private FFmpeg configuration is recorded
in BoraMin's `tools/build_ffmpeg.py`; FFmpegBuild's exact patches and build
instructions are in its pinned repository.

Portions of this software are copyright © 2006 The FreeType Project
(https://www.freetype.org). All rights reserved.

AMSMB2's repository licence is retained verbatim. Its Swift source headers also
identify Mousavian's code as MIT-licensed; the original copyright statements
are reproduced in `SMB-source-notices.txt`. libsmb2's client library uses LGPL;
the separate BSD licence mentioned in its `COPYING` notice applies to examples.

FFmpegBuild removes libzvbi's GPL-only files and supplies LGPL stubs. Its FFmpeg
and libzvbi modifications are documented in the pinned package's `build.sh`.
The `ure.c` notice supplied by that package refers to 0.2.44; it is preserved
verbatim as supplied with the 0.2.45 binary build.

## Maintenance and distribution

- Licence copies originate from `vendor/AetherEngine`, `vendor/AMSMB2`,
  `vendor/FFmpeg-LICENSE.txt`, `vendor/Subtitle-notices`, and the pinned
  FFmpegBuild package's `LICENSES` directory. `GPL-3.0.txt` is the official text
  from https://www.gnu.org/licenses/gpl-3.0.txt.
- Update this inventory and the copied texts whenever a dependency changes.
  Exact SwiftPM revisions are recorded in
  `BoraMin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- Preserve the vendored library changes and build instructions described in
  `vendor/DEPENDENCIES.md` and `vendor/AetherEngine/README.md` when preparing
  corresponding-source and relinking materials for a release.
- These notices do not replace LGPL corresponding-source or relinking
  obligations. This directory is a collection of notices, not a source offer
  or a relinking kit. AetherEngine's App Store exception applies to that
  component; it does not grant an exception for every dependency.
