#include "CFreeRDPShim.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// FreeRDP 3.x ABI offsets (verified on arm64 macOS FreeRDP 3.33.1)
#define RDP_CONTEXT_SIZE 1024
#define RDP_CONTEXT_LAST_ERROR_OFFSET 24
#define RDP_CONTEXT_GDI_OFFSET 264
#define RDP_CONTEXT_INPUT_OFFSET 304
#define RDP_CONTEXT_UPDATE_OFFSET 312
#define RDP_CONTEXT_SETTINGS_OFFSET 320

#define RDP_INST_CONTEXT_OFFSET 0
#define RDP_INST_CONTEXT_SIZE_OFFSET 256
#define RDP_INST_PRE_CONNECT_OFFSET 384
#define RDP_INST_POST_CONNECT_OFFSET 392
#define RDP_INST_POST_DISCONNECT_OFFSET 440
#define RDP_INST_VERIFY_CERT_EX_OFFSET 528
#define RDP_INST_VERIFY_CHANGED_CERT_EX_OFFSET 536

#define RDP_UPDATE_BEGIN_PAINT_OFFSET 72
#define RDP_UPDATE_END_PAINT_OFFSET 80
#define RDP_UPDATE_DESKTOP_RESIZE_OFFSET 104

#define RDP_GDI_WIDTH_OFFSET 8
#define RDP_GDI_HEIGHT_OFFSET 12
#define RDP_GDI_STRIDE_OFFSET 16
#define RDP_GDI_PRIMARY_BUFFER_OFFSET 64

#define MIO_PIXEL_FORMAT_BGRX32 0x20040888u

typedef int RdpBool;
typedef uint32_t RdpUInt32;
typedef int32_t RdpInt32;

typedef struct {
    bool initialized;
    bool available;
    char library_path[512];
    void* winpr_handle;
    void* freerdp_handle;

    void* (*freerdp_new)(void);
    void (*freerdp_free)(void* instance);
    RdpBool (*freerdp_context_new)(void* instance);
    void (*freerdp_context_free)(void* instance);
    RdpBool (*freerdp_connect)(void* instance);
    RdpBool (*freerdp_disconnect)(void* instance);
    RdpBool (*freerdp_shall_disconnect_context)(void* context);
    RdpUInt32 (*freerdp_get_event_handles)(void* context, void** events, RdpUInt32 count);
    RdpBool (*freerdp_check_event_handles)(void* context);
    RdpUInt32 (*freerdp_get_last_error)(void* context);
    const char* (*freerdp_get_last_error_string)(RdpUInt32 code);

    ssize_t (*freerdp_settings_get_key_for_name)(const char* value);
    RdpBool (*freerdp_settings_set_string)(void* settings, size_t id, const char* val);
    RdpBool (*freerdp_settings_set_uint32)(void* settings, size_t id, RdpUInt32 val);
    RdpBool (*freerdp_settings_set_bool)(void* settings, size_t id, RdpBool val);

    RdpBool (*gdi_init)(void* instance, RdpUInt32 format);
    void (*gdi_free)(void* instance);

    RdpBool (*input_send_mouse_event)(void* input, uint16_t flags, uint16_t x, uint16_t y);
    RdpBool (*input_send_keyboard_event_ex)(void* input, RdpBool down, RdpBool repeat, RdpUInt32 rdp_scancode);
    RdpBool (*input_send_unicode_keyboard_event)(void* input, uint16_t flags, uint16_t code);

    RdpUInt32 (*wait_for_multiple_objects)(RdpUInt32 count, const void** handles, RdpBool wait_all, RdpUInt32 ms);
} FreeRDPFunctions;

static pthread_mutex_t g_loader_mutex = PTHREAD_MUTEX_INITIALIZER;
static FreeRDPFunctions g_fn = {0};

static inline void* ptr_at(void* base, size_t offset) {
    return *(void**)((char*)base + offset);
}

