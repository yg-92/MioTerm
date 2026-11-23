#include "CFreeRDPShim.h"

#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

// FreeRDP 3.x ABI offsets (verified on arm64 macOS FreeRDP 3.33.1)
#define RDP_CONTEXT_SIZE 1024
#define RDP_CONTEXT_LAST_ERROR_OFFSET 24
#define RDP_CONTEXT_PUBSUB_OFFSET 144
#define RDP_CONTEXT_GDI_OFFSET 264
#define RDP_CONTEXT_CHANNELS_OFFSET 288
#define RDP_CONTEXT_INPUT_OFFSET 304
#define RDP_CONTEXT_UPDATE_OFFSET 312
#define RDP_CONTEXT_SETTINGS_OFFSET 320

#define RDP_INST_CONTEXT_OFFSET 0
#define RDP_INST_CONTEXT_SIZE_OFFSET 256
#define RDP_INST_PRE_CONNECT_OFFSET 384
#define RDP_INST_POST_CONNECT_OFFSET 392
#define RDP_INST_POST_DISCONNECT_OFFSET 440
#define RDP_INST_LOAD_CHANNELS_OFFSET 472
#define RDP_INST_VERIFY_CERT_EX_OFFSET 528
#define RDP_INST_VERIFY_CHANGED_CERT_EX_OFFSET 536

#define RDP_UPDATE_BEGIN_PAINT_OFFSET 72
#define RDP_UPDATE_END_PAINT_OFFSET 80
#define RDP_UPDATE_DESKTOP_RESIZE_OFFSET 104

#define RDP_GDI_WIDTH_OFFSET 8
#define RDP_GDI_HEIGHT_OFFSET 12
#define RDP_GDI_STRIDE_OFFSET 16
#define RDP_GDI_PRIMARY_BUFFER_OFFSET 64

#define RDP_EVENT_CHANNEL_NAME_OFFSET 16
#define RDP_EVENT_CHANNEL_INTERFACE_OFFSET 24
#define RDP_DISP_SEND_LAYOUT_OFFSET 24

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
    void* client_handle;

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
    RdpUInt32 (*freerdp_settings_get_uint32)(const void* settings, size_t id);
    RdpBool (*freerdp_settings_set_string)(void* settings, size_t id, const char* val);
    RdpBool (*freerdp_settings_set_uint16)(void* settings, size_t id, uint16_t val);
    RdpBool (*freerdp_settings_set_uint32)(void* settings, size_t id, RdpUInt32 val);
    RdpBool (*freerdp_settings_set_bool)(void* settings, size_t id, RdpBool val);

    RdpBool (*gdi_init)(void* instance, RdpUInt32 format);
    RdpBool (*gdi_resize)(void* gdi, RdpUInt32 width, RdpUInt32 height);
    void (*gdi_free)(void* instance);
    RdpBool (*gdi_graphics_pipeline_init)(void* gdi, void* gfx);
    void (*gdi_graphics_pipeline_uninit)(void* gdi, void* gfx);

    RdpBool (*input_send_mouse_event)(void* input, uint16_t flags, uint16_t x, uint16_t y);
    RdpBool (*input_send_keyboard_event_ex)(void* input, RdpBool down, RdpBool repeat, RdpUInt32 rdp_scancode);
    RdpBool (*input_send_unicode_keyboard_event)(void* input, uint16_t flags, uint16_t code);

    RdpUInt32 (*wait_for_multiple_objects)(RdpUInt32 count, const void** handles, RdpBool wait_all, RdpUInt32 ms);
    int (*pubsub_subscribe)(void* pubSub, const char* eventName, ...);

    int (*client_parse_args)(void* settings, int argc, char** argv, RdpBool allow_unknown);
    RdpBool (*client_load_addins)(void* channels, void* settings);
    int (*register_addin_provider)(void* provider, RdpUInt32 flags);
    void* load_static_addin_entry;

    void* (*clipboard_create)(void);
    void (*clipboard_destroy)(void* clipboard);
    RdpBool (*clipboard_empty)(void* clipboard);
    RdpUInt32 (*clipboard_get_format_id)(void* clipboard, const char* name);
    const char* (*clipboard_get_format_name)(void* clipboard, RdpUInt32 format_id);
    RdpUInt32 (*clipboard_register_format)(void* clipboard, const char* name);
    RdpBool (*clipboard_set_data)(void* clipboard, RdpUInt32 format_id, const void* data, RdpUInt32 size);
    void* (*clipboard_get_data)(void* clipboard, RdpUInt32 format_id, RdpUInt32* size);
    void (*clipboard_lock)(void* clipboard);
    void (*clipboard_unlock)(void* clipboard);

    void* (*clip_file_new)(void* context);
    void (*clip_file_free)(void* file);
    RdpBool (*clip_file_init)(void* file, void* cliprdr);
    RdpBool (*clip_file_uninit)(void* file, void* cliprdr);
    RdpBool (*clip_file_clear)(void* file);
    RdpBool (*clip_file_set_locally_available)(void* file, RdpBool available);
    RdpBool (*clip_file_remote_set_flags)(void* file, RdpUInt32 flags);
    RdpUInt32 (*clip_file_current_flags)(void* file);
    RdpUInt32 (*clip_file_notify_new_server_format_list)(void* file);
    RdpUInt32 (*clip_file_notify_new_client_format_list)(void* file);
    RdpBool (*clip_file_update_client_data)(void* file, const char* data, size_t size);
    RdpBool (*clip_file_set_local_clipboard_data)(void* file, const void* (*fkt)(void*, const char*, size_t*), void* userdata, const char** mime_types, size_t count);
    RdpUInt32 (*cliprdr_serialize_file_list_ex)(RdpUInt32 flags, const void* file_descriptor_array, RdpUInt32 file_descriptor_count, uint8_t** format_data, RdpUInt32* format_data_length);
    RdpUInt32 (*cliprdr_parse_file_list)(const uint8_t* format_data, RdpUInt32 format_data_length, void** file_descriptor_array, RdpUInt32* file_descriptor_count);
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
    char client_path[512];
    snprintf(winpr_path, sizeof(winpr_path), "%s/libwinpr3.dylib", dir);
    snprintf(freerdp_path, sizeof(freerdp_path), "%s/libfreerdp3.dylib", dir);
    snprintf(client_path, sizeof(client_path), "%s/libfreerdp-client3.dylib", dir);

    void* winpr = dlopen(winpr_path, RTLD_LAZY | RTLD_LOCAL);
    if (!winpr) return false;

    void* freerdp = dlopen(freerdp_path, RTLD_LAZY | RTLD_LOCAL);
    if (!freerdp) {
        dlclose(winpr);
        return false;
    }

    void* client = dlopen(client_path, RTLD_LAZY | RTLD_LOCAL);

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
    LOAD_SYM(freerdp, freerdp_settings_get_uint32, "freerdp_settings_get_uint32");
    LOAD_SYM(freerdp, freerdp_settings_set_string, "freerdp_settings_set_string");
    LOAD_SYM(freerdp, freerdp_settings_set_uint16, "freerdp_settings_set_uint16");
    LOAD_SYM(freerdp, freerdp_settings_set_uint32, "freerdp_settings_set_uint32");
    LOAD_SYM(freerdp, freerdp_settings_set_bool, "freerdp_settings_set_bool");

    LOAD_SYM(freerdp, gdi_init, "gdi_init");
    LOAD_SYM(freerdp, gdi_resize, "gdi_resize");
    LOAD_SYM(freerdp, gdi_free, "gdi_free");
    g_fn.gdi_graphics_pipeline_init = dlsym(freerdp, "gdi_graphics_pipeline_init");
    g_fn.gdi_graphics_pipeline_uninit = dlsym(freerdp, "gdi_graphics_pipeline_uninit");

    LOAD_SYM(freerdp, input_send_mouse_event, "freerdp_input_send_mouse_event");
    LOAD_SYM(freerdp, input_send_keyboard_event_ex, "freerdp_input_send_keyboard_event_ex");
    LOAD_SYM(freerdp, input_send_unicode_keyboard_event, "freerdp_input_send_unicode_keyboard_event");

    LOAD_SYM(winpr, wait_for_multiple_objects, "WaitForMultipleObjects");
    #undef LOAD_SYM

    g_fn.pubsub_subscribe = dlsym(winpr, "PubSub_Subscribe");
    g_fn.clipboard_create = dlsym(winpr, "ClipboardCreate");
    g_fn.clipboard_destroy = dlsym(winpr, "ClipboardDestroy");
    g_fn.clipboard_empty = dlsym(winpr, "ClipboardEmpty");
    g_fn.clipboard_get_format_id = dlsym(winpr, "ClipboardGetFormatId");
    g_fn.clipboard_get_format_name = dlsym(winpr, "ClipboardGetFormatName");
    g_fn.clipboard_register_format = dlsym(winpr, "ClipboardRegisterFormat");
    g_fn.clipboard_set_data = dlsym(winpr, "ClipboardSetData");
    g_fn.clipboard_get_data = dlsym(winpr, "ClipboardGetData");
    g_fn.clipboard_lock = dlsym(winpr, "ClipboardLock");
    g_fn.clipboard_unlock = dlsym(winpr, "ClipboardUnlock");

    if (client) {
        g_fn.client_parse_args = dlsym(client, "freerdp_client_settings_parse_command_line_arguments");
        g_fn.client_load_addins = dlsym(client, "freerdp_client_load_addins");
        g_fn.load_static_addin_entry = dlsym(client, "freerdp_channels_load_static_addin_entry");
        g_fn.register_addin_provider = dlsym(freerdp, "freerdp_register_addin_provider");
        if (g_fn.register_addin_provider && g_fn.load_static_addin_entry) {
            g_fn.register_addin_provider(g_fn.load_static_addin_entry, 0);
        }
        g_fn.clip_file_new = dlsym(client, "cliprdr_file_context_new");
        g_fn.clip_file_free = dlsym(client, "cliprdr_file_context_free");
        g_fn.clip_file_init = dlsym(client, "cliprdr_file_context_init");
        g_fn.clip_file_uninit = dlsym(client, "cliprdr_file_context_uninit");
        g_fn.clip_file_clear = dlsym(client, "cliprdr_file_context_clear");
        g_fn.clip_file_set_locally_available = dlsym(client, "cliprdr_file_context_set_locally_available");
        g_fn.clip_file_remote_set_flags = dlsym(client, "cliprdr_file_context_remote_set_flags");
        g_fn.clip_file_current_flags = dlsym(client, "cliprdr_file_context_current_flags");
        g_fn.clip_file_notify_new_server_format_list = dlsym(client, "cliprdr_file_context_notify_new_server_format_list");
        g_fn.clip_file_notify_new_client_format_list = dlsym(client, "cliprdr_file_context_notify_new_client_format_list");
        g_fn.clip_file_update_client_data = dlsym(client, "cliprdr_file_context_update_client_data");
        g_fn.clip_file_set_local_clipboard_data = dlsym(client, "cliprdr_file_context_set_local_clipboard_data");
    }
    g_fn.cliprdr_serialize_file_list_ex = dlsym(freerdp, "cliprdr_serialize_file_list_ex");
    g_fn.cliprdr_parse_file_list = dlsym(freerdp, "cliprdr_parse_file_list");

    g_fn.winpr_handle = winpr;
    g_fn.freerdp_handle = freerdp;
    g_fn.client_handle = client;
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
    void* disp;
    MioRdpCallbacks callbacks;
    void* userdata;
    pthread_mutex_t lock;
    uint32_t pending_width;
    uint32_t pending_height;
    uint32_t pending_scale_percent;
    uint32_t scale_percent;
    bool resize_pending;
    bool disp_ready;
    bool gdi_initialized;
    bool connected;

    void* cliprdr;
    void* clip_file;
    void* clipboard;
    pthread_mutex_t clip_lock;
    pthread_cond_t clip_cond;
    bool closing;
    bool clip_ready;
    bool server_has_text;
    uint32_t server_text_format_id;
    bool server_has_files;
    uint32_t server_fgd_format_id;
    uint32_t client_fgd_format_id;
    bool pending_response_ready;
    uint8_t* pending_response_data;
    uint32_t pending_response_size;
    uint8_t* remote_fgd_cache;
    size_t remote_fgd_cache_size;
    uint8_t* remote_text_cache;
    size_t remote_text_cache_size;
    char* client_uri_list;
    uint64_t server_clip_generation;
    uint32_t server_clip_caps;
    uint32_t next_client_lock_id;
    uint32_t next_file_stream_id;
    uint32_t pending_file_stream_id;
    bool pending_file_ready;
    bool pending_file_ok;
    uint8_t* pending_file_data;
    uint32_t pending_file_size;
};

