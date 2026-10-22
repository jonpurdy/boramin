#include <stdint.h>
#include <stddef.h>
typedef struct MediaReader MediaReader;
typedef struct {
    void *context;
    int64_t size;
    int (*read)(void *context, int64_t offset, uint8_t *buffer, int count);
    int (*cancelled)(void *context);
} MediaIO;
typedef struct {
    int vp9, width, height, bit_depth, profile, primaries, transfer, matrix, full_range, level, chroma;
    double duration, frame_rate;
    uint8_t mastering[24], light[4];
    int has_mastering, has_light;
} MediaInfo;
// Parse only VP9's uncompressed keyframe header; never decode pixels.
// 1 = keyframe metadata, 0 = inter/show-existing frame, negative = malformed/truncated.
int media_vp9_header(const uint8_t *bytes, size_t count, MediaInfo *info);
MediaReader *media_open(const char *path, MediaInfo *info, char *error, size_t capacity);
MediaReader *media_open_io(MediaIO io, MediaInfo *info, char *error, size_t capacity);
void media_close(MediaReader *reader);
int media_seek(MediaReader *reader, double seconds);
// For a fresh probe reader only; changes its position. Returns a complete indexed
// keyframe list, or zero if unavailable. Index discovery reads at most 4 MiB.
// Pass NULL/0 to query count, then pass a buffer to copy the times in seconds.
int media_keyframes(MediaReader *reader, double *times, int capacity);
// 1 = packet, 0 = EOF, negative = error. Bytes valid until next call.
int media_packet(MediaReader *reader, const uint8_t **bytes, int *count, double *pts, double *duration, int *key);
// Decode the first audio track to a CAF timeline; synthesize silence for video-only files.
int media_audio(const char *input, const char *output, int (*cancel)(void *), void *context, char *error, size_t capacity);
typedef struct MediaPCMReader MediaPCMReader;
MediaPCMReader *media_pcm_open(MediaIO io, double duration, char *error, size_t capacity);
// Random-access stereo 48 kHz signed 16-bit PCM, on the original container timeline.
int media_pcm_read(MediaPCMReader *reader, int64_t first_frame, int frames, uint8_t *output);
void media_pcm_close(MediaPCMReader *reader);
int64_t media_caf_header(double duration, uint8_t *header);