static inline void set_ptr_at(void* base, size_t offset, void* value) {
    *(void**)((char*)base + offset) = value;
}

static inline void set_size_at(void* base, size_t offset, size_t value) {
    *(size_t*)((char*)base + offset) = value;
}

static inline int32_t i32_at(void* base, size_t offset) {
    return *(int32_t*)((char*)base + offset);
}

static inline uint32_t u32_at(void* base, size_t offset) {
    return *(uint32_t*)((char*)base + offset);
}

static bool try_load_from_dir(const char* dir) {
    char winpr_path[512];
    char freerdp_path[512];
    snprintf(winpr_path, sizeof(winpr_path), "%s/libwinpr3.dylib", dir);
    snprintf(freerdp_path, sizeof(freerdp_path), "%s/libfreerdp3.dylib", dir);

    void* winpr = dlopen(winpr_path, RTLD_LAZY | RTLD_LOCAL);
    if (!winpr) return false;

    void* freerdp = dlopen(freerdp_path, RTLD_LAZY | RTLD_LOCAL);
    if (!freerdp) {
        dlclose(winpr);
        return false;
    }

    #define LOAD_SYM(handle, field, name) \
        g_fn.field = dlsym(handle, name); \
        if (!g_fn.field) { dlclose(freerdp); dlclose(winpr); memset(&g_fn, 0, sizeof(g_fn)); return false; }

    LOAD_SYM(freerdp, freerdp_new, "freerdp_new");
    LOAD_SYM(freerdp, freerdp_free, "freerdp_free");
    LOAD_SYM(freerdp, freerdp_context_new, "freerdp_context_new");
    LOAD_SYM(freerdp, freerdp_context_free, "freerdp_context_free");
    LOAD_SYM(freerdp, freerdp_connect, "freerdp_connect");
    LOAD_SYM(freerdp, freerdp_disconnect, "freerdp_disconnect");
    LOAD_SYM(freerdp, freerdp_shall_disconnect_context, "freerdp_shall_disconnect_context");
    LOAD_SYM(freerdp, freerdp_get_event_handles, "freerdp_get_event_handles");
    LOAD_SYM(freerdp, freerdp_check_event_handles, "freerdp_check_event_handles");
    LOAD_SYM(freerdp, freerdp_get_last_error, "freerdp_get_last_error");
    LOAD_SYM(freerdp, freerdp_get_last_error_string, "freerdp_get_last_error_string");

    LOAD_SYM(freerdp, freerdp_settings_get_key_for_name, "freerdp_settings_get_key_for_name");
    LOAD_SYM(freerdp, freerdp_settings_set_string, "freerdp_settings_set_string");
    LOAD_SYM(freerdp, freerdp_settings_set_uint32, "freerdp_settings_set_uint32");
    LOAD_SYM(freerdp, freerdp_settings_set_bool, "freerdp_settings_set_bool");

    LOAD_SYM(freerdp, gdi_init, "gdi_init");
    LOAD_SYM(freerdp, gdi_free, "gdi_free");

    LOAD_SYM(freerdp, input_send_mouse_event, "freerdp_input_send_mouse_event");
    LOAD_SYM(freerdp, input_send_keyboard_event_ex, "freerdp_input_send_keyboard_event_ex");
    LOAD_SYM(freerdp, input_send_unicode_keyboard_event, "freerdp_input_send_unicode_keyboard_event");

    LOAD_SYM(winpr, wait_for_multiple_objects, "WaitForMultipleObjects");
    #undef LOAD_SYM

    g_fn.winpr_handle = winpr;
    g_fn.freerdp_handle = freerdp;
    snprintf(g_fn.library_path, sizeof(g_fn.library_path), "%s", freerdp_path);
    return true;
}