#define MIO_CF_TEXT 1u
#define MIO_CF_UNICODETEXT 13u
#define MIO_CB_FORMAT_LIST 0x0002u
#define MIO_CB_FORMAT_LIST_RESPONSE 0x0003u
#define MIO_CB_FORMAT_DATA_REQUEST 0x0004u
#define MIO_CB_FORMAT_DATA_RESPONSE 0x0005u
#define MIO_CB_CLIP_CAPS 0x0007u
#define MIO_CB_RESPONSE_OK 0x0001u
#define MIO_CB_RESPONSE_FAIL 0x0002u
#define MIO_CB_CAPSTYPE_GENERAL 0x0001u
#define MIO_CB_CAPSTYPE_GENERAL_LEN 12u
#define MIO_CB_CAPS_VERSION_2 0x00000002u
#define MIO_CB_USE_LONG_FORMAT_NAMES 0x00000002u
#define MIO_CB_STREAM_FILECLIP_ENABLED 0x00000004u
#define MIO_CB_FILECLIP_NO_FILE_PATHS 0x00000008u
#define MIO_CB_CAN_LOCK_CLIPDATA 0x00000010u
#define MIO_CB_HUGE_FILE_SUPPORT_ENABLED 0x00000020u

typedef struct {
    uint16_t msgType;
    uint16_t msgFlags;
    uint32_t dataLen;
} MioCliprdrHeader;

typedef struct {
    uint16_t capabilitySetType;
    uint16_t capabilitySetLength;
    uint32_t version;
    uint32_t generalFlags;
} MioCliprdrGeneralCapSet;

typedef struct {
    MioCliprdrHeader common;
    uint32_t cCapabilitiesSets;
    void* capabilitySets;
} MioCliprdrCapabilities;

typedef struct {
    uint32_t formatId;
    char* formatName;
} MioCliprdrFormat;

typedef struct {
    MioCliprdrHeader common;
    uint32_t numFormats;
    MioCliprdrFormat* formats;
} MioCliprdrFormatList;

typedef struct {
    MioCliprdrHeader common;
} MioCliprdrFormatListResponse;

typedef struct {
    MioCliprdrHeader common;
    uint32_t requestedFormatId;
} MioCliprdrFormatDataRequest;

typedef struct {
    MioCliprdrHeader common;
    const uint8_t* requestedFormatData;
} MioCliprdrFormatDataResponse;

#define MIO_CB_FILECONTENTS_REQUEST 0x0008u
#define MIO_CB_LOCK_CLIPDATA 0x000Au
#define MIO_CB_UNLOCK_CLIPDATA 0x000Bu
#define MIO_FILECONTENTS_SIZE 0x00000001u
#define MIO_FILECONTENTS_RANGE 0x00000002u
#define MIO_FD_FILESIZE 0x00000040u
#define MIO_FILE_ATTRIBUTE_DIRECTORY 0x00000010u

typedef struct {
    MioCliprdrHeader common;
    uint32_t clipDataId;
} MioCliprdrLockClipboardData;

typedef struct {
    MioCliprdrHeader common;
    uint32_t streamId;
    uint32_t listIndex;
    uint32_t dwFlags;
    uint32_t nPositionLow;
    uint32_t nPositionHigh;
    uint32_t cbRequested;
    RdpBool haveClipDataId;
    uint32_t clipDataId;
} MioCliprdrFileContentsRequest;

typedef struct {
    MioCliprdrHeader common;
    uint32_t streamId;
    uint32_t cbRequested;
    const uint8_t* requestedData;
} MioCliprdrFileContentsResponse;

typedef struct {
    uint32_t dwFlags;
    uint8_t clsid[16];
    uint8_t sizel[8];
    uint8_t pointl[8];
    uint32_t dwFileAttributes;
    uint64_t ftCreationTime;
    uint64_t ftLastAccessTime;
    uint64_t ftLastWriteTime;
    uint32_t nFileSizeHigh;
    uint32_t nFileSizeLow;
    uint16_t cFileName[260];
} MioFileDescriptorW;

typedef struct MioCliprdrClientContext MioCliprdrClientContext;
typedef RdpUInt32 (*MioCliprdrFn)(MioCliprdrClientContext* context, const void* arg);

struct MioCliprdrClientContext {
    void* handle;
    void* custom;
    MioCliprdrFn ServerCapabilities;
    MioCliprdrFn ClientCapabilities;
    MioCliprdrFn MonitorReady;
    MioCliprdrFn TempDirectory;
    MioCliprdrFn ClientFormatList;
    MioCliprdrFn ServerFormatList;
    MioCliprdrFn ClientFormatListResponse;
    MioCliprdrFn ServerFormatListResponse;
    MioCliprdrFn ClientLockClipboardData;
    MioCliprdrFn ServerLockClipboardData;
    MioCliprdrFn ClientUnlockClipboardData;
    MioCliprdrFn ServerUnlockClipboardData;
    MioCliprdrFn ClientFormatDataRequest;
    MioCliprdrFn ServerFormatDataRequest;
    MioCliprdrFn ClientFormatDataResponse;
    MioCliprdrFn ServerFormatDataResponse;
    MioCliprdrFn ClientFileContentsRequest;
    MioCliprdrFn ServerFileContentsRequest;
    MioCliprdrFn ClientFileContentsResponse;
    MioCliprdrFn ServerFileContentsResponse;
    uint32_t lastRequestedFormatId;
    void* rdpcontext;
};

