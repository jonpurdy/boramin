# Dependencies

- AMSMB2 4.0.3, commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`, from https://github.com/amosavian/AMSMB2.
- libsmb2 submodule commit `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03` from https://github.com/sahlberg/libsmb2.
- FFmpeg 8.0.1 from https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz, SHA-256 `05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41`.

AMSMB2 and libsmb2 source and notices are vendored. Both AMSMB2 manifests (Package.swift and Package@swift-6.0.swift) use a static library and omit upstream test targets and their otherwise-unused swift-atomics dependency. The application builds offline after generating FFmpeg libraries.

FFmpeg is built without GPL/nonfree components, video software decoders, network protocols, programs or encoders. It supplies container demuxing and audio decoding/resampling. VP9 video is decoded only by VideoToolbox. FFmpeg LGPL 2.1 text is in FFmpeg-LICENSE.txt; AMSMB2/libsmb2 notices remain in their source trees. Build objects and scripts are retained for relinking. Preserve applicable library notices and relinking/source requirements when distributing binaries.