static void ensure_loaded(void) {
    pthread_mutex_lock(&g_loader_mutex);
    if (!g_fn.initialized) {
        const char* dirs[] = {
            "/opt/homebrew/opt/freerdp/lib",
            "/opt/homebrew/lib",
            "/usr/local/opt/freerdp/lib",
            "/usr/local/lib"
        };
        bool ok = false;
        for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
            if (try_load_from_dir(dirs[i])) {
                ok = true;
                break;
            }
        }
        g_fn.initialized = true;
        g_fn.available = ok;
    }
    pthread_mutex_unlock(&g_loader_mutex);
}

bool mio_freerdp_is_available(void) {
    ensure_loaded();
    return g_fn.available;
}

const char* mio_freerdp_library_path(void) {
    ensure_loaded();
    return g_fn.available ? g_fn.library_path : NULL;
}

struct MioRdpSession {
    void* instance;
    void* context;
    MioRdpCallbacks callbacks;
    void* userdata;
    bool gdi_initialized;
    bool connected;
};

static MioRdpSession* session_from_context(void* context) {
    if (!context) return NULL;
    return (MioRdpSession*)ptr_at(context, RDP_CONTEXT_SIZE);
}

static RdpBool cb_pre_connect(void* instance) {
    (void)instance;
    return 1;
}

static RdpBool cb_begin_paint(void* context) {
    (void)context;
    return 1;
}

static RdpBool cb_end_paint(void* context) {
    MioRdpSession* session = session_from_context(context);
    if (!session || !session->callbacks.on_frame) return 1;
    void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
    if (!gdi) return 1;
    int32_t width = i32_at(gdi, RDP_GDI_WIDTH_OFFSET);
    int32_t height = i32_at(gdi, RDP_GDI_HEIGHT_OFFSET);
    int32_t stride = (int32_t)u32_at(gdi, RDP_GDI_STRIDE_OFFSET);
    const uint8_t* buffer = (const uint8_t*)ptr_at(gdi, RDP_GDI_PRIMARY_BUFFER_OFFSET);
    if (buffer && width > 0 && height > 0 && stride > 0) {
        session->callbacks.on_frame(session->userdata, buffer, width, height, stride);
    }
    return 1;
}

static RdpBool cb_desktop_resize(void* context) {
    MioRdpSession* session = session_from_context(context);
    if (!session || !session->callbacks.on_connected) return 1;
    void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
    if (!gdi) return 1;
    int32_t width = i32_at(gdi, RDP_GDI_WIDTH_OFFSET);
    int32_t height = i32_at(gdi, RDP_GDI_HEIGHT_OFFSET);
    if (width > 0 && height > 0) {
        session->callbacks.on_connected(session->userdata, width, height);
    }
    return 1;
}

static RdpBool cb_post_connect(void* instance) {
    void* context = ptr_at(instance, RDP_INST_CONTEXT_OFFSET);
    MioRdpSession* session = session_from_context(context);
    if (!session) return 0;

    if (!g_fn.gdi_init(instance, MIO_PIXEL_FORMAT_BGRX32)) {
        return 0;
    }
    session->gdi_initialized = true;

    void* update = ptr_at(context, RDP_CONTEXT_UPDATE_OFFSET);
    if (update) {
        set_ptr_at(update, RDP_UPDATE_BEGIN_PAINT_OFFSET, (void*)cb_begin_paint);
        set_ptr_at(update, RDP_UPDATE_END_PAINT_OFFSET, (void*)cb_end_paint);
        set_ptr_at(update, RDP_UPDATE_DESKTOP_RESIZE_OFFSET, (void*)cb_desktop_resize);
    }

    void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
    if (gdi && session->callbacks.on_connected) {
        int32_t width = i32_at(gdi, RDP_GDI_WIDTH_OFFSET);
        int32_t height = i32_at(gdi, RDP_GDI_HEIGHT_OFFSET);
        session->callbacks.on_connected(session->userdata, width, height);
    }
    session->connected = true;
    return 1;
}

static void cb_post_disconnect(void* instance) {
    void* context = ptr_at(instance, RDP_INST_CONTEXT_OFFSET);
    MioRdpSession* session = session_from_context(context);
    if (!session) return;
    if (session->gdi_initialized) {
        g_fn.gdi_free(instance);
        session->gdi_initialized = false;
    }
    session->connected = false;
}