typedef struct {
    uint32_t Flags;
    int32_t Left;
    int32_t Top;
    uint32_t Width;
    uint32_t Height;
    uint32_t PhysicalWidth;
    uint32_t PhysicalHeight;
    uint32_t Orientation;
    uint32_t DesktopScaleFactor;
    uint32_t DeviceScaleFactor;
} MioDisplayMonitorLayout;

typedef RdpUInt32 (*MioDispSendLayoutFn)(void* disp, RdpUInt32 num_monitors, MioDisplayMonitorLayout* monitors);

static MioRdpSession* session_from_context(void* context) {
    if (!context) return NULL;
    return (MioRdpSession*)ptr_at(context, RDP_CONTEXT_SIZE);
}

static void shim_log(MioRdpSession* session, const char* message);

static MioRdpSession* session_from_cliprdr(MioCliprdrClientContext* cliprdr) {
    if (!cliprdr) return NULL;
    return session_from_context(cliprdr->rdpcontext);
}

static RdpUInt32 cb_cliprdr_server_capabilities(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrCapabilities* caps = (const MioCliprdrCapabilities*)arg;
    if (!session || !caps) return 0;
    if (caps->cCapabilitiesSets > 0 && caps->capabilitySets) {
        const MioCliprdrGeneralCapSet* set = (const MioCliprdrGeneralCapSet*)caps->capabilitySets;
        if (set->capabilitySetType == MIO_CB_CAPSTYPE_GENERAL) {
            pthread_mutex_lock(&session->clip_lock);
            session->server_clip_caps = set->generalFlags;
            pthread_mutex_unlock(&session->clip_lock);
            if (session->clip_file && g_fn.clip_file_remote_set_flags) {
                g_fn.clip_file_remote_set_flags(session->clip_file, set->generalFlags);
            }
        }
    }
    return 0;
}

static RdpUInt32 cb_cliprdr_monitor_ready(MioCliprdrClientContext* cliprdr, const void* arg) {
    (void)arg;
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    if (!session || !cliprdr || !cliprdr->ClientCapabilities) return 0;

    MioCliprdrGeneralCapSet gen = {0};
    gen.capabilitySetType = MIO_CB_CAPSTYPE_GENERAL;
    gen.capabilitySetLength = MIO_CB_CAPSTYPE_GENERAL_LEN;
    gen.version = MIO_CB_CAPS_VERSION_2;
    gen.generalFlags = MIO_CB_USE_LONG_FORMAT_NAMES |
                       MIO_CB_STREAM_FILECLIP_ENABLED |
                       MIO_CB_FILECLIP_NO_FILE_PATHS |
                       MIO_CB_CAN_LOCK_CLIPDATA |
                       MIO_CB_HUGE_FILE_SUPPORT_ENABLED;

    MioCliprdrCapabilities caps = {0};
    caps.common.msgType = MIO_CB_CLIP_CAPS;
    caps.common.dataLen = 4 + MIO_CB_CAPSTYPE_GENERAL_LEN;
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = &gen;
    cliprdr->ClientCapabilities(cliprdr, &caps);

    pthread_mutex_lock(&session->clip_lock);
    session->clip_ready = true;
    pthread_mutex_unlock(&session->clip_lock);

    if (session->callbacks.on_clipboard_ready) {
        session->callbacks.on_clipboard_ready(session->userdata);
    }
    return 0;
}

static RdpUInt32 cb_cliprdr_server_format_list(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrFormatList* list = (const MioCliprdrFormatList*)arg;
    if (!session || !list) return 0;

    bool has_text = false;
    uint32_t text_fmt = 0;
    bool has_files = false;
    uint32_t fgd_fmt = 0;

    for (uint32_t i = 0; i < list->numFormats; i++) {
        uint32_t fid = list->formats[i].formatId;
        const char* fname = list->formats[i].formatName;
        if (fid == MIO_CF_UNICODETEXT) {
            has_text = true;
            text_fmt = MIO_CF_UNICODETEXT;
        } else if (fid == MIO_CF_TEXT && !has_text) {
            has_text = true;
            text_fmt = MIO_CF_TEXT;
        } else if (fname && strcmp(fname, "FileGroupDescriptorW") == 0) {
            has_files = true;
            fgd_fmt = fid;
        }
    }

    pthread_mutex_lock(&session->clip_lock);
    session->server_has_text = has_text;
    session->server_text_format_id = text_fmt;
    session->server_has_files = has_files;
    session->server_fgd_format_id = fgd_fmt;
    session->server_clip_generation++;
    pthread_cond_broadcast(&session->clip_cond);
    pthread_mutex_unlock(&session->clip_lock);

    if (session->clip_file && g_fn.clip_file_notify_new_server_format_list) {
        g_fn.clip_file_notify_new_server_format_list(session->clip_file);
    }

    if (cliprdr->ClientFormatListResponse) {
        MioCliprdrFormatListResponse resp = {0};
        resp.common.msgType = MIO_CB_FORMAT_LIST_RESPONSE;
        resp.common.msgFlags = MIO_CB_RESPONSE_OK;
        cliprdr->ClientFormatListResponse(cliprdr, &resp);
    }

    if ((has_text || has_files) && session->callbacks.on_clipboard_formats) {
        session->callbacks.on_clipboard_formats(session->userdata, has_text, has_files);
    }
    return 0;
}

static RdpUInt32 cb_cliprdr_server_format_list_response(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrFormatListResponse* resp = (const MioCliprdrFormatListResponse*)arg;
    if (session && resp) {
        char buf[96];
        snprintf(buf, sizeof(buf), "cliprdr ServerFormatListResponse flags=0x%x", resp->common.msgFlags);
        shim_log(session, buf);
    }
    return 0;
}

#define MIO_FILEDESCRIPTORW_SIZE 592u

static RdpUInt32 cb_cliprdr_server_format_data_request(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrFormatDataRequest* req = (const MioCliprdrFormatDataRequest*)arg;
    if (!session || !req || !cliprdr->ClientFormatDataResponse) return 0;

    void* data = NULL;
    uint32_t data_size = 0;
    uint32_t fgd_id = 0;
    uint32_t file_flags = 0;
    RdpBool file_updated = 0;

    pthread_mutex_lock(&session->clip_lock);
    fgd_id = session->client_fgd_format_id;
    if (fgd_id != 0 && req->requestedFormatId == fgd_id &&
        session->clip_file && session->client_uri_list && g_fn.clip_file_update_client_data) {
        // 必须在 Windows 下发 ServerLockClipboardData 之后、响应 FileGroupDescriptorW 时更新，
        // 这样 FreeRDP 会把文件列表绑定到当前的 clipDataId 锁槽，后续 FileContentsRequest 才能命中。
        file_updated = g_fn.clip_file_update_client_data(
            session->clip_file,
            session->client_uri_list,
            strlen(session->client_uri_list)
        );
    }
    if (session->clipboard && g_fn.clipboard_get_data) {
        data = g_fn.clipboard_get_data(session->clipboard, req->requestedFormatId, &data_size);
    }
    if (session->clip_file && g_fn.clip_file_current_flags) {
        file_flags = g_fn.clip_file_current_flags(session->clip_file);
    }
    pthread_mutex_unlock(&session->clip_lock);

    uint32_t raw_size = data_size;
    if (fgd_id != 0 && req->requestedFormatId == fgd_id && data && data_size >= MIO_FILEDESCRIPTORW_SIZE &&
        (data_size % MIO_FILEDESCRIPTORW_SIZE) == 0 && g_fn.cliprdr_serialize_file_list_ex) {
        uint8_t* serialized = NULL;
        RdpUInt32 serialized_size = 0;
        RdpUInt32 count = data_size / MIO_FILEDESCRIPTORW_SIZE;
        RdpUInt32 ser_rc = g_fn.cliprdr_serialize_file_list_ex(file_flags, data, count, &serialized, &serialized_size);
        free(data);
        if (ser_rc == 0 && serialized && serialized_size > 0) {
            data = serialized;
            data_size = serialized_size;
        } else {
            free(serialized);
            data = NULL;
            data_size = 0;
        }
    }

    char buf[192];
    snprintf(buf, sizeof(buf), "cliprdr ServerFormatDataRequest fmt=%u (fgd=%u) updated=%d raw=%u resp=%u flags=0x%x",
             req->requestedFormatId, fgd_id, file_updated, raw_size, data_size, file_flags);
    shim_log(session, buf);

    MioCliprdrFormatDataResponse resp = {0};
    resp.common.msgType = MIO_CB_FORMAT_DATA_RESPONSE;
    resp.common.msgFlags = data ? MIO_CB_RESPONSE_OK : MIO_CB_RESPONSE_FAIL;
    resp.common.dataLen = data ? data_size : 0;
    resp.requestedFormatData = (const uint8_t*)data;
    cliprdr->ClientFormatDataResponse(cliprdr, &resp);
    free(data);
    return 0;
}

