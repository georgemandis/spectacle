// Core Audio Taps IO proc helper — implemented in C because Core Audio's
// real-time audio thread requires C-compatible function pointers.
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

// Callback type that Zig code will set
typedef void (*SpectacleAudioCallback)(
    const float *data,
    uint32_t frame_count,
    uint32_t channels,
    uint32_t sample_rate,
    uint64_t timestamp_ns
);

static SpectacleAudioCallback g_callback = NULL;
static uint32_t g_sample_rate = 48000;
static uint32_t g_channels = 2;

void spectacle_tap_set_callback(SpectacleAudioCallback cb, uint32_t sample_rate, uint32_t channels) {
    g_callback = cb;
    g_sample_rate = sample_rate;
    g_channels = channels;
}

static OSStatus tapIOProc(
    AudioObjectID           inDevice,
    const AudioTimeStamp   *inNow,
    const AudioBufferList  *inInputData,
    const AudioTimeStamp   *inInputTime,
    AudioBufferList        *outOutputData,
    const AudioTimeStamp   *inOutputTime,
    void                   *inClientData
) {
    (void)inDevice; (void)inNow; (void)outOutputData; (void)inOutputTime; (void)inClientData;

    if (!g_callback) return 0;
    if (inInputData->mNumberBuffers == 0) return 0;

    const AudioBuffer *buf = &inInputData->mBuffers[0];
    if (!buf->mData || buf->mDataByteSize == 0) return 0;

    uint32_t channels = g_channels;
    uint32_t frame_count = buf->mDataByteSize / (sizeof(float) * channels);
    if (frame_count == 0) return 0;

    uint64_t timestamp_ns = (uint64_t)(inInputTime->mSampleTime * 1000000000.0 / (double)g_sample_rate);

    g_callback((const float *)buf->mData, frame_count, channels, g_sample_rate, timestamp_ns);
    return 0;
}

// Returns the C function pointer for use with AudioDeviceCreateIOProcID
AudioDeviceIOProc spectacle_tap_get_io_proc(void) {
    return tapIOProc;
}
