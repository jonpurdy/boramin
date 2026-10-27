# Dependencies

- AMSMB2 4.0.3, commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`, from https://github.com/amosavian/AMSMB2.
- libsmb2 submodule commit `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03` from https://github.com/sahlberg/libsmb2.
- FFmpeg 8.0.1 from https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz, SHA-256 `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41`.

AMSMB2 and libsmb2 source and notices are vendored. Both AMSMB2 manifests (Package.swift and Package@swift-6.0.swift) use a static library and omit upstream test targets and their otherwise-unused swift-atomics dependency. The original playback dependencies build offline after generating FFmpeg libraries; the experimental AetherEngine package additionally requires initial SwiftPM dependency resolution.

FFmpeg is built without GPL/nonfree components, video software decoders, network protocols, programs or encoders. It supplies container demuxing and audio decoding/resampling. VP9 video is decoded only by VideoToolbox. FFmpeg LGPL 2.1 text is in FFmpeg-LICENSE.txt; AMSMB2/libsmb2 notices remain in their source trees. Build objects and scripts are retained for relinking. Preserve applicable library notices and relinking/source requirements when distributing binaries.


- AetherEngine experimental native MKV backend: pinned source revision and local compiler compatibility changes in [AetherEngine/README.md](AetherEngine/README.md). LGPL v3 with Apple Store / DRM exception; full source and notices retained. Its SwiftPM dependencies include FFmpegBuild 3.9.0 (FFmpeg 8.1.3 plus its documented codecs/patches) and LibDovi 2.1.0. Exact revisions are in `BoraMin.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; corresponding build/patch source is available from those pinned upstream repositories. The legacy FFmpeg remains isolated in the private BoraMinMedia framework. Aether dependency notices are bundled under Notices and AetherEngine-LICENSE.txt.

- Styled ASS/SSA subtitles: SwiftAssRenderer 1.3.1 and SwiftLibass 1.4.0, with exact source revisions in Package.resolved. BoraMin uses the public libass C API for incremental events and track ownership, plus SwiftAssRenderer's bitmap blending pipeline. The high-level whole-script renderer is not used. Bundled component notices are in `Subtitle-notices/`; libass 0.17.3, FreeType 2.13.2, HarfBuzz 8.5.0, FriBidi 1.0.14, Fontconfig 2.15.0 and libpng 1.6.43 are supplied by SwiftLibass. These notices and upstream source/relinking materials must be retained when distributing. No libVLC/VLCKit dependency was added.