static RdpUInt32 cb_cliprdr_server_format_data_response(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrFormatDataResponse* resp = (const MioCliprdrFormatDataResponse*)arg;
    if (!session || !resp) return 0;

    pthread_mutex_lock(&session->clip_lock);
    free(session->pending_response_data);
    session->pending_response_data = NULL;
    session->pending_response_size = 0;

    if ((resp->common.msgFlags & MIO_CB_RESPONSE_OK) &&
        resp->requestedFormatData &&
        resp->common.dataLen > 0) {
        session->pending_response_data = (uint8_t*)malloc(resp->common.dataLen);
        if (session->pending_response_data) {
            memcpy(session->pending_response_data, resp->requestedFormatData, resp->common.dataLen);
            session->pending_response_size = resp->common.dataLen;
        }
    }
    session->pending_response_ready = true;
    pthread_cond_broadcast(&session->clip_cond);
    pthread_mutex_unlock(&session->clip_lock);
    return 0;
}

static RdpUInt32 cb_cliprdr_server_file_contents_response(MioCliprdrClientContext* cliprdr, const void* arg) {
    MioRdpSession* session = session_from_cliprdr(cliprdr);
    const MioCliprdrFileContentsResponse* resp = (const MioCliprdrFileContentsResponse*)arg;
    if (!session || !resp) return 0;

    pthread_mutex_lock(&session->clip_lock);
    if (resp->streamId == session->pending_file_stream_id) {
        free(session->pending_file_data);
        session->pending_file_data = NULL;
        session->pending_file_size = 0;
        session->pending_file_ok = (resp->common.msgFlags & MIO_CB_RESPONSE_OK) != 0;
        if (session->pending_file_ok && resp->requestedData && resp->cbRequested > 0) {
            session->pending_file_data = (uint8_t*)malloc(resp->cbRequested);
            if (session->pending_file_data) {
                memcpy(session->pending_file_data, resp->requestedData, resp->cbRequested);
                session->pending_file_size = resp->cbRequested;
            } else {
                session->pending_file_ok = false;
            }
        }
        session->pending_file_ready = true;
        pthread_cond_broadcast(&session->clip_cond);
    }
    pthread_mutex_unlock(&session->clip_lock);
    return 0;
}

static void shim_log(MioRdpSession* session, const char* message) {
    if (session && session->callbacks.on_log && message) {
        session->callbacks.on_log(session->userdata, message);
    }
}

static RdpUInt32 cb_disp_caps(void* disp, RdpUInt32 max_num_monitors, RdpUInt32 max_area_a, RdpUInt32 max_area_b) {
    (void)max_num_monitors;
    (void)max_area_a;
    (void)max_area_b;
    if (!disp) return 0;
    MioRdpSession* session = (MioRdpSession*)ptr_at(disp, 8);
    if (session) {
        pthread_mutex_lock(&session->lock);
        session->disp_ready = true;
        pthread_mutex_unlock(&session->lock);
        char buf[128];
        snprintf(buf, sizeof(buf), "DisplayControlCaps maxMonitors=%u area=(%u,%u)", max_num_monitors, max_area_a, max_area_b);
        shim_log(session, buf);
    }
    return 0;
}

static void cb_channel_connected(void* context, const void* e) {
    MioRdpSession* session = session_from_context(context);
    if (!session || !e) return;
    const char* name = *(const char**)((const char*)e + RDP_EVENT_CHANNEL_NAME_OFFSET);
    void* iface = *(void**)((const char*)e + RDP_EVENT_CHANNEL_INTERFACE_OFFSET);
    if (name) {
        char buf[160];
        snprintf(buf, sizeof(buf), "ChannelConnected: %s (iface=%p)", name, iface);
        shim_log(session, buf);
    }
    if (name && strcmp(name, "Microsoft::Windows::RDS::Graphics") == 0 && iface) {
        void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
        if (gdi && g_fn.gdi_graphics_pipeline_init) {
            RdpBool ok = g_fn.gdi_graphics_pipeline_init(gdi, iface);
            char buf[64];
            snprintf(buf, sizeof(buf), "gdi_graphics_pipeline_init=%d", ok);
            shim_log(session, buf);
        }
    } else if (name && strcmp(name, "Microsoft::Windows::RDS::DisplayControl") == 0 && iface) {
        pthread_mutex_lock(&session->lock);
        session->disp = iface;
        session->disp_ready = false;
        pthread_mutex_unlock(&session->lock);
        set_ptr_at(iface, 8, session);
        set_ptr_at(iface, 16, (void*)cb_disp_caps);
        shim_log(session, "ChannelConnected: DisplayControl");
    } else if (name && strcmp(name, "cliprdr") == 0 && iface) {
        MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)iface;
        pthread_mutex_lock(&session->clip_lock);
        session->cliprdr = cliprdr;
        if (!session->clipboard && g_fn.clipboard_create) {
            session->clipboard = g_fn.clipboard_create();
            if (session->clipboard && g_fn.clipboard_get_format_id) {
                session->client_fgd_format_id = g_fn.clipboard_get_format_id(session->clipboard, "FileGroupDescriptorW");
            }
        }
        if (!session->clip_file && g_fn.clip_file_new) {
            session->clip_file = g_fn.clip_file_new(session);
        }
        if (session->clip_file && g_fn.clip_file_init) {
            g_fn.clip_file_init(session->clip_file, cliprdr);
            if (g_fn.clip_file_set_locally_available) {
                g_fn.clip_file_set_locally_available(session->clip_file, 1);
            }
        }
        cliprdr->ServerCapabilities = cb_cliprdr_server_capabilities;
        cliprdr->MonitorReady = cb_cliprdr_monitor_ready;
        cliprdr->ServerFormatList = cb_cliprdr_server_format_list;
        cliprdr->ServerFormatListResponse = cb_cliprdr_server_format_list_response;
        cliprdr->ServerFormatDataRequest = cb_cliprdr_server_format_data_request;
        cliprdr->ServerFormatDataResponse = cb_cliprdr_server_format_data_response;
        cliprdr->ServerFileContentsResponse = cb_cliprdr_server_file_contents_response;
        pthread_mutex_unlock(&session->clip_lock);
    }
}

static void cb_channel_disconnected(void* context, const void* e) {
    MioRdpSession* session = session_from_context(context);
    if (!session || !e) return;
    const char* name = *(const char**)((const char*)e + RDP_EVENT_CHANNEL_NAME_OFFSET);
    void* iface = *(void**)((const char*)e + RDP_EVENT_CHANNEL_INTERFACE_OFFSET);
    if (name && strcmp(name, "Microsoft::Windows::RDS::Graphics") == 0 && iface) {
        void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
        if (gdi && g_fn.gdi_graphics_pipeline_uninit) {
            g_fn.gdi_graphics_pipeline_uninit(gdi, iface);
        }
    } else if (name && strcmp(name, "Microsoft::Windows::RDS::DisplayControl") == 0) {
        pthread_mutex_lock(&session->lock);
        session->disp = NULL;
        session->disp_ready = false;
        pthread_mutex_unlock(&session->lock);
    } else if (name && strcmp(name, "cliprdr") == 0) {
        pthread_mutex_lock(&session->clip_lock);
        if (session->clip_file && session->cliprdr && g_fn.clip_file_uninit) {
            g_fn.clip_file_uninit(session->clip_file, session->cliprdr);
        }
        if (session->clip_file && g_fn.clip_file_free) {
            g_fn.clip_file_free(session->clip_file);
            session->clip_file = NULL;
        }
        if (session->clipboard && g_fn.clipboard_destroy) {
            g_fn.clipboard_destroy(session->clipboard);
            session->clipboard = NULL;
        }
        session->cliprdr = NULL;
        session->clip_ready = false;
        pthread_cond_broadcast(&session->clip_cond);
        pthread_mutex_unlock(&session->clip_lock);
    }
}

static RdpBool cb_load_channels(void* instance) {
    if (!instance) return 0;
    void* context = ptr_at(instance, RDP_INST_CONTEXT_OFFSET);
    if (context && g_fn.client_load_addins) {
        void* channels = ptr_at(context, RDP_CONTEXT_CHANNELS_OFFSET);
        void* settings = ptr_at(context, RDP_CONTEXT_SETTINGS_OFFSET);
        if (channels && settings) {
            RdpBool ok = g_fn.client_load_addins(channels, settings);
            MioRdpSession* session = session_from_context(context);
            char buf[64];
            snprintf(buf, sizeof(buf), "LoadChannels client_load_addins=%d", ok);
            shim_log(session, buf);
        }
    }
    return 1;
}