static RdpUInt32 cb_verify_cert_ex(
    void* instance, const char* host, uint16_t port,
    const char* common_name, const char* subject,
    const char* issuer, const char* fingerprint, RdpUInt32 flags
) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)fingerprint; (void)flags;
    return 1; // Temporarily accept certificate for seamless session start
}

static RdpUInt32 cb_verify_changed_cert_ex(
    void* instance, const char* host, uint16_t port,
    const char* common_name, const char* subject,
    const char* issuer, const char* new_fp,
    const char* old_subject, const char* old_issuer,
    const char* old_fp, RdpUInt32 flags
) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)new_fp;
    (void)old_subject; (void)old_issuer; (void)old_fp; (void)flags;
    return 1;
}

static void set_str_setting(void* settings, const char* name, const char* value) {
    if (!value || !value[0]) return;
    ssize_t key = g_fn.freerdp_settings_get_key_for_name(name);
    if (key >= 0) {
        g_fn.freerdp_settings_set_string(settings, (size_t)key, value);
    }
}

static void set_u32_setting(void* settings, const char* name, uint32_t value) {
    ssize_t key = g_fn.freerdp_settings_get_key_for_name(name);
    if (key >= 0) {
        g_fn.freerdp_settings_set_uint32(settings, (size_t)key, value);
    }
}

static void set_bool_setting(void* settings, const char* name, bool value) {
    ssize_t key = g_fn.freerdp_settings_get_key_for_name(name);
    if (key >= 0) {
        g_fn.freerdp_settings_set_bool(settings, (size_t)key, value ? 1 : 0);
    }
}

MioRdpSession* mio_rdp_create(const MioRdpConfig* config, MioRdpCallbacks callbacks, void* userdata) {
    if (!config || !mio_freerdp_is_available()) return NULL;

    void* instance = g_fn.freerdp_new();
    if (!instance) return NULL;

    set_size_at(instance, RDP_INST_CONTEXT_SIZE_OFFSET, RDP_CONTEXT_SIZE + sizeof(MioRdpSession*));
    set_ptr_at(instance, RDP_INST_PRE_CONNECT_OFFSET, (void*)cb_pre_connect);
    set_ptr_at(instance, RDP_INST_POST_CONNECT_OFFSET, (void*)cb_post_connect);
    set_ptr_at(instance, RDP_INST_POST_DISCONNECT_OFFSET, (void*)cb_post_disconnect);
    set_ptr_at(instance, RDP_INST_VERIFY_CERT_EX_OFFSET, (void*)cb_verify_cert_ex);
    set_ptr_at(instance, RDP_INST_VERIFY_CHANGED_CERT_EX_OFFSET, (void*)cb_verify_changed_cert_ex);

    if (!g_fn.freerdp_context_new(instance)) {
        g_fn.freerdp_free(instance);
        return NULL;
    }

    void* context = ptr_at(instance, RDP_INST_CONTEXT_OFFSET);
    MioRdpSession* session = (MioRdpSession*)calloc(1, sizeof(MioRdpSession));
    if (!session) {
        g_fn.freerdp_context_free(instance);
        g_fn.freerdp_free(instance);
        return NULL;
    }
    session->instance = instance;
    session->context = context;
    session->callbacks = callbacks;
    session->userdata = userdata;
    set_ptr_at(context, RDP_CONTEXT_SIZE, session);

    void* settings = ptr_at(context, RDP_CONTEXT_SETTINGS_OFFSET);
    if (settings) {
        set_str_setting(settings, "ServerHostname", config->host);
        set_u32_setting(settings, "ServerPort", config->port > 0 ? config->port : 3389);
        set_str_setting(settings, "Username", config->username);
        set_str_setting(settings, "Password", config->password);
        set_str_setting(settings, "Domain", config->domain);
        set_u32_setting(settings, "DesktopWidth", config->width > 0 ? config->width : 1280);
        set_u32_setting(settings, "DesktopHeight", config->height > 0 ? config->height : 800);
        set_u32_setting(settings, "ColorDepth", 32);
        set_bool_setting(settings, "SoftwareGdi", true);
        set_bool_setting(settings, "IgnoreCertificate", true);
        set_bool_setting(settings, "NlaSecurity", true);
        set_bool_setting(settings, "TlsSecurity", true);
        set_bool_setting(settings, "RdpSecurity", true);
    }

    return session;
}

