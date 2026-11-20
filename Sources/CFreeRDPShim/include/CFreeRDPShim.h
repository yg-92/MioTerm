#ifndef C_FREERDP_SHIM_H
#define C_FREERDP_SHIM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MioRdpSession MioRdpSession;

typedef struct {
    const char* host;
    uint16_t port;
    const char* username;
    const char* password;
    const char* domain;
    const char* shared_dir;
    uint32_t width;
    uint32_t height;
} MioRdpConfig;

typedef struct {
    void (*on_connected)(void* userdata, int32_t width, int32_t height);
    void (*on_frame)(void* userdata, const uint8_t* bgra, int32_t width, int32_t height, int32_t stride);
    void (*on_error)(void* userdata, const char* message);
    void (*on_disconnected)(void* userdata);
} MioRdpCallbacks;

bool mio_freerdp_is_available(void);
const char* mio_freerdp_library_path(void);

MioRdpSession* mio_rdp_create(const MioRdpConfig* config, MioRdpCallbacks callbacks, void* userdata);
bool mio_rdp_connect(MioRdpSession* session);
/// Returns 1 on success, 0 on disconnect/shutdown, -1 on error.
int mio_rdp_poll(MioRdpSession* session, uint32_t timeout_ms);
void mio_rdp_disconnect(MioRdpSession* session);
void mio_rdp_destroy(MioRdpSession* session);

void mio_rdp_send_mouse(MioRdpSession* session, uint16_t flags, uint16_t x, uint16_t y);
void mio_rdp_send_key(MioRdpSession* session, bool down, uint32_t rdp_scancode);
void mio_rdp_send_unicode(MioRdpSession* session, bool down, uint16_t code);

#ifdef __cplusplus
}
#endif

#endif