static RdpBool cb_pre_connect(void* instance) {
    if (!instance) return 0;
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

static uint32_t get_u32_setting(void* settings, const char* name) {
    ssize_t key = g_fn.freerdp_settings_get_key_for_name(name);
    if (key < 0) return 0;
    return g_fn.freerdp_settings_get_uint32(settings, (size_t)key);
}

static RdpBool cb_desktop_resize(void* context) {
    MioRdpSession* session = session_from_context(context);
    if (!session) return 1;
    void* gdi = ptr_at(context, RDP_CONTEXT_GDI_OFFSET);
    void* settings = ptr_at(context, RDP_CONTEXT_SETTINGS_OFFSET);
    if (!gdi) return 1;
    uint32_t width = settings ? get_u32_setting(settings, "FreeRDP_DesktopWidth") : 0;
    uint32_t height = settings ? get_u32_setting(settings, "FreeRDP_DesktopHeight") : 0;
    if (width > 0 && height > 0 && g_fn.gdi_resize) {
        g_fn.gdi_resize(gdi, width, height);
    } else {
        width = (uint32_t)i32_at(gdi, RDP_GDI_WIDTH_OFFSET);
        height = (uint32_t)i32_at(gdi, RDP_GDI_HEIGHT_OFFSET);
    }
    if (width > 0 && height > 0 && session->callbacks.on_connected) {
        char buf[96];
        snprintf(buf, sizeof(buf), "cb_desktop_resize=%ux%u", width, height);
        shim_log(session, buf);
        session->callbacks.on_connected(session->userdata, (int32_t)width, (int32_t)height);
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

static void set_u16_setting(void* settings, const char* name, uint16_t value) {
    ssize_t key = g_fn.freerdp_settings_get_key_for_name(name);
    if (key >= 0) {
        g_fn.freerdp_settings_set_uint16(settings, (size_t)key, value);
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
    set_ptr_at(instance, RDP_INST_LOAD_CHANNELS_OFFSET, (void*)cb_load_channels);
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
    session->scale_percent = (config->scale_percent >= 100 && config->scale_percent <= 500) ? config->scale_percent : 100;
    session->pending_scale_percent = session->scale_percent;
    pthread_mutex_init(&session->lock, NULL);
    pthread_mutex_init(&session->clip_lock, NULL);
    pthread_cond_init(&session->clip_cond, NULL);
    set_ptr_at(context, RDP_CONTEXT_SIZE, session);

    if (g_fn.pubsub_subscribe) {
        void* pubsub = ptr_at(context, RDP_CONTEXT_PUBSUB_OFFSET);
        if (pubsub) {
            g_fn.pubsub_subscribe(pubsub, "ChannelConnected", cb_channel_connected);
            g_fn.pubsub_subscribe(pubsub, "ChannelDisconnected", cb_channel_disconnected);
        }
    }

    void* settings = ptr_at(context, RDP_CONTEXT_SETTINGS_OFFSET);
    if (settings) {
        set_str_setting(settings, "FreeRDP_ServerHostname", config->host);
        set_u32_setting(settings, "FreeRDP_ServerPort", config->port > 0 ? config->port : 3389);
        set_str_setting(settings, "FreeRDP_Username", config->username);
        set_str_setting(settings, "FreeRDP_Password", config->password);
        set_str_setting(settings, "FreeRDP_Domain", config->domain);
        set_u32_setting(settings, "FreeRDP_DesktopWidth", config->width > 0 ? config->width : 1280);
        set_u32_setting(settings, "FreeRDP_DesktopHeight", config->height > 0 ? config->height : 800);
        set_u32_setting(settings, "FreeRDP_DesktopScaleFactor", session->scale_percent);
        set_u32_setting(settings, "FreeRDP_DeviceScaleFactor", session->scale_percent);
        set_u32_setting(settings, "FreeRDP_ColorDepth", 32);
        set_bool_setting(settings, "FreeRDP_SoftwareGdi", true);
        set_bool_setting(settings, "FreeRDP_IgnoreCertificate", true);
        set_u32_setting(settings, "FreeRDP_TlsSecLevel", 0);
        set_u16_setting(settings, "FreeRDP_TLSMinVersion", 0x0301);
        set_u16_setting(settings, "FreeRDP_TLSMaxVersion", 0x0303);
        set_bool_setting(settings, "FreeRDP_NlaSecurity", true);
        set_bool_setting(settings, "FreeRDP_TlsSecurity", true);
        set_bool_setting(settings, "FreeRDP_RdpSecurity", true);
        set_bool_setting(settings, "FreeRDP_DeviceRedirection", true);
        set_bool_setting(settings, "FreeRDP_RedirectDrives", true);
        set_bool_setting(settings, "FreeRDP_RedirectHomeDrive", true);
        set_bool_setting(settings, "FreeRDP_RedirectClipboard", true);
        set_bool_setting(settings, "FreeRDP_SupportDynamicChannels", true);
        set_bool_setting(settings, "FreeRDP_SupportGraphicsPipeline", true);
        set_bool_setting(settings, "FreeRDP_SupportDisplayControl", true);
        set_bool_setting(settings, "FreeRDP_DynamicResolutionUpdate", true);

        if (config->shared_dir && config->shared_dir[0] && g_fn.client_parse_args) {
            char drive_arg[1024];
            snprintf(drive_arg, sizeof(drive_arg), "/drive:MioTerm,%s", config->shared_dir);
            char* argv[] = {"mioterm-rdp", drive_arg};
            g_fn.client_parse_args(settings, 2, argv, 1);
        }
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

    void* disp = NULL;
    uint32_t req_w = 0;
    uint32_t req_h = 0;
    uint32_t req_scale = 100;
    bool disp_ready = false;
    bool should_resize = false;
    pthread_mutex_lock(&session->lock);
    if (session->resize_pending && session->disp && session->disp_ready) {
        disp = session->disp;
        req_w = session->pending_width;
        req_h = session->pending_height;
        req_scale = session->pending_scale_percent >= 100 ? session->pending_scale_percent : 100;
        disp_ready = session->disp_ready;
        session->resize_pending = false;
        should_resize = true;
    }
    pthread_mutex_unlock(&session->lock);

    if (should_resize && disp) {
        MioDispSendLayoutFn send_layout = (MioDispSendLayoutFn)ptr_at(disp, RDP_DISP_SEND_LAYOUT_OFFSET);
        if (send_layout) {
            MioDisplayMonitorLayout layout;
            memset(&layout, 0, sizeof(layout));
            layout.Flags = 0x00000001; // DISPLAY_CONTROL_MONITOR_PRIMARY
            layout.Width = req_w;
            layout.Height = req_h;
            uint32_t phys_w = (req_w * 254u) / 960u;
            uint32_t phys_h = (req_h * 254u) / 960u;
            layout.PhysicalWidth = phys_w < 10 ? 10 : (phys_w > 10000 ? 10000 : phys_w);
            layout.PhysicalHeight = phys_h < 10 ? 10 : (phys_h > 10000 ? 10000 : phys_h);
            layout.DesktopScaleFactor = req_scale;
            layout.DeviceScaleFactor = req_scale;
            RdpUInt32 rc = send_layout(disp, 1, &layout);
            char buf[128];
            snprintf(buf, sizeof(buf), "send_layout(%ux%u scale=%u ready=%d) -> rc=%u", req_w, req_h, req_scale, disp_ready ? 1 : 0, rc);
            shim_log(session, buf);
            if (rc != 0 && !disp_ready) {
                pthread_mutex_lock(&session->lock);
                session->resize_pending = true;
                pthread_mutex_unlock(&session->lock);
            }
        }
    }
    return 1;
}

void mio_rdp_disconnect(MioRdpSession* session) {
    if (!session || !session->instance) return;
    pthread_mutex_lock(&session->clip_lock);
    session->closing = true;
    pthread_cond_broadcast(&session->clip_cond);
    pthread_mutex_unlock(&session->clip_lock);
    g_fn.freerdp_disconnect(session->instance);
}

void mio_rdp_destroy(MioRdpSession* session) {
    if (!session) return;
    pthread_mutex_lock(&session->clip_lock);
    session->closing = true;
    pthread_cond_broadcast(&session->clip_cond);
    if (session->clip_file && session->cliprdr && g_fn.clip_file_uninit) {
        g_fn.clip_file_uninit(session->clip_file, session->cliprdr);
    }
    if (session->clip_file && g_fn.clip_file_free) {
        g_fn.clip_file_free(session->clip_file);
        session->clip_file = NULL;
    }
    if (session->clipboard && g_fn.clipboard_destroy) {
        g_fn.clipboard_destroy(session->clipboard);
        session->clipboard = NULL;
    }
    session->cliprdr = NULL;
    free(session->pending_response_data);
    session->pending_response_data = NULL;
    free(session->remote_fgd_cache);
    session->remote_fgd_cache = NULL;
    free(session->remote_text_cache);
    session->remote_text_cache = NULL;
    free(session->client_uri_list);
    session->client_uri_list = NULL;
    free(session->pending_file_data);
    session->pending_file_data = NULL;
    pthread_mutex_unlock(&session->clip_lock);

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
    pthread_cond_destroy(&session->clip_cond);
    pthread_mutex_destroy(&session->clip_lock);
    pthread_mutex_destroy(&session->lock);
    free(session);
}

void mio_rdp_resize(MioRdpSession* session, uint32_t width, uint32_t height, uint32_t scale_percent) {
    if (!session || !session->connected) return;
    uint32_t w = width < 200 ? 200 : (width > 8192 ? 8192 : width);
    uint32_t h = height < 200 ? 200 : (height > 8192 ? 8192 : height);
    w = (w + 1u) & ~1u;
    h = (h + 1u) & ~1u;
    uint32_t scale = (scale_percent >= 100 && scale_percent <= 500) ? scale_percent : 100;
    pthread_mutex_lock(&session->lock);
    session->pending_width = w;
    session->pending_height = h;
    session->pending_scale_percent = scale;
    session->resize_pending = true;
    pthread_mutex_unlock(&session->lock);
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

static uint8_t* request_remote_format_data(MioRdpSession* session, uint32_t format_id, uint32_t* out_size) {
    if (!session || !out_size) return NULL;
    *out_size = 0;

    pthread_mutex_lock(&session->clip_lock);
    if (session->closing || !session->clip_ready || !session->cliprdr) {
        pthread_mutex_unlock(&session->clip_lock);
        return NULL;
    }
    MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)session->cliprdr;
    if (!cliprdr->ClientFormatDataRequest) {
        pthread_mutex_unlock(&session->clip_lock);
        return NULL;
    }
    free(session->pending_response_data);
    session->pending_response_data = NULL;
    session->pending_response_size = 0;
    session->pending_response_ready = false;
    pthread_mutex_unlock(&session->clip_lock);

    MioCliprdrFormatDataRequest req = {0};
    req.common.msgType = MIO_CB_FORMAT_DATA_REQUEST;
    req.common.dataLen = 4;
    req.requestedFormatId = format_id;
    if (cliprdr->ClientFormatDataRequest(cliprdr, &req) != 0) {
        return NULL;
    }

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 4;

    pthread_mutex_lock(&session->clip_lock);
    while (!session->pending_response_ready && !session->closing) {
        int rc = pthread_cond_timedwait(&session->clip_cond, &session->clip_lock, &ts);
        if (rc == ETIMEDOUT) break;
    }
    uint8_t* result = session->pending_response_data;
    uint32_t size = session->pending_response_size;
    session->pending_response_data = NULL;
    session->pending_response_size = 0;
    session->pending_response_ready = false;
    pthread_mutex_unlock(&session->clip_lock);

    if (result && size > 0) {
        *out_size = size;
        return result;
    }
    free(result);
    return NULL;
}

bool mio_rdp_clipboard_send_text(MioRdpSession* session, const char* utf8_text) {
    if (!session || !utf8_text) return false;

    pthread_mutex_lock(&session->clip_lock);
    if (!session->clip_ready || !session->cliprdr || !session->clipboard ||
        !g_fn.clipboard_empty || !g_fn.clipboard_set_data || !g_fn.clipboard_get_format_id) {
        pthread_mutex_unlock(&session->clip_lock);
        return false;
    }
    MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)session->cliprdr;
    if (!cliprdr->ClientFormatList) {
        pthread_mutex_unlock(&session->clip_lock);
        return false;
    }
    if (session->clip_file && g_fn.clip_file_notify_new_client_format_list) {
        g_fn.clip_file_notify_new_client_format_list(session->clip_file);
    }
    free(session->client_uri_list);
    session->client_uri_list = NULL;
    g_fn.clipboard_empty(session->clipboard);
    uint32_t utf8_id = g_fn.clipboard_get_format_id(session->clipboard, "UTF8_STRING");
    g_fn.clipboard_set_data(session->clipboard, utf8_id, utf8_text, (uint32_t)(strlen(utf8_text) + 1));
    pthread_mutex_unlock(&session->clip_lock);

    MioCliprdrFormat formats[2] = {
        { .formatId = MIO_CF_UNICODETEXT, .formatName = NULL },
        { .formatId = MIO_CF_TEXT, .formatName = NULL }
    };
    MioCliprdrFormatList list = {0};
    list.common.msgType = MIO_CB_FORMAT_LIST;
    list.numFormats = 2;
    list.formats = formats;
    return cliprdr->ClientFormatList(cliprdr, &list) == 0;
}

bool mio_rdp_clipboard_send_files(MioRdpSession* session, const char* uri_list) {
    if (!session || !uri_list) return false;

    pthread_mutex_lock(&session->clip_lock);
    if (!session->clip_ready || !session->cliprdr || !session->clipboard || !session->clip_file ||
        !g_fn.clipboard_empty || !g_fn.clipboard_set_data || !g_fn.clipboard_get_format_id ||
        !g_fn.clip_file_update_client_data) {
        pthread_mutex_unlock(&session->clip_lock);
        return false;
    }
    MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)session->cliprdr;
    if (!cliprdr->ClientFormatList) {
        pthread_mutex_unlock(&session->clip_lock);
        return false;
    }

    size_t len = strlen(uri_list);
    char* uri_copy = strdup(uri_list);
    if (!uri_copy) {
        pthread_mutex_unlock(&session->clip_lock);
        return false;
    }
    if (g_fn.clip_file_notify_new_client_format_list) {
        g_fn.clip_file_notify_new_client_format_list(session->clip_file);
    }
    free(session->client_uri_list);
    session->client_uri_list = uri_copy;
    g_fn.clipboard_empty(session->clipboard);
    uint32_t uri_id = g_fn.clipboard_get_format_id(session->clipboard, "text/uri-list");
    g_fn.clipboard_set_data(session->clipboard, uri_id, uri_list, (uint32_t)(len + 1));
    uint32_t fgd_id = session->client_fgd_format_id;
    pthread_mutex_unlock(&session->clip_lock);

    MioCliprdrFormat formats[1] = {
        { .formatId = fgd_id, .formatName = "FileGroupDescriptorW" }
    };
    MioCliprdrFormatList list = {0};
    list.common.msgType = MIO_CB_FORMAT_LIST;
    list.numFormats = 1;
    list.formats = formats;
    RdpUInt32 rc = cliprdr->ClientFormatList(cliprdr, &list);
    char buf[160];
    snprintf(buf, sizeof(buf), "clipboard_send_files(len=%zu fgd=%u) -> rc=%u", len, fgd_id, rc);
    shim_log(session, buf);
    return rc == 0;
}

char* mio_rdp_clipboard_fetch_remote_text(MioRdpSession* session) {
    if (!session || !g_fn.clipboard_create || !g_fn.clipboard_destroy ||
        !g_fn.clipboard_set_data || !g_fn.clipboard_get_data || !g_fn.clipboard_get_format_id) {
        return NULL;
    }

    pthread_mutex_lock(&session->clip_lock);
    bool has_text = session->server_has_text;
    uint32_t fmt_id = session->server_text_format_id;
    pthread_mutex_unlock(&session->clip_lock);
    if (!has_text || fmt_id == 0) return NULL;

    uint32_t raw_size = 0;
    uint8_t* raw = request_remote_format_data(session, fmt_id, &raw_size);
    if (!raw || raw_size == 0) {
        free(raw);
        return NULL;
    }

    void* tmp = g_fn.clipboard_create();
    if (!tmp) {
        free(raw);
        return NULL;
    }
    g_fn.clipboard_set_data(tmp, fmt_id, raw, raw_size);
    free(raw);

    uint32_t utf8_id = g_fn.clipboard_get_format_id(tmp, "UTF8_STRING");
    uint32_t utf8_size = 0;
    char* utf8 = (char*)g_fn.clipboard_get_data(tmp, utf8_id, &utf8_size);
    g_fn.clipboard_destroy(tmp);

    if (!utf8 || utf8_size == 0) {
        free(utf8);
        return NULL;
    }
    char* out = (char*)malloc((size_t)utf8_size + 1);
    if (out) {
        memcpy(out, utf8, utf8_size);
        out[utf8_size] = '\0';
    }
    free(utf8);
    return out;
}

static const void* cb_remote_data_fkt(void* userdata, const char* mime_type, size_t* size) {
    MioRdpSession* session = (MioRdpSession*)userdata;
    if (!session || !mime_type || !size) return NULL;
    *size = 0;

    if (strcmp(mime_type, "FileGroupDescriptorW") == 0) {
        pthread_mutex_lock(&session->clip_lock);
        bool has_files = session->server_has_files;
        uint32_t fgd_fmt = session->server_fgd_format_id;
        pthread_mutex_unlock(&session->clip_lock);
        if (!has_files || fgd_fmt == 0) return NULL;

        uint32_t raw_size = 0;
        uint8_t* raw = request_remote_format_data(session, fgd_fmt, &raw_size);
        if (!raw || raw_size == 0) {
            free(raw);
            return NULL;
        }
        pthread_mutex_lock(&session->clip_lock);
        free(session->remote_fgd_cache);
        session->remote_fgd_cache = raw;
        session->remote_fgd_cache_size = raw_size;
        pthread_mutex_unlock(&session->clip_lock);
        *size = raw_size;
        return raw;
    }

    if (strcmp(mime_type, "text/plain;charset=utf-8") == 0 ||
        strcmp(mime_type, "text/plain") == 0 ||
        strcmp(mime_type, "UTF8_STRING") == 0) {
        char* text = mio_rdp_clipboard_fetch_remote_text(session);
        if (!text) return NULL;
        size_t len = strlen(text);
        pthread_mutex_lock(&session->clip_lock);
        free(session->remote_text_cache);
        session->remote_text_cache = (uint8_t*)text;
        session->remote_text_cache_size = len;
        pthread_mutex_unlock(&session->clip_lock);
        *size = len;
        return text;
    }

    return NULL;
}

bool mio_rdp_clipboard_publish_remote_files(MioRdpSession* session) {
    if (!session || !session->clip_file || !g_fn.clip_file_set_local_clipboard_data) return false;
    pthread_mutex_lock(&session->clip_lock);
    bool has_files = session->server_has_files;
    bool has_text = session->server_has_text;
    pthread_mutex_unlock(&session->clip_lock);
    if (!has_files) return false;

    const char* mimes[2];
    size_t count = 0;
    mimes[count++] = "text/uri-list";
    if (has_text) {
        mimes[count++] = "text/plain;charset=utf-8";
    }
    return g_fn.clip_file_set_local_clipboard_data(session->clip_file, cb_remote_data_fkt, session, mimes, count) != 0;
}

static bool decode_win_relpath(const uint16_t* wname, char* out, size_t out_cap) {
    if (!wname || !out || out_cap < 4) return false;
    size_t pos = 0;
    for (size_t i = 0; i < 260; i++) {
        uint16_t wc = wname[i];
        if (wc == 0) break;
        uint32_t cp = wc;
        if (wc >= 0xD800 && wc <= 0xDBFF && i + 1 < 260) {
            uint16_t low = wname[i + 1];
            if (low >= 0xDC00 && low <= 0xDFFF) {
                cp = 0x10000u + (((uint32_t)(wc - 0xD800u) << 10) | (uint32_t)(low - 0xDC00u));
                i++;
            }
        }
        if (cp == '\\') cp = '/';
        if (cp < 0x80) {
            if (pos + 1 >= out_cap) return false;
            out[pos++] = (char)cp;
        } else if (cp < 0x800) {
            if (pos + 2 >= out_cap) return false;
            out[pos++] = (char)(0xC0 | (cp >> 6));
            out[pos++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            if (pos + 3 >= out_cap) return false;
            out[pos++] = (char)(0xE0 | (cp >> 12));
            out[pos++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[pos++] = (char)(0x80 | (cp & 0x3F));
        } else {
            if (pos + 4 >= out_cap) return false;
            out[pos++] = (char)(0xF0 | (cp >> 18));
            out[pos++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[pos++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[pos++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    out[pos] = '\0';
    // 去掉前导斜杠并拒绝任何包含 ".." 的路径穿越片段
    char* start = out;
    while (*start == '/') start++;
    if (start != out) memmove(out, start, strlen(start) + 1);
    size_t len = strlen(out);
    while (len > 0 && out[len - 1] == '/') {
        out[--len] = '\0';
    }
    if (len == 0) return false;
    const char* p = out;
    while (*p) {
        const char* slash = strchr(p, '/');
        size_t seg_len = slash ? (size_t)(slash - p) : strlen(p);
        if (seg_len == 2 && p[0] == '.' && p[1] == '.') return false;
        if (!slash) break;
        p = slash + 1;
    }
    return true;
}

static bool mkdir_p(const char* path) {
    if (!path || !path[0]) return false;
    char tmp[2048];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return false;
    memcpy(tmp, path, len + 1);
    for (char* p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
    return true;
}

static uint8_t* request_remote_file_contents(
    MioRdpSession* session,
    uint64_t generation,
    uint32_t list_index,
    uint32_t flags,
    uint64_t offset,
    uint32_t cb_requested,
    bool have_lock,
    uint32_t lock_id,
    uint32_t* out_size,
    bool* out_ok
) {
    *out_size = 0;
    *out_ok = false;

    pthread_mutex_lock(&session->clip_lock);
    if (session->closing || !session->clip_ready || !session->cliprdr ||
        session->server_clip_generation != generation) {
        pthread_mutex_unlock(&session->clip_lock);
        return NULL;
    }
    MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)session->cliprdr;
    if (!cliprdr->ClientFileContentsRequest) {
        pthread_mutex_unlock(&session->clip_lock);
        return NULL;
    }
    uint32_t stream_id = ++session->next_file_stream_id;
    free(session->pending_file_data);
    session->pending_file_data = NULL;
    session->pending_file_size = 0;
    session->pending_file_stream_id = stream_id;
    session->pending_file_ready = false;
    session->pending_file_ok = false;
    pthread_mutex_unlock(&session->clip_lock);

    MioCliprdrFileContentsRequest req = {0};
    req.common.msgType = MIO_CB_FILECONTENTS_REQUEST;
    req.common.dataLen = have_lock ? 28u : 24u;
    req.streamId = stream_id;
    req.listIndex = list_index;
    req.dwFlags = flags;
    req.nPositionLow = (uint32_t)(offset & 0xFFFFFFFFu);
    req.nPositionHigh = (uint32_t)((offset >> 32) & 0xFFFFFFFFu);
    req.cbRequested = cb_requested;
    req.haveClipDataId = have_lock ? 1 : 0;
    req.clipDataId = have_lock ? lock_id : 0;
    RdpUInt32 send_rc = cliprdr->ClientFileContentsRequest(cliprdr, &req);
    if (send_rc != 0) {
        char buf[160];
        snprintf(buf, sizeof(buf), "ClientFileContentsRequest failed rc=%u idx=%u flags=0x%x cb=%u lock=%u",
                 send_rc, list_index, flags, cb_requested, lock_id);
        shim_log(session, buf);
        return NULL;
    }

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 10;

    bool timed_out = false;
    pthread_mutex_lock(&session->clip_lock);
    while (!session->pending_file_ready && !session->closing &&
           session->server_clip_generation == generation) {
        int rc = pthread_cond_timedwait(&session->clip_cond, &session->clip_lock, &ts);
        if (rc == ETIMEDOUT) {
            timed_out = true;
            break;
        }
    }
    bool ready = session->pending_file_ready && session->server_clip_generation == generation;
    bool ok = ready && session->pending_file_ok;
    uint8_t* data = ok ? session->pending_file_data : NULL;
    uint32_t size = ok ? session->pending_file_size : 0;
    if (!ok) {
        free(session->pending_file_data);
        char buf[192];
        snprintf(buf, sizeof(buf),
                 "FileContentsResponse failed idx=%u flags=0x%x offset=%llu cb=%u ready=%d ok=%d timeout=%d lock=%u",
                 list_index, flags, (unsigned long long)offset, cb_requested, ready ? 1 : 0,
                 session->pending_file_ok ? 1 : 0, timed_out ? 1 : 0, lock_id);
        shim_log(session, buf);
    }
    session->pending_file_data = NULL;
    session->pending_file_size = 0;
    session->pending_file_ready = false;
    session->pending_file_ok = false;
    pthread_mutex_unlock(&session->clip_lock);

    *out_ok = ok;
    *out_size = size;
    return data;
}

char* mio_rdp_clipboard_download_remote_files(MioRdpSession* session, const char* dest_dir, uint64_t max_total_bytes) {
    if (!session || !dest_dir || !dest_dir[0] || !g_fn.cliprdr_parse_file_list) return NULL;

    pthread_mutex_lock(&session->clip_lock);
    bool has_files = session->server_has_files;
    uint32_t fgd_fmt = session->server_fgd_format_id;
    uint64_t generation = session->server_clip_generation;
    uint32_t server_caps = session->server_clip_caps;
    MioCliprdrClientContext* cliprdr = (MioCliprdrClientContext*)session->cliprdr;
    uint32_t lock_id = 0;
    bool have_lock = false;
    if (has_files && fgd_fmt != 0 && cliprdr &&
        (server_caps & MIO_CB_CAN_LOCK_CLIPDATA) != 0 &&
        cliprdr->ClientLockClipboardData && cliprdr->ClientUnlockClipboardData) {
        lock_id = ++session->next_client_lock_id;
        if (lock_id == 0) lock_id = ++session->next_client_lock_id;
        have_lock = true;
    }
    pthread_mutex_unlock(&session->clip_lock);
    if (!has_files || fgd_fmt == 0) return NULL;

    if (have_lock) {
        MioCliprdrLockClipboardData lock_req = {0};
        lock_req.common.msgType = MIO_CB_LOCK_CLIPDATA;
        lock_req.common.dataLen = 4;
        lock_req.clipDataId = lock_id;
        if (cliprdr->ClientLockClipboardData(cliprdr, &lock_req) != 0) {
            have_lock = false;
            lock_id = 0;
        }
    }

    uint32_t raw_size = 0;
    uint8_t* raw = request_remote_format_data(session, fgd_fmt, &raw_size);
    if (!raw || raw_size == 0) {
        free(raw);
        if (have_lock) {
            MioCliprdrLockClipboardData unlock_req = {0};
            unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
            unlock_req.common.dataLen = 4;
            unlock_req.clipDataId = lock_id;
            cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
        }
        return NULL;
    }

    void* descs_raw = NULL;
    RdpUInt32 count = 0;
    RdpUInt32 parse_rc = g_fn.cliprdr_parse_file_list(raw, raw_size, &descs_raw, &count);
    free(raw);
    if (parse_rc != 0 || !descs_raw || count == 0) {
        free(descs_raw);
        if (have_lock) {
            MioCliprdrLockClipboardData unlock_req = {0};
            unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
            unlock_req.common.dataLen = 4;
            unlock_req.clipDataId = lock_id;
            cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
        }
        return NULL;
    }

    const MioFileDescriptorW* descs = (const MioFileDescriptorW*)descs_raw;
    if (max_total_bytes > 0) {
        uint64_t declared_total = 0;
        for (RdpUInt32 i = 0; i < count; i++) {
            if ((descs[i].dwFileAttributes & MIO_FILE_ATTRIBUTE_DIRECTORY) == 0 &&
                (descs[i].dwFlags & MIO_FD_FILESIZE) != 0) {
                uint64_t sz = ((uint64_t)descs[i].nFileSizeHigh << 32) | (uint64_t)descs[i].nFileSizeLow;
                if (sz > max_total_bytes || declared_total > max_total_bytes - sz) {
                    char buf[160];
                    snprintf(buf, sizeof(buf), "clipboard_download_remote_files skipped: exceeds max_total_bytes=%llu",
                             (unsigned long long)max_total_bytes);
                    shim_log(session, buf);
                    free(descs_raw);
                    if (have_lock) {
                        MioCliprdrLockClipboardData unlock_req = {0};
                        unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
                        unlock_req.common.dataLen = 4;
                        unlock_req.clipDataId = lock_id;
                        cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
                    }
                    return NULL;
                }
                declared_total += sz;
            }
        }
    }

    if (!mkdir_p(dest_dir)) {
        free(descs_raw);
        if (have_lock) {
            MioCliprdrLockClipboardData unlock_req = {0};
            unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
            unlock_req.common.dataLen = 4;
            unlock_req.clipDataId = lock_id;
            cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
        }
        return NULL;
    }

    size_t out_cap = 1024;
    size_t out_len = 0;
    char* top_paths = (char*)malloc(out_cap);
    if (!top_paths) {
        free(descs_raw);
        if (have_lock) {
            MioCliprdrLockClipboardData unlock_req = {0};
            unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
            unlock_req.common.dataLen = 4;
            unlock_req.clipDataId = lock_id;
            cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
        }
        return NULL;
    }
    top_paths[0] = '\0';

    uint64_t downloaded_total = 0;
    bool all_ok = true;
    const char* fail_step = "none";

    for (RdpUInt32 i = 0; i < count; i++) {
        pthread_mutex_lock(&session->clip_lock);
        bool cancelled = session->closing || session->server_clip_generation != generation;
        pthread_mutex_unlock(&session->clip_lock);
        if (cancelled) {
            fail_step = "cancelled";
            all_ok = false;
            break;
        }

        char rel_path[1024];
        if (!decode_win_relpath(descs[i].cFileName, rel_path, sizeof(rel_path))) {
            fail_step = "decode_path";
            all_ok = false;
            break;
        }

        char full_path[2048];
        int n = snprintf(full_path, sizeof(full_path), "%s/%s", dest_dir, rel_path);
        if (n <= 0 || (size_t)n >= sizeof(full_path)) {
            fail_step = "path_len";
            all_ok = false;
            break;
        }

        // 记录顶层文件/目录路径（去重）
        char top_entry[2048];
        const char* first_slash = strchr(rel_path, '/');
        size_t top_seg_len = first_slash ? (size_t)(first_slash - rel_path) : strlen(rel_path);
        int tn = snprintf(top_entry, sizeof(top_entry), "%s/%.*s\n", dest_dir, (int)top_seg_len, rel_path);
        if (tn > 0 && (size_t)tn < sizeof(top_entry)) {
            bool exists = false;
            const char* cursor = top_paths;
            while (*cursor) {
                const char* nl = strchr(cursor, '\n');
                size_t line_len = nl ? (size_t)(nl - cursor + 1) : strlen(cursor);
                if (line_len == (size_t)tn && memcmp(cursor, top_entry, line_len) == 0) {
                    exists = true;
                    break;
                }
                if (!nl) break;
                cursor = nl + 1;
            }
            if (!exists) {
                if (out_len + (size_t)tn + 1 > out_cap) {
                    size_t next_cap = (out_cap + (size_t)tn + 1) * 2;
                    char* grown = (char*)realloc(top_paths, next_cap);
                    if (!grown) {
                        fail_step = "oom";
                        all_ok = false;
                        break;
                    }
                    top_paths = grown;
                    out_cap = next_cap;
                }
                memcpy(top_paths + out_len, top_entry, (size_t)tn + 1);
                out_len += (size_t)tn;
            }
        }

        if ((descs[i].dwFileAttributes & MIO_FILE_ATTRIBUTE_DIRECTORY) != 0) {
            if (!mkdir_p(full_path)) {
                fail_step = "mkdir_entry";
                all_ok = false;
                break;
            }
            continue;
        }

        // 确保父目录存在
        char* last_slash = strrchr(full_path, '/');
        if (last_slash && last_slash != full_path) {
            *last_slash = '\0';
            bool dir_ok = mkdir_p(full_path);
            *last_slash = '/';
            if (!dir_ok) {
                fail_step = "mkdir_parent";
                all_ok = false;
                break;
            }
        }

        uint64_t file_size = 0;
        if ((descs[i].dwFlags & MIO_FD_FILESIZE) != 0) {
            file_size = ((uint64_t)descs[i].nFileSizeHigh << 32) | (uint64_t)descs[i].nFileSizeLow;
        } else {
            uint32_t sz_bytes = 0;
            bool sz_ok = false;
            uint8_t* sz_buf = request_remote_file_contents(
                session, generation, i, MIO_FILECONTENTS_SIZE, 0, 8, have_lock, lock_id, &sz_bytes, &sz_ok
            );
            if (!sz_ok || !sz_buf || sz_bytes < 8) {
                free(sz_buf);
                fail_step = "file_size";
                all_ok = false;
                break;
            }
            for (int b = 0; b < 8; b++) {
                file_size |= ((uint64_t)sz_buf[b]) << (8 * b);
            }
            free(sz_buf);
        }

        if (max_total_bytes > 0 && (file_size > max_total_bytes || downloaded_total > max_total_bytes - file_size)) {
            fail_step = "max_bytes";
            all_ok = false;
            break;
        }

        FILE* fp = fopen(full_path, "wb");
        if (!fp) {
            fail_step = "fopen";
            all_ok = false;
            break;
        }

        uint64_t offset = 0;
        const uint32_t chunk_size = 65536u;
        while (offset < file_size) {
            uint64_t remaining = file_size - offset;
            uint32_t to_read = remaining > chunk_size ? chunk_size : (uint32_t)remaining;
            uint32_t got = 0;
            bool chunk_ok = false;
            uint8_t* chunk = request_remote_file_contents(
                session, generation, i, MIO_FILECONTENTS_RANGE, offset, to_read, have_lock, lock_id, &got, &chunk_ok
            );
            if (!chunk_ok || !chunk || got == 0) {
                free(chunk);
                fail_step = "file_range";
                all_ok = false;
                break;
            }
            size_t written = fwrite(chunk, 1, got, fp);
            free(chunk);
            if (written != got) {
                fail_step = "fwrite";
                all_ok = false;
                break;
            }
            offset += got;
            downloaded_total += got;
        }
        fclose(fp);
        if (!all_ok) break;
    }

    free(descs_raw);
    if (have_lock) {
        MioCliprdrLockClipboardData unlock_req = {0};
        unlock_req.common.msgType = MIO_CB_UNLOCK_CLIPDATA;
        unlock_req.common.dataLen = 4;
        unlock_req.clipDataId = lock_id;
        cliprdr->ClientUnlockClipboardData(cliprdr, &unlock_req);
    }

    char log_buf[192];
    snprintf(log_buf, sizeof(log_buf), "clipboard_download_remote_files(count=%u bytes=%llu lock=%u step=%s) -> %s",
             count, (unsigned long long)downloaded_total, lock_id, fail_step, all_ok ? "ok" : "fail");
    shim_log(session, log_buf);

    if (!all_ok || out_len == 0) {
        free(top_paths);
        return NULL;
    }
    return top_paths;
}

void mio_rdp_free_string(char* str) {
    free(str);
}