bool mio_rdp_connect(MioRdpSession* session) {
    if (!session || !session->instance) return false;
    if (!g_fn.freerdp_connect(session->instance)) {
        if (session->callbacks.on_error && session->context) {
            uint32_t err = g_fn.freerdp_get_last_error(session->context);
            const char* msg = g_fn.freerdp_get_last_error_string(err);
            session->callbacks.on_error(session->userdata, msg ? msg : "FreeRDP connect failed");
        }
        return false;
    }
    return true;
}

int mio_rdp_poll(MioRdpSession* session, uint32_t timeout_ms) {
    if (!session || !session->context) return -1;
    if (g_fn.freerdp_shall_disconnect_context(session->context)) {
        return 0;
    }

    void* handles[64];
    RdpUInt32 count = g_fn.freerdp_get_event_handles(session->context, handles, 64);
    if (count == 0) {
        if (session->callbacks.on_error) {
            session->callbacks.on_error(session->userdata, "FreeRDP event handles unavailable");
        }
        return -1;
    }

    g_fn.wait_for_multiple_objects(count, (const void**)handles, 0, timeout_ms);
    if (!g_fn.freerdp_check_event_handles(session->context)) {
        if (g_fn.freerdp_shall_disconnect_context(session->context)) {
            return 0;
        }
        uint32_t err = g_fn.freerdp_get_last_error(session->context);
        if (err != 0 && session->callbacks.on_error) {
            const char* msg = g_fn.freerdp_get_last_error_string(err);
            session->callbacks.on_error(session->userdata, msg ? msg : "FreeRDP event error");
        }
        return -1;
    }
    return 1;
}

void mio_rdp_disconnect(MioRdpSession* session) {
    if (!session || !session->instance) return;
    g_fn.freerdp_disconnect(session->instance);
}

void mio_rdp_destroy(MioRdpSession* session) {
    if (!session) return;
    if (session->instance) {
        if (session->gdi_initialized) {
            g_fn.gdi_free(session->instance);
            session->gdi_initialized = false;
        }
        g_fn.freerdp_context_free(session->instance);
        g_fn.freerdp_free(session->instance);
        session->instance = NULL;
        session->context = NULL;
    }
    free(session);
}

void mio_rdp_send_mouse(MioRdpSession* session, uint16_t flags, uint16_t x, uint16_t y) {
    if (!session || !session->context || !session->connected) return;
    void* input = ptr_at(session->context, RDP_CONTEXT_INPUT_OFFSET);
    if (input) {
        g_fn.input_send_mouse_event(input, flags, x, y);
    }
}

void mio_rdp_send_key(MioRdpSession* session, bool down, uint32_t rdp_scancode) {
    if (!session || !session->context || !session->connected) return;
    void* input = ptr_at(session->context, RDP_CONTEXT_INPUT_OFFSET);
    if (input) {
        g_fn.input_send_keyboard_event_ex(input, down ? 1 : 0, 0, rdp_scancode);
    }
}

void mio_rdp_send_unicode(MioRdpSession* session, bool down, uint16_t code) {
    if (!session || !session->context || !session->connected) return;
    void* input = ptr_at(session->context, RDP_CONTEXT_INPUT_OFFSET);
    if (input) {
        // KBD_FLAGS_RELEASE = 0x8000
        g_fn.input_send_unicode_keyboard_event(input, down ? 0 : 0x8000, code);
    }
}
