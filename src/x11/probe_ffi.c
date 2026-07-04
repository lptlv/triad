#include <stdarg.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <xcb/randr.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>
#include <xcb/xcb_ewmh.h>
#include <xcb/xinput.h>
#include <xcb/xkb.h>

typedef void (*triad_x11_log_fn)(void *user_data, const char *message);

typedef enum TriadX11RequestKind {
    TRIAD_X11_REQUEST_CONFIGURE_WINDOW = 0,
    TRIAD_X11_REQUEST_SET_INPUT_FOCUS = 1,
    TRIAD_X11_REQUEST_SEND_CLOSE_WINDOW = 2,
    TRIAD_X11_REQUEST_MAP_WINDOW = 3,
    TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE = 4,
    TRIAD_X11_REQUEST_SET_MAXIMIZED_STATE = 5,
    TRIAD_X11_REQUEST_SET_HIDDEN_STATE = 6,
    TRIAD_X11_REQUEST_UNMAP_WINDOW = 7,
} TriadX11RequestKind;

typedef struct TriadX11Request {
    TriadX11RequestKind kind;
    uint32_t window_id;
    uint32_t value_mask;
    uint32_t value_count;
    int32_t values[4];
} TriadX11Request;

typedef enum TriadX11EventKind {
    TRIAD_X11_EVENT_WINDOW_DISCOVERED = 0,
    TRIAD_X11_EVENT_WINDOW_DESTROYED = 1,
    TRIAD_X11_EVENT_WINDOW_UNMAPPED = 2,
    TRIAD_X11_EVENT_OUTPUT_DISCOVERED = 3,
    TRIAD_X11_EVENT_CONFIGURE_REQUESTED = 4,
    TRIAD_X11_EVENT_PROPERTY_CHANGED = 5,
    TRIAD_X11_EVENT_FOCUS_CHANGED = 6,
    TRIAD_X11_EVENT_POINTER_ENTERED = 7,
    TRIAD_X11_EVENT_RANDR_CHANGED = 8,
    TRIAD_X11_EVENT_MAP_REQUESTED = 9,
    TRIAD_X11_EVENT_KEY_BINDING = 10,
    TRIAD_X11_EVENT_POINTER_BINDING = 11,
    TRIAD_X11_EVENT_AXIS_BINDING = 12,
    TRIAD_X11_EVENT_POINTER_MOTION = 13,
    TRIAD_X11_EVENT_POINTER_RELEASE = 14,
    TRIAD_X11_EVENT_MAPPING_CHANGED = 15,
    TRIAD_X11_EVENT_XKB_CHANGED = 16,
} TriadX11EventKind;

typedef struct TriadX11Event {
    TriadX11EventKind kind;
    uint32_t id;
    uint32_t parent_id;
    int32_t pid;
    int32_t x;
    int32_t y;
    int32_t w;
    int32_t h;
    uint32_t value_mask;
    uint32_t sibling;
    uint32_t stack_mode;
    uint32_t root;
    uint8_t override_redirect;
    uint8_t mapped;
    uint8_t connected;
    uint8_t focused;
    char name[256];
    char title[512];
} TriadX11Event;

typedef struct TriadX11KeyGrab {
    uint32_t keysym;
    uint32_t modifiers;
    char binding[128];
} TriadX11KeyGrab;

typedef struct TriadX11ResolvedKeysym {
    xcb_keycode_t keycode;
    uint32_t modifiers;
} TriadX11ResolvedKeysym;

typedef struct TriadX11ButtonGrab {
    uint32_t button;
    uint32_t modifiers;
    char binding[128];
} TriadX11ButtonGrab;

typedef struct TriadX11AxisGrab {
    uint32_t button;
    uint32_t modifiers;
    char binding[128];
} TriadX11AxisGrab;

typedef struct TriadX11ResolvedKeyGrab {
    uint32_t keysym;
    uint32_t modifiers;
    xcb_keycode_t keycode;
    char binding[128];
} TriadX11ResolvedKeyGrab;

typedef struct TriadX11ResolvedButtonGrab {
    uint32_t button;
    uint32_t modifiers;
    char binding[128];
} TriadX11ResolvedButtonGrab;

typedef struct TriadX11ResolvedAxisGrab {
    uint32_t button;
    uint32_t modifiers;
    char binding[128];
} TriadX11ResolvedAxisGrab;

typedef void (*triad_x11_event_fn)(void *user_data, const TriadX11Event *event);
typedef void (*triad_x11_tick_fn)(void *user_data);

typedef struct TriadX11Atoms {
    xcb_atom_t wm_protocols;
    xcb_atom_t wm_delete_window;
    xcb_atom_t wm_class;
    xcb_atom_t wm_name;
    xcb_atom_t net_wm_name;
    xcb_atom_t net_wm_pid;
    xcb_atom_t net_wm_state;
    xcb_atom_t net_wm_state_fullscreen;
    xcb_atom_t net_wm_state_maximized_horz;
    xcb_atom_t net_wm_state_maximized_vert;
    xcb_atom_t net_wm_state_hidden;
    xcb_atom_t net_wm_state_demands_attention;
    xcb_atom_t net_wm_window_type;
    xcb_atom_t net_supported;
    xcb_atom_t net_supporting_wm_check;
    xcb_atom_t utf8_string;
    xcb_atom_t cardinal;
    xcb_atom_t window;
    xcb_atom_t wm_selection;
} TriadX11Atoms;

typedef struct TriadX11Probe {
    xcb_connection_t *conn;
    const xcb_setup_t *setup;
    xcb_screen_t *screen;
    int screen_number;
    xcb_window_t owner_window;
    xcb_ewmh_connection_t ewmh;
    int ewmh_ready;
    const xcb_query_extension_reply_t *randr_ext;
    const xcb_query_extension_reply_t *xinput_ext;
    const xcb_query_extension_reply_t *xkb_ext;
    uint32_t ignored_lock_modifiers;
    int stop_requested;
    TriadX11ResolvedKeyGrab *key_grabs;
    uint32_t key_grab_count;
    TriadX11ResolvedButtonGrab *button_grabs;
    uint32_t button_grab_count;
    TriadX11ResolvedAxisGrab *axis_grabs;
    uint32_t axis_grab_count;
    xcb_window_t *suppressed_unmaps;
    uint32_t suppressed_unmap_count;
    uint32_t suppressed_unmap_capacity;
    TriadX11Atoms atoms;
    triad_x11_log_fn log;
    triad_x11_event_fn event;
    void *log_user_data;
} TriadX11Probe;

static TriadX11Probe *active_probe = NULL;

static int suppress_unmap_notify(TriadX11Probe *probe, xcb_window_t window)
{
    if (probe == NULL || window == XCB_WINDOW_NONE)
        return 0;
    for (uint32_t i = 0; i < probe->suppressed_unmap_count; i++) {
        if (probe->suppressed_unmaps[i] == window)
            return 1;
    }
    if (probe->suppressed_unmap_count == probe->suppressed_unmap_capacity) {
        uint32_t next_capacity =
            probe->suppressed_unmap_capacity == 0 ? 8 : probe->suppressed_unmap_capacity * 2;
        xcb_window_t *next = realloc(
            probe->suppressed_unmaps, (size_t)next_capacity * sizeof(xcb_window_t));
        if (next == NULL)
            return 0;
        probe->suppressed_unmaps = next;
        probe->suppressed_unmap_capacity = next_capacity;
    }
    probe->suppressed_unmaps[probe->suppressed_unmap_count++] = window;
    return 1;
}

static int take_suppressed_unmap_notify(TriadX11Probe *probe, xcb_window_t window)
{
    if (probe == NULL || window == XCB_WINDOW_NONE)
        return 0;
    for (uint32_t i = 0; i < probe->suppressed_unmap_count; i++) {
        if (probe->suppressed_unmaps[i] != window)
            continue;
        probe->suppressed_unmap_count--;
        probe->suppressed_unmaps[i] = probe->suppressed_unmaps[probe->suppressed_unmap_count];
        return 1;
    }
    return 0;
}

static void clear_suppressed_unmaps(TriadX11Probe *probe)
{
    if (probe == NULL)
        return;
    free(probe->suppressed_unmaps);
    probe->suppressed_unmaps = NULL;
    probe->suppressed_unmap_count = 0;
    probe->suppressed_unmap_capacity = 0;
}

#define TRIAD_XK_NUM_LOCK 0xff7f
#define TRIAD_XK_SCROLL_LOCK 0xff14
#define TRIAD_X11_MAX_GRAB_VARIANTS 256

static void probe_log(TriadX11Probe *probe, const char *fmt, ...)
{
    char buffer[1024];
    va_list args;

    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    if (probe->log != NULL)
        probe->log(probe->log_user_data, buffer);
}

static void copy_text(char *dst, size_t dst_len, const char *src)
{
    if (dst_len == 0)
        return;
    dst[0] = '\0';
    if (src == NULL)
        return;
    snprintf(dst, dst_len, "%s", src);
}

static void probe_event(TriadX11Probe *probe, const TriadX11Event *event)
{
    if (probe->event != NULL) {
        TriadX11Probe *previous = active_probe;
        active_probe = probe;
        probe->event(probe->log_user_data, event);
        active_probe = previous;
    }
}

static void request_log(
    triad_x11_log_fn log_fn, void *user_data, const char *fmt, ...)
{
    char buffer[1024];
    va_list args;

    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    if (log_fn != NULL)
        log_fn(user_data, buffer);
}

static xcb_screen_t *screen_for_number(const xcb_setup_t *setup, int screen_number)
{
    xcb_screen_iterator_t iter = xcb_setup_roots_iterator(setup);
    for (int i = 0; iter.rem > 0; i++, xcb_screen_next(&iter)) {
        if (i == screen_number)
            return iter.data;
    }
    return NULL;
}

static xcb_atom_t intern_atom(TriadX11Probe *probe, const char *name, int only_if_exists)
{
    xcb_intern_atom_cookie_t cookie =
        xcb_intern_atom(probe->conn, only_if_exists, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *reply =
        xcb_intern_atom_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return XCB_ATOM_NONE;
    xcb_atom_t atom = reply->atom;
    free(reply);
    return atom;
}

static const char *event_name(uint8_t response_type)
{
    switch (response_type) {
    case XCB_MAP_REQUEST:
        return "MapRequest";
    case XCB_KEY_PRESS:
        return "KeyPress";
    case XCB_KEY_RELEASE:
        return "KeyRelease";
    case XCB_BUTTON_PRESS:
        return "ButtonPress";
    case XCB_BUTTON_RELEASE:
        return "ButtonRelease";
    case XCB_MOTION_NOTIFY:
        return "MotionNotify";
    case XCB_UNMAP_NOTIFY:
        return "UnmapNotify";
    case XCB_DESTROY_NOTIFY:
        return "DestroyNotify";
    case XCB_CONFIGURE_REQUEST:
        return "ConfigureRequest";
    case XCB_CONFIGURE_NOTIFY:
        return "ConfigureNotify";
    case XCB_PROPERTY_NOTIFY:
        return "PropertyNotify";
    case XCB_FOCUS_IN:
        return "FocusIn";
    case XCB_FOCUS_OUT:
        return "FocusOut";
    case XCB_ENTER_NOTIFY:
        return "EnterNotify";
    case XCB_CLIENT_MESSAGE:
        return "ClientMessage";
    case XCB_MAPPING_NOTIFY:
        return "MappingNotify";
    default:
        return "Unknown";
    }
}

static const char *xkb_event_name(uint8_t xkb_type)
{
    switch (xkb_type) {
    case XCB_XKB_NEW_KEYBOARD_NOTIFY:
        return "XkbNewKeyboardNotify";
    case XCB_XKB_MAP_NOTIFY:
        return "XkbMapNotify";
    case XCB_XKB_STATE_NOTIFY:
        return "XkbStateNotify";
    default:
        return "XkbUnknown";
    }
}

static char *atom_name(TriadX11Probe *probe, xcb_atom_t atom)
{
    if (atom == XCB_ATOM_NONE)
        return strdup("NONE");

    xcb_get_atom_name_cookie_t cookie = xcb_get_atom_name(probe->conn, atom);
    xcb_get_atom_name_reply_t *reply =
        xcb_get_atom_name_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return strdup("unknown");

    int len = xcb_get_atom_name_name_length(reply);
    char *name = calloc((size_t)len + 1, 1);
    if (name != NULL)
        memcpy(name, xcb_get_atom_name_name(reply), (size_t)len);
    free(reply);
    return name != NULL ? name : strdup("unknown");
}

static char *property_string(
    TriadX11Probe *probe, xcb_window_t win, xcb_atom_t property, xcb_atom_t type)
{
    xcb_get_property_cookie_t cookie =
        xcb_get_property(probe->conn, 0, win, property, type, 0, 4096);
    xcb_get_property_reply_t *reply =
        xcb_get_property_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return NULL;

    int len = xcb_get_property_value_length(reply);
    if (len <= 0) {
        free(reply);
        return NULL;
    }

    char *value = calloc((size_t)len + 1, 1);
    if (value != NULL)
        memcpy(value, xcb_get_property_value(reply), (size_t)len);
    free(reply);
    return value;
}

static char *window_title(TriadX11Probe *probe, xcb_window_t win)
{
    char *title =
        property_string(probe, win, probe->atoms.net_wm_name, probe->atoms.utf8_string);
    if (title != NULL)
        return title;
    return property_string(probe, win, XCB_ATOM_WM_NAME, XCB_ATOM_STRING);
}

static char *window_class(TriadX11Probe *probe, xcb_window_t win)
{
    xcb_get_property_cookie_t cookie = xcb_icccm_get_wm_class(probe->conn, win);
    xcb_icccm_get_wm_class_reply_t reply;
    memset(&reply, 0, sizeof(reply));
    if (!xcb_icccm_get_wm_class_reply(probe->conn, cookie, &reply, NULL))
        return NULL;

    const char *instance = reply.instance_name != NULL ? reply.instance_name : "";
    const char *class_name = reply.class_name != NULL ? reply.class_name : "";
    size_t len = strlen(instance) + strlen(class_name) + 2;
    char *result = calloc(len, 1);
    if (result != NULL)
        snprintf(result, len, "%s/%s", instance, class_name);
    xcb_icccm_get_wm_class_reply_wipe(&reply);
    return result;
}

static uint32_t window_pid(TriadX11Probe *probe, xcb_window_t win)
{
    xcb_get_property_cookie_t cookie = xcb_get_property(
        probe->conn, 0, win, probe->atoms.net_wm_pid, XCB_ATOM_CARDINAL, 0, 1);
    xcb_get_property_reply_t *reply =
        xcb_get_property_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return 0;
    uint32_t pid = 0;
    if (xcb_get_property_value_length(reply) >= 4)
        pid = *((uint32_t *)xcb_get_property_value(reply));
    free(reply);
    return pid;
}

static char *window_state_atoms(TriadX11Probe *probe, xcb_window_t win)
{
    xcb_get_property_cookie_t cookie = xcb_get_property(
        probe->conn, 0, win, probe->atoms.net_wm_state, XCB_ATOM_ATOM, 0, 64);
    xcb_get_property_reply_t *reply =
        xcb_get_property_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return NULL;

    int len = xcb_get_property_value_length(reply) / (int)sizeof(xcb_atom_t);
    xcb_atom_t *atoms = xcb_get_property_value(reply);
    char *result = calloc(512, 1);
    if (result == NULL) {
        free(reply);
        return NULL;
    }

    size_t used = 0;
    for (int i = 0; i < len && used + 1 < 512; i++) {
        char *name = atom_name(probe, atoms[i]);
        if (name == NULL)
            continue;
        int written = snprintf(
            result + used,
            512 - used,
            "%s%s",
            used > 0 ? " " : "",
            name);
        free(name);
        if (written < 0)
            break;
        if ((size_t)written >= 512 - used) {
            used = 511;
            break;
        }
        used += (size_t)written;
    }

    free(reply);
    return result;
}

static int select_window_events(TriadX11Probe *probe, xcb_window_t win)
{
    uint32_t mask =
        XCB_EVENT_MASK_PROPERTY_CHANGE |
        XCB_EVENT_MASK_STRUCTURE_NOTIFY |
        XCB_EVENT_MASK_FOCUS_CHANGE |
        XCB_EVENT_MASK_ENTER_WINDOW;
    xcb_void_cookie_t cookie =
        xcb_change_window_attributes_checked(
            probe->conn, win, XCB_CW_EVENT_MASK, &mask);
    xcb_generic_error_t *error = xcb_request_check(probe->conn, cookie);
    if (error != NULL) {
        free(error);
        return 0;
    }
    return 1;
}

static uint32_t modifier_mask_for_index(int index)
{
    switch (index) {
    case 0:
        return XCB_MOD_MASK_SHIFT;
    case 1:
        return XCB_MOD_MASK_LOCK;
    case 2:
        return XCB_MOD_MASK_CONTROL;
    case 3:
        return XCB_MOD_MASK_1;
    case 4:
        return XCB_MOD_MASK_2;
    case 5:
        return XCB_MOD_MASK_3;
    case 6:
        return XCB_MOD_MASK_4;
    case 7:
        return XCB_MOD_MASK_5;
    default:
        return 0;
    }
}

static int keyboard_mapping_has_keysym(
    xcb_get_keyboard_mapping_reply_t *reply,
    xcb_keycode_t min_keycode,
    xcb_keycode_t max_keycode,
    xcb_keycode_t keycode,
    uint32_t keysym)
{
    if (reply == NULL || keycode < min_keycode || keycode > max_keycode)
        return 0;

    const xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
    int per_keycode = reply->keysyms_per_keycode;
    int offset = (keycode - min_keycode) * per_keycode;
    for (int level = 0; level < per_keycode; level++) {
        if (keysyms[offset + level] == keysym)
            return 1;
    }
    return 0;
}

static void detect_ignored_lock_modifiers(TriadX11Probe *probe)
{
    uint32_t ignored = XCB_MOD_MASK_LOCK;
    uint32_t num_lock_mask = 0;
    uint32_t scroll_lock_mask = 0;
    xcb_keycode_t min_keycode = probe->setup->min_keycode;
    xcb_keycode_t max_keycode = probe->setup->max_keycode;
    uint8_t keycode_count = (uint8_t)(max_keycode - min_keycode + 1);

    xcb_get_modifier_mapping_cookie_t mod_cookie = xcb_get_modifier_mapping(probe->conn);
    xcb_get_keyboard_mapping_cookie_t key_cookie =
        xcb_get_keyboard_mapping(probe->conn, min_keycode, keycode_count);
    xcb_get_modifier_mapping_reply_t *mod_reply =
        xcb_get_modifier_mapping_reply(probe->conn, mod_cookie, NULL);
    xcb_get_keyboard_mapping_reply_t *key_reply =
        xcb_get_keyboard_mapping_reply(probe->conn, key_cookie, NULL);

    if (mod_reply == NULL || key_reply == NULL) {
        probe->ignored_lock_modifiers = ignored;
        probe_log(
            probe,
            "x11 ignored lock modifiers mask=0x%04x detection=unavailable",
            ignored);
        free(mod_reply);
        free(key_reply);
        return;
    }

    xcb_keycode_t *keycodes = xcb_get_modifier_mapping_keycodes(mod_reply);
    int per_modifier = mod_reply->keycodes_per_modifier;
    for (int mod_index = 0; mod_index < 8; mod_index++) {
        uint32_t modifier_mask = modifier_mask_for_index(mod_index);
        if (modifier_mask == 0)
            continue;
        for (int slot = 0; slot < per_modifier; slot++) {
            xcb_keycode_t keycode = keycodes[mod_index * per_modifier + slot];
            if (keycode == 0)
                continue;
            if (keyboard_mapping_has_keysym(
                    key_reply,
                    min_keycode,
                    max_keycode,
                    keycode,
                    TRIAD_XK_NUM_LOCK)) {
                num_lock_mask |= modifier_mask;
                ignored |= modifier_mask;
            }
            if (keyboard_mapping_has_keysym(
                    key_reply,
                    min_keycode,
                    max_keycode,
                    keycode,
                    TRIAD_XK_SCROLL_LOCK)) {
                scroll_lock_mask |= modifier_mask;
                ignored |= modifier_mask;
            }
        }
    }

    probe->ignored_lock_modifiers = ignored;
    probe_log(
        probe,
        "x11 ignored lock modifiers mask=0x%04x num_lock=0x%04x scroll_lock=0x%04x",
        ignored,
        num_lock_mask,
        scroll_lock_mask);
    free(mod_reply);
    free(key_reply);
}

static int append_unique_variant(
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS],
    size_t *count,
    uint32_t variant)
{
    for (size_t i = 0; i < *count; i++) {
        if (variants[i] == variant)
            return 1;
    }
    if (*count >= TRIAD_X11_MAX_GRAB_VARIANTS)
        return 0;
    variants[*count] = variant;
    (*count)++;
    return 1;
}

static size_t grab_modifier_variants(
    TriadX11Probe *probe,
    uint32_t modifiers,
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS])
{
    size_t ignored_count = 0;
    uint32_t ignored_bits[8];
    for (int mod_index = 0; mod_index < 8; mod_index++) {
        uint32_t modifier_mask = modifier_mask_for_index(mod_index);
        if ((probe->ignored_lock_modifiers & modifier_mask) != 0)
            ignored_bits[ignored_count++] = modifier_mask;
    }

    size_t variant_count = 0;
    size_t combo_count = ((size_t)1) << ignored_count;
    for (size_t combo = 0; combo < combo_count; combo++) {
        uint32_t variant = modifiers;
        for (size_t bit = 0; bit < ignored_count; bit++) {
            if ((combo & (((size_t)1) << bit)) != 0)
                variant |= ignored_bits[bit];
        }
        if (!append_unique_variant(variants, &variant_count, variant))
            break;
    }
    return variant_count;
}

static uint32_t binding_modifier_mask(TriadX11Probe *probe, uint32_t state)
{
    uint32_t binding_modifiers =
        XCB_MOD_MASK_SHIFT |
        XCB_MOD_MASK_CONTROL |
        XCB_MOD_MASK_1 |
        XCB_MOD_MASK_2 |
        XCB_MOD_MASK_3 |
        XCB_MOD_MASK_4 |
        XCB_MOD_MASK_5;
    return (state & binding_modifiers) & ~probe->ignored_lock_modifiers;
}

static TriadX11ResolvedKeysym resolved_key_for_keysym(
    TriadX11Probe *probe,
    uint32_t keysym)
{
    TriadX11ResolvedKeysym result = {0, 0};
    xcb_keycode_t min_keycode = probe->setup->min_keycode;
    xcb_keycode_t max_keycode = probe->setup->max_keycode;
    uint8_t count = (uint8_t)(max_keycode - min_keycode + 1);
    xcb_get_keyboard_mapping_cookie_t cookie =
        xcb_get_keyboard_mapping(probe->conn, min_keycode, count);
    xcb_get_keyboard_mapping_reply_t *reply =
        xcb_get_keyboard_mapping_reply(probe->conn, cookie, NULL);
    if (reply == NULL)
        return result;

    xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
    int per_keycode = reply->keysyms_per_keycode;
    for (uint16_t keycode = min_keycode; keycode <= max_keycode && result.keycode == 0; keycode++) {
        int offset = (keycode - min_keycode) * per_keycode;
        for (int level = 0; level < per_keycode; level++) {
            if (keysyms[offset + level] == keysym) {
                result.keycode = (xcb_keycode_t)keycode;
                if ((level % 2) == 1)
                    result.modifiers |= XCB_MOD_MASK_SHIFT;
                break;
            }
        }
    }

    free(reply);
    return result;
}

static void ungrab_key_variants(
    TriadX11Probe *probe,
    xcb_keycode_t keycode,
    uint32_t modifiers)
{
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS];
    size_t variant_count = grab_modifier_variants(probe, modifiers, variants);
    for (size_t i = 0; i < variant_count; i++)
        xcb_ungrab_key(probe->conn, keycode, probe->screen->root, (uint16_t)variants[i]);
}

static int grab_key_variants(
    TriadX11Probe *probe,
    xcb_keycode_t keycode,
    uint32_t modifiers,
    const char *binding)
{
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS];
    size_t variant_count = grab_modifier_variants(probe, modifiers, variants);
    int ok = 1;
    for (size_t i = 0; i < variant_count; i++) {
        xcb_void_cookie_t cookie = xcb_grab_key_checked(
            probe->conn,
            1,
            probe->screen->root,
            (uint16_t)variants[i],
            keycode,
            XCB_GRAB_MODE_ASYNC,
            XCB_GRAB_MODE_ASYNC);
        xcb_generic_error_t *error = xcb_request_check(probe->conn, cookie);
        if (error != NULL) {
            probe_log(
                probe,
                "key grab failed binding=\"%s\" keycode=%u modifiers=0x%04x error_code=%u",
                binding,
                keycode,
                variants[i],
                error->error_code);
            free(error);
            ok = 0;
        }
    }
    return ok;
}

static const TriadX11ResolvedKeyGrab *key_grab_for_event(
    TriadX11Probe *probe,
    xcb_keycode_t keycode,
    uint32_t state)
{
    uint32_t modifiers = binding_modifier_mask(probe, state);
    for (uint32_t i = 0; i < probe->key_grab_count; i++) {
        TriadX11ResolvedKeyGrab *grab = &probe->key_grabs[i];
        if (grab->keycode == keycode && grab->modifiers == modifiers)
            return grab;
    }
    return NULL;
}

static void clear_key_grabs(TriadX11Probe *probe)
{
    for (uint32_t i = 0; i < probe->key_grab_count; i++) {
        TriadX11ResolvedKeyGrab *grab = &probe->key_grabs[i];
        ungrab_key_variants(probe, grab->keycode, grab->modifiers);
    }
    free(probe->key_grabs);
    probe->key_grabs = NULL;
    probe->key_grab_count = 0;
}

static void ungrab_button_variants(
    TriadX11Probe *probe,
    uint32_t button,
    uint32_t modifiers)
{
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS];
    size_t variant_count = grab_modifier_variants(probe, modifiers, variants);
    for (size_t i = 0; i < variant_count; i++)
        xcb_ungrab_button(
            probe->conn,
            (uint8_t)button,
            probe->screen->root,
            (uint16_t)variants[i]);
}

static int grab_button_variants(
    TriadX11Probe *probe,
    uint32_t button,
    uint32_t modifiers,
    const char *binding)
{
    uint32_t variants[TRIAD_X11_MAX_GRAB_VARIANTS];
    size_t variant_count = grab_modifier_variants(probe, modifiers, variants);
    int ok = 1;
    for (size_t i = 0; i < variant_count; i++) {
        xcb_void_cookie_t cookie = xcb_grab_button_checked(
            probe->conn,
            0,
            probe->screen->root,
            XCB_EVENT_MASK_BUTTON_PRESS |
                XCB_EVENT_MASK_BUTTON_RELEASE |
                XCB_EVENT_MASK_POINTER_MOTION,
            XCB_GRAB_MODE_ASYNC,
            XCB_GRAB_MODE_ASYNC,
            XCB_NONE,
            XCB_NONE,
            (uint8_t)button,
            (uint16_t)variants[i]);
        xcb_generic_error_t *error = xcb_request_check(probe->conn, cookie);
        if (error != NULL) {
            probe_log(
                probe,
                "button grab failed binding=\"%s\" button=%u modifiers=0x%04x error_code=%u",
                binding,
                button,
                variants[i],
                error->error_code);
            free(error);
            ok = 0;
        }
    }
    return ok;
}

static const TriadX11ResolvedButtonGrab *button_grab_for_event(
    TriadX11Probe *probe,
    uint32_t button,
    uint32_t state)
{
    uint32_t modifiers = binding_modifier_mask(probe, state);
    for (uint32_t i = 0; i < probe->button_grab_count; i++) {
        TriadX11ResolvedButtonGrab *grab = &probe->button_grabs[i];
        if (grab->button == button && grab->modifiers == modifiers)
            return grab;
    }
    return NULL;
}

static void clear_button_grabs(TriadX11Probe *probe)
{
    for (uint32_t i = 0; i < probe->button_grab_count; i++) {
        TriadX11ResolvedButtonGrab *grab = &probe->button_grabs[i];
        ungrab_button_variants(probe, grab->button, grab->modifiers);
    }
    free(probe->button_grabs);
    probe->button_grabs = NULL;
    probe->button_grab_count = 0;
}

static const TriadX11ResolvedAxisGrab *axis_grab_for_event(
    TriadX11Probe *probe,
    uint32_t button,
    uint32_t state)
{
    uint32_t modifiers = binding_modifier_mask(probe, state);
    for (uint32_t i = 0; i < probe->axis_grab_count; i++) {
        TriadX11ResolvedAxisGrab *grab = &probe->axis_grabs[i];
        if (grab->button == button && grab->modifiers == modifiers)
            return grab;
    }
    return NULL;
}

static void clear_axis_grabs(TriadX11Probe *probe)
{
    for (uint32_t i = 0; i < probe->axis_grab_count; i++) {
        TriadX11ResolvedAxisGrab *grab = &probe->axis_grabs[i];
        ungrab_button_variants(probe, grab->button, grab->modifiers);
    }
    free(probe->axis_grabs);
    probe->axis_grabs = NULL;
    probe->axis_grab_count = 0;
}

static void log_window(
    TriadX11Probe *probe,
    xcb_window_t win,
    const char *source,
    TriadX11EventKind event_kind)
{
    if (win == probe->owner_window)
        return;

    xcb_get_window_attributes_cookie_t attr_cookie =
        xcb_get_window_attributes(probe->conn, win);
    xcb_get_geometry_cookie_t geom_cookie = xcb_get_geometry(probe->conn, win);
    xcb_get_window_attributes_reply_t *attr =
        xcb_get_window_attributes_reply(probe->conn, attr_cookie, NULL);
    xcb_get_geometry_reply_t *geom =
        xcb_get_geometry_reply(probe->conn, geom_cookie, NULL);

    if (attr == NULL || geom == NULL) {
        free(attr);
        free(geom);
        return;
    }

    char *title = window_title(probe, win);
    char *class_name = window_class(probe, win);
    uint32_t pid = window_pid(probe, win);

    probe_log(
        probe,
        "window source=%s id=0x%08x map_state=%u override_redirect=%u geom=%dx%d+%d+%d class=\"%s\" title=\"%s\" pid=%u",
        source,
        win,
        attr->map_state,
        attr->override_redirect,
        geom->width,
        geom->height,
        geom->x,
        geom->y,
        class_name != NULL ? class_name : "",
        title != NULL ? title : "",
        pid);

    TriadX11Event event;
    memset(&event, 0, sizeof(event));
    event.kind = event_kind;
    event.id = win;
    event.parent_id = 0;
    event.pid = (int32_t)pid;
    event.x = geom->x;
    event.y = geom->y;
    event.w = geom->width;
    event.h = geom->height;
    event.override_redirect = attr->override_redirect ? 1 : 0;
    event.mapped = attr->map_state == XCB_MAP_STATE_VIEWABLE ? 1 : 0;
    copy_text(event.name, sizeof(event.name), class_name);
    copy_text(event.title, sizeof(event.title), title);
    probe_event(probe, &event);

    if (!attr->override_redirect)
        select_window_events(probe, win);

    free(title);
    free(class_name);
    free(attr);
    free(geom);
}

static void query_existing_windows(TriadX11Probe *probe)
{
    xcb_query_tree_cookie_t cookie = xcb_query_tree(probe->conn, probe->screen->root);
    xcb_query_tree_reply_t *reply =
        xcb_query_tree_reply(probe->conn, cookie, NULL);
    if (reply == NULL) {
        probe_log(probe, "windows unavailable");
        return;
    }

    int len = xcb_query_tree_children_length(reply);
    xcb_window_t *children = xcb_query_tree_children(reply);
    probe_log(probe, "windows count=%d", len);
    for (int i = 0; i < len; i++)
        log_window(probe, children[i], "startup", TRIAD_X11_EVENT_WINDOW_DISCOVERED);
    free(reply);
}

static void init_atoms(TriadX11Probe *probe)
{
    char selection_name[32];
    snprintf(selection_name, sizeof(selection_name), "WM_S%d", probe->screen_number);

    probe->atoms.wm_protocols = intern_atom(probe, "WM_PROTOCOLS", 0);
    probe->atoms.wm_delete_window = intern_atom(probe, "WM_DELETE_WINDOW", 0);
    probe->atoms.wm_class = intern_atom(probe, "WM_CLASS", 0);
    probe->atoms.wm_name = intern_atom(probe, "WM_NAME", 0);
    probe->atoms.net_wm_name = intern_atom(probe, "_NET_WM_NAME", 0);
    probe->atoms.net_wm_pid = intern_atom(probe, "_NET_WM_PID", 0);
    probe->atoms.net_wm_state = intern_atom(probe, "_NET_WM_STATE", 0);
    probe->atoms.net_wm_state_fullscreen =
        intern_atom(probe, "_NET_WM_STATE_FULLSCREEN", 0);
    probe->atoms.net_wm_state_maximized_horz =
        intern_atom(probe, "_NET_WM_STATE_MAXIMIZED_HORZ", 0);
    probe->atoms.net_wm_state_maximized_vert =
        intern_atom(probe, "_NET_WM_STATE_MAXIMIZED_VERT", 0);
    probe->atoms.net_wm_state_hidden =
        intern_atom(probe, "_NET_WM_STATE_HIDDEN", 0);
    probe->atoms.net_wm_state_demands_attention =
        intern_atom(probe, "_NET_WM_STATE_DEMANDS_ATTENTION", 0);
    probe->atoms.net_wm_window_type = intern_atom(probe, "_NET_WM_WINDOW_TYPE", 0);
    probe->atoms.net_supported = intern_atom(probe, "_NET_SUPPORTED", 0);
    probe->atoms.net_supporting_wm_check =
        intern_atom(probe, "_NET_SUPPORTING_WM_CHECK", 0);
    probe->atoms.utf8_string = intern_atom(probe, "UTF8_STRING", 0);
    probe->atoms.cardinal = intern_atom(probe, "CARDINAL", 0);
    probe->atoms.window = intern_atom(probe, "WINDOW", 0);
    probe->atoms.wm_selection = intern_atom(probe, selection_name, 0);

    probe_log(probe, "atoms initialized wm_selection=%s", selection_name);

    xcb_intern_atom_cookie_t *ewmh_cookie =
        xcb_ewmh_init_atoms(probe->conn, &probe->ewmh);
    if (xcb_ewmh_init_atoms_replies(&probe->ewmh, ewmh_cookie, NULL)) {
        probe->ewmh_ready = 1;
        probe_log(probe, "ewmh initialized");
    } else {
        probe_log(probe, "ewmh initialization failed");
    }
}

static int claim_wm(TriadX11Probe *probe)
{
    uint32_t owner_values[] = { XCB_EVENT_MASK_PROPERTY_CHANGE };
    probe->owner_window = xcb_generate_id(probe->conn);
    xcb_create_window(
        probe->conn,
        XCB_COPY_FROM_PARENT,
        probe->owner_window,
        probe->screen->root,
        -1,
        -1,
        1,
        1,
        0,
        XCB_WINDOW_CLASS_INPUT_OUTPUT,
        probe->screen->root_visual,
        XCB_CW_EVENT_MASK,
        owner_values);

    uint32_t root_mask =
        XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT |
        XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY |
        XCB_EVENT_MASK_STRUCTURE_NOTIFY |
        XCB_EVENT_MASK_PROPERTY_CHANGE |
        XCB_EVENT_MASK_FOCUS_CHANGE;
    xcb_void_cookie_t root_cookie = xcb_change_window_attributes_checked(
        probe->conn, probe->screen->root, XCB_CW_EVENT_MASK, &root_mask);
    xcb_generic_error_t *root_error = xcb_request_check(probe->conn, root_cookie);
    if (root_error != NULL) {
        uint8_t code = root_error->error_code;
        free(root_error);
        probe_log(
            probe,
            "error another window manager owns root event selection error_code=%u",
            code);
        return 0;
    }

    xcb_set_selection_owner(
        probe->conn,
        probe->owner_window,
        probe->atoms.wm_selection,
        XCB_CURRENT_TIME);
    xcb_get_selection_owner_cookie_t selection_cookie =
        xcb_get_selection_owner(probe->conn, probe->atoms.wm_selection);
    xcb_get_selection_owner_reply_t *selection_reply =
        xcb_get_selection_owner_reply(probe->conn, selection_cookie, NULL);
    if (selection_reply == NULL ||
        selection_reply->owner != probe->owner_window) {
        free(selection_reply);
        probe_log(probe, "error failed to claim window-manager selection");
        return 0;
    }
    free(selection_reply);

    const char name[] = "triad_xlibre probe";
    xcb_change_property(
        probe->conn,
        XCB_PROP_MODE_REPLACE,
        probe->screen->root,
        probe->atoms.net_supporting_wm_check,
        XCB_ATOM_WINDOW,
        32,
        1,
        &probe->owner_window);
    xcb_change_property(
        probe->conn,
        XCB_PROP_MODE_REPLACE,
        probe->owner_window,
        probe->atoms.net_supporting_wm_check,
        XCB_ATOM_WINDOW,
        32,
        1,
        &probe->owner_window);
    xcb_change_property(
        probe->conn,
        XCB_PROP_MODE_REPLACE,
        probe->owner_window,
        probe->atoms.net_wm_name,
        probe->atoms.utf8_string,
        8,
        strlen(name),
        name);

    xcb_atom_t supported[] = {
        probe->atoms.net_supported,
        probe->atoms.net_supporting_wm_check,
        probe->atoms.net_wm_name,
        probe->atoms.net_wm_pid,
        probe->atoms.net_wm_state,
        probe->atoms.net_wm_state_fullscreen,
        probe->atoms.net_wm_state_maximized_horz,
        probe->atoms.net_wm_state_maximized_vert,
        probe->atoms.net_wm_state_hidden,
        probe->atoms.net_wm_state_demands_attention,
        probe->atoms.net_wm_window_type,
    };
    xcb_change_property(
        probe->conn,
        XCB_PROP_MODE_REPLACE,
        probe->screen->root,
        probe->atoms.net_supported,
        XCB_ATOM_ATOM,
        32,
        sizeof(supported) / sizeof(supported[0]),
        supported);

    xcb_flush(probe->conn);
    probe_log(
        probe,
        "wm claimed root=0x%08x owner=0x%08x selection_atom=%u",
        probe->screen->root,
        probe->owner_window,
        probe->atoms.wm_selection);
    return 1;
}

static int device_has_class(
    const xcb_input_xi_device_info_t *device,
    uint16_t class_type)
{
    xcb_input_device_class_iterator_t iter =
        xcb_input_xi_device_info_classes_iterator(device);
    while (iter.rem > 0) {
        if (iter.data->type == class_type)
            return 1;
        xcb_input_device_class_next(&iter);
    }
    return 0;
}

static void query_xinput_devices(TriadX11Probe *probe)
{
    xcb_input_xi_query_device_cookie_t device_cookie =
        xcb_input_xi_query_device(probe->conn, XCB_INPUT_DEVICE_ALL);
    xcb_generic_error_t *device_error = NULL;
    xcb_input_xi_query_device_reply_t *devices =
        xcb_input_xi_query_device_reply(probe->conn, device_cookie, &device_error);
    if (device_error != NULL) {
        probe_log(
            probe,
            "xinput devices unavailable error_code=%u",
            device_error->error_code);
        free(device_error);
        return;
    }
    if (devices == NULL) {
        probe_log(probe, "xinput devices unavailable");
        return;
    }

    int master_keyboards = 0;
    int master_pointers = 0;
    int slave_keyboards = 0;
    int slave_pointers = 0;
    int key_class_devices = 0;
    int button_class_devices = 0;
    int touch_class_devices = 0;

    xcb_input_xi_device_info_iterator_t iter =
        xcb_input_xi_query_device_infos_iterator(devices);
    while (iter.rem > 0) {
        xcb_input_xi_device_info_t *device = iter.data;
        switch (device->type) {
        case XCB_INPUT_DEVICE_TYPE_MASTER_KEYBOARD:
            master_keyboards++;
            break;
        case XCB_INPUT_DEVICE_TYPE_MASTER_POINTER:
            master_pointers++;
            break;
        case XCB_INPUT_DEVICE_TYPE_SLAVE_KEYBOARD:
            slave_keyboards++;
            break;
        case XCB_INPUT_DEVICE_TYPE_SLAVE_POINTER:
            slave_pointers++;
            break;
        default:
            break;
        }
        if (device_has_class(device, XCB_INPUT_DEVICE_CLASS_TYPE_KEY))
            key_class_devices++;
        if (device_has_class(device, XCB_INPUT_DEVICE_CLASS_TYPE_BUTTON))
            button_class_devices++;
        if (device_has_class(device, XCB_INPUT_DEVICE_CLASS_TYPE_TOUCH))
            touch_class_devices++;
        xcb_input_xi_device_info_next(&iter);
    }

    probe_log(
        probe,
        "xinput devices count=%u master_keyboards=%d master_pointers=%d "
        "slave_keyboards=%d slave_pointers=%d key_class=%d button_class=%d touch_class=%d",
        devices->num_infos,
        master_keyboards,
        master_pointers,
        slave_keyboards,
        slave_pointers,
        key_class_devices,
        button_class_devices,
        touch_class_devices);
    free(devices);
}

static void select_xkb_events(TriadX11Probe *probe)
{
    uint16_t xkb_events =
        XCB_XKB_EVENT_TYPE_NEW_KEYBOARD_NOTIFY |
        XCB_XKB_EVENT_TYPE_MAP_NOTIFY |
        XCB_XKB_EVENT_TYPE_STATE_NOTIFY;
    uint16_t map_parts =
        XCB_XKB_MAP_PART_KEY_TYPES |
        XCB_XKB_MAP_PART_KEY_SYMS |
        XCB_XKB_MAP_PART_MODIFIER_MAP |
        XCB_XKB_MAP_PART_VIRTUAL_MODS |
        XCB_XKB_MAP_PART_VIRTUAL_MOD_MAP;
    uint16_t state_parts =
        XCB_XKB_STATE_PART_MODIFIER_STATE |
        XCB_XKB_STATE_PART_MODIFIER_BASE |
        XCB_XKB_STATE_PART_MODIFIER_LATCH |
        XCB_XKB_STATE_PART_MODIFIER_LOCK |
        XCB_XKB_STATE_PART_GROUP_STATE |
        XCB_XKB_STATE_PART_GROUP_BASE |
        XCB_XKB_STATE_PART_GROUP_LATCH |
        XCB_XKB_STATE_PART_GROUP_LOCK;
    uint16_t new_keyboard_details =
        XCB_XKB_NKN_DETAIL_KEYCODES | XCB_XKB_NKN_DETAIL_DEVICE_ID;

    xcb_xkb_select_events_details_t details;
    memset(&details, 0, sizeof(details));
    details.affectNewKeyboard = new_keyboard_details;
    details.newKeyboardDetails = new_keyboard_details;
    details.affectState = state_parts;
    details.stateDetails = state_parts;

    xcb_void_cookie_t cookie = xcb_xkb_select_events_aux_checked(
        probe->conn,
        XCB_XKB_ID_USE_CORE_KBD,
        xkb_events,
        0,
        xkb_events,
        map_parts,
        map_parts,
        &details);
    xcb_generic_error_t *error = xcb_request_check(probe->conn, cookie);
    if (error != NULL) {
        probe_log(probe, "xkb event selection failed error_code=%u", error->error_code);
        free(error);
        return;
    }
    probe_log(
        probe,
        "xkb events selected events=0x%04x map=0x%04x state=0x%04x",
        xkb_events,
        map_parts,
        state_parts);
}

static void query_input_extensions(TriadX11Probe *probe)
{
    probe->xkb_ext = xcb_get_extension_data(probe->conn, &xcb_xkb_id);
    if (probe->xkb_ext == NULL || !probe->xkb_ext->present) {
        probe_log(probe, "xkb unavailable");
    } else {
        xcb_xkb_use_extension_cookie_t xkb_cookie =
            xcb_xkb_use_extension(probe->conn, XCB_XKB_MAJOR_VERSION, XCB_XKB_MINOR_VERSION);
        xcb_generic_error_t *xkb_error = NULL;
        xcb_xkb_use_extension_reply_t *xkb =
            xcb_xkb_use_extension_reply(probe->conn, xkb_cookie, &xkb_error);
        if (xkb_error != NULL) {
            probe_log(probe, "xkb unavailable error_code=%u", xkb_error->error_code);
            free(xkb_error);
        } else if (xkb == NULL) {
            probe_log(probe, "xkb unavailable");
        } else {
            probe_log(
                probe,
                "xkb version=%u.%u supported=%u event_base=%u",
                xkb->serverMajor,
                xkb->serverMinor,
                xkb->supported,
                probe->xkb_ext->first_event);
            if (xkb->supported)
                select_xkb_events(probe);
            free(xkb);
        }
    }

    probe->xinput_ext = xcb_get_extension_data(probe->conn, &xcb_input_id);
    if (probe->xinput_ext == NULL || !probe->xinput_ext->present) {
        probe_log(probe, "xinput unavailable");
        return;
    }

    xcb_input_xi_query_version_cookie_t xinput_cookie =
        xcb_input_xi_query_version(probe->conn, 2, 4);
    xcb_generic_error_t *xinput_error = NULL;
    xcb_input_xi_query_version_reply_t *xinput =
        xcb_input_xi_query_version_reply(probe->conn, xinput_cookie, &xinput_error);
    if (xinput_error != NULL) {
        probe_log(probe, "xinput unavailable error_code=%u", xinput_error->error_code);
        free(xinput_error);
        return;
    }
    if (xinput == NULL) {
        probe_log(probe, "xinput unavailable");
        return;
    }

    probe_log(
        probe,
        "xinput version=%u.%u opcode=%u event_base=%u",
        xinput->major_version,
        xinput->minor_version,
        probe->xinput_ext->major_opcode,
        probe->xinput_ext->first_event);
    free(xinput);
    query_xinput_devices(probe);
}

static void query_randr(TriadX11Probe *probe)
{
    probe->randr_ext = xcb_get_extension_data(probe->conn, &xcb_randr_id);
    if (probe->randr_ext == NULL || !probe->randr_ext->present) {
        probe_log(probe, "randr unavailable");
        return;
    }

    xcb_randr_query_version_cookie_t version_cookie =
        xcb_randr_query_version(probe->conn, 1, 5);
    xcb_randr_query_version_reply_t *version =
        xcb_randr_query_version_reply(probe->conn, version_cookie, NULL);
    if (version != NULL) {
        probe_log(
            probe,
            "randr version=%u.%u event_base=%u",
            version->major_version,
            version->minor_version,
            probe->randr_ext->first_event);
        free(version);
    }

    xcb_randr_select_input(
        probe->conn,
        probe->screen->root,
        XCB_RANDR_NOTIFY_MASK_SCREEN_CHANGE |
            XCB_RANDR_NOTIFY_MASK_CRTC_CHANGE |
            XCB_RANDR_NOTIFY_MASK_OUTPUT_CHANGE |
            XCB_RANDR_NOTIFY_MASK_OUTPUT_PROPERTY);

    xcb_randr_get_screen_resources_current_cookie_t resources_cookie =
        xcb_randr_get_screen_resources_current(probe->conn, probe->screen->root);
    xcb_randr_get_screen_resources_current_reply_t *resources =
        xcb_randr_get_screen_resources_current_reply(
            probe->conn, resources_cookie, NULL);
    if (resources == NULL) {
        probe_log(probe, "outputs unavailable");
        return;
    }

    int output_len = xcb_randr_get_screen_resources_current_outputs_length(resources);
    xcb_randr_output_t *outputs =
        xcb_randr_get_screen_resources_current_outputs(resources);
    probe_log(probe, "outputs count=%d", output_len);

    for (int i = 0; i < output_len; i++) {
        xcb_randr_get_output_info_cookie_t info_cookie =
            xcb_randr_get_output_info(probe->conn, outputs[i], resources->config_timestamp);
        xcb_randr_get_output_info_reply_t *info =
            xcb_randr_get_output_info_reply(probe->conn, info_cookie, NULL);
        if (info == NULL)
            continue;

        int name_len = xcb_randr_get_output_info_name_length(info);
        char name[128];
        int copy_len = name_len < (int)sizeof(name) - 1 ? name_len : (int)sizeof(name) - 1;
        memcpy(name, xcb_randr_get_output_info_name(info), (size_t)copy_len);
        name[copy_len] = '\0';

        int16_t x = 0;
        int16_t y = 0;
        uint16_t width = 0;
        uint16_t height = 0;
        if (info->crtc != XCB_NONE) {
            xcb_randr_get_crtc_info_cookie_t crtc_cookie =
                xcb_randr_get_crtc_info(probe->conn, info->crtc, resources->config_timestamp);
            xcb_randr_get_crtc_info_reply_t *crtc =
                xcb_randr_get_crtc_info_reply(probe->conn, crtc_cookie, NULL);
            if (crtc != NULL) {
                x = crtc->x;
                y = crtc->y;
                width = crtc->width;
                height = crtc->height;
                free(crtc);
            }
        }

        probe_log(
            probe,
            "output id=%u name=\"%s\" connected=%u crtc=%u geom=%ux%u+%d+%d",
            outputs[i],
            name,
            info->connection == XCB_RANDR_CONNECTION_CONNECTED,
            info->crtc,
            width,
            height,
            x,
            y);

        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_OUTPUT_DISCOVERED;
        event.id = outputs[i];
        event.connected =
            info->connection == XCB_RANDR_CONNECTION_CONNECTED ? 1 : 0;
        event.x = x;
        event.y = y;
        event.w = width;
        event.h = height;
        copy_text(event.name, sizeof(event.name), name);
        probe_event(probe, &event);
        free(info);
    }

    free(resources);
}

static void emit_xkb_changed(
    TriadX11Probe *probe,
    uint8_t xkb_type,
    uint16_t changed,
    uint8_t group,
    uint8_t locked_group,
    uint8_t keycode)
{
    TriadX11Event emitted;
    memset(&emitted, 0, sizeof(emitted));
    emitted.kind = TRIAD_X11_EVENT_XKB_CHANGED;
    emitted.id = xkb_type;
    emitted.value_mask = changed;
    emitted.root = ((uint32_t)group << 16) | locked_group;
    emitted.sibling = keycode;
    probe_event(probe, &emitted);
}

static void log_xkb_event(TriadX11Probe *probe, xcb_generic_event_t *event)
{
    uint8_t xkb_type = ((xcb_xkb_state_notify_event_t *)event)->xkbType;
    switch (xkb_type) {
    case XCB_XKB_NEW_KEYBOARD_NOTIFY: {
        xcb_xkb_new_keyboard_notify_event_t *ev =
            (xcb_xkb_new_keyboard_notify_event_t *)event;
        probe_log(
            probe,
            "event %s device=%u changed=0x%04x min_keycode=%u max_keycode=%u",
            xkb_event_name(xkb_type),
            ev->deviceID,
            ev->changed,
            ev->minKeyCode,
            ev->maxKeyCode);
        detect_ignored_lock_modifiers(probe);
        emit_xkb_changed(
            probe,
            xkb_type,
            ev->changed,
            0,
            0,
            ev->minKeyCode);
        break;
    }
    case XCB_XKB_MAP_NOTIFY: {
        xcb_xkb_map_notify_event_t *ev = (xcb_xkb_map_notify_event_t *)event;
        probe_log(
            probe,
            "event %s device=%u changed=0x%04x min_keycode=%u max_keycode=%u first_keysym=%u n_keysyms=%u",
            xkb_event_name(xkb_type),
            ev->deviceID,
            ev->changed,
            ev->minKeyCode,
            ev->maxKeyCode,
            ev->firstKeySym,
            ev->nKeySyms);
        detect_ignored_lock_modifiers(probe);
        emit_xkb_changed(
            probe,
            xkb_type,
            ev->changed,
            0,
            0,
            ev->minKeyCode);
        break;
    }
    case XCB_XKB_STATE_NOTIFY: {
        xcb_xkb_state_notify_event_t *ev = (xcb_xkb_state_notify_event_t *)event;
        probe_log(
            probe,
            "event %s device=%u changed=0x%04x group=%u base_group=%d latched_group=%d locked_group=%u mods=0x%02x locked_mods=0x%02x keycode=%u",
            xkb_event_name(xkb_type),
            ev->deviceID,
            ev->changed,
            ev->group,
            ev->baseGroup,
            ev->latchedGroup,
            ev->lockedGroup,
            ev->mods,
            ev->lockedMods,
            ev->keycode);
        emit_xkb_changed(
            probe,
            xkb_type,
            ev->changed,
            ev->group,
            ev->lockedGroup,
            ev->keycode);
        break;
    }
    default:
        probe_log(probe, "event %s type=%u", xkb_event_name(xkb_type), xkb_type);
        break;
    }
}

static void log_event(TriadX11Probe *probe, xcb_generic_event_t *event)
{
    uint8_t type = event->response_type & 0x7f;
    if (probe->xkb_ext != NULL && probe->xkb_ext->present &&
        type == probe->xkb_ext->first_event) {
        log_xkb_event(probe, event);
        return;
    }
    if (probe->randr_ext != NULL && probe->randr_ext->present &&
        type == probe->randr_ext->first_event + XCB_RANDR_SCREEN_CHANGE_NOTIFY) {
        xcb_randr_screen_change_notify_event_t *ev =
            (xcb_randr_screen_change_notify_event_t *)event;
        probe_log(
            probe,
            "event RandRScreenChange root=0x%08x size=%ux%u",
            ev->root,
            ev->width,
            ev->height);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_RANDR_CHANGED;
        event.root = ev->root;
        event.w = ev->width;
        event.h = ev->height;
        probe_event(probe, &event);
        return;
    }
    if (probe->randr_ext != NULL && probe->randr_ext->present &&
        type == probe->randr_ext->first_event + XCB_RANDR_NOTIFY) {
        xcb_randr_notify_event_t *ev = (xcb_randr_notify_event_t *)event;
        probe_log(probe, "event RandRNotify subCode=%u", ev->subCode);
        return;
    }

    switch (type) {
    case XCB_MAP_REQUEST: {
        xcb_map_request_event_t *ev = (xcb_map_request_event_t *)event;
        probe_log(
            probe,
            "event %s parent=0x%08x window=0x%08x",
            event_name(type),
            ev->parent,
            ev->window);
        log_window(probe, ev->window, "map-request", TRIAD_X11_EVENT_MAP_REQUESTED);
        break;
    }
    case XCB_KEY_PRESS: {
        xcb_key_press_event_t *ev = (xcb_key_press_event_t *)event;
        const TriadX11ResolvedKeyGrab *grab =
            key_grab_for_event(probe, ev->detail, ev->state);
        probe_log(
            probe,
            "event %s keycode=%u state=0x%04x binding=\"%s\"",
            event_name(type),
            ev->detail,
            ev->state,
            grab != NULL ? grab->binding : "");
        if (grab != NULL) {
            TriadX11Event event;
            memset(&event, 0, sizeof(event));
            event.kind = TRIAD_X11_EVENT_KEY_BINDING;
            event.id = ev->detail;
            event.value_mask = binding_modifier_mask(probe, ev->state);
            copy_text(event.name, sizeof(event.name), grab->binding);
            probe_event(probe, &event);
        }
        break;
    }
    case XCB_BUTTON_PRESS: {
        xcb_button_press_event_t *ev = (xcb_button_press_event_t *)event;
        const TriadX11ResolvedButtonGrab *grab =
            button_grab_for_event(probe, ev->detail, ev->state);
        const TriadX11ResolvedAxisGrab *axis_grab =
            grab == NULL ? axis_grab_for_event(probe, ev->detail, ev->state) : NULL;
        probe_log(
            probe,
            "event %s button=%u state=0x%04x binding=\"%s\"",
            event_name(type),
            ev->detail,
            ev->state,
            grab != NULL ? grab->binding : axis_grab != NULL ? axis_grab->binding : "");
        if (grab != NULL) {
            TriadX11Event event;
            memset(&event, 0, sizeof(event));
            event.kind = TRIAD_X11_EVENT_POINTER_BINDING;
            event.id = ev->detail;
            event.parent_id = ev->child;
            event.x = ev->root_x;
            event.y = ev->root_y;
            event.value_mask = binding_modifier_mask(probe, ev->state);
            copy_text(event.name, sizeof(event.name), grab->binding);
            probe_event(probe, &event);
        } else if (axis_grab != NULL) {
            TriadX11Event event;
            memset(&event, 0, sizeof(event));
            event.kind = TRIAD_X11_EVENT_AXIS_BINDING;
            event.id = ev->detail;
            event.parent_id = ev->child;
            event.x = ev->root_x;
            event.y = ev->root_y;
            event.value_mask = binding_modifier_mask(probe, ev->state);
            copy_text(event.name, sizeof(event.name), axis_grab->binding);
            probe_event(probe, &event);
        }
        break;
    }
    case XCB_MOTION_NOTIFY: {
        xcb_motion_notify_event_t *ev = (xcb_motion_notify_event_t *)event;
        probe_log(
            probe,
            "event %s root_xy=%d,%d state=0x%04x child=0x%08x",
            event_name(type),
            ev->root_x,
            ev->root_y,
            ev->state,
            ev->child);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_POINTER_MOTION;
        event.id = ev->child;
        event.x = ev->root_x;
        event.y = ev->root_y;
        event.value_mask = binding_modifier_mask(probe, ev->state);
        probe_event(probe, &event);
        break;
    }
    case XCB_BUTTON_RELEASE: {
        xcb_button_release_event_t *ev = (xcb_button_release_event_t *)event;
        probe_log(
            probe,
            "event %s button=%u root_xy=%d,%d state=0x%04x child=0x%08x",
            event_name(type),
            ev->detail,
            ev->root_x,
            ev->root_y,
            ev->state,
            ev->child);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_POINTER_RELEASE;
        event.id = ev->detail;
        event.parent_id = ev->child;
        event.x = ev->root_x;
        event.y = ev->root_y;
        event.value_mask = binding_modifier_mask(probe, ev->state);
        probe_event(probe, &event);
        break;
    }
    case XCB_UNMAP_NOTIFY: {
        xcb_unmap_notify_event_t *ev = (xcb_unmap_notify_event_t *)event;
        char *state = window_state_atoms(probe, ev->window);
        probe_log(
            probe,
            "event %s event=0x%08x window=0x%08x from_configure=%u state=\"%s\"",
            event_name(type),
            ev->event,
            ev->window,
            ev->from_configure,
            state != NULL ? state : "");
        if (take_suppressed_unmap_notify(probe, ev->window)) {
            probe_log(probe, "event UnmapNotify ignored internal window=0x%08x", ev->window);
            free(state);
            break;
        }
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.id = ev->window;
        if (state != NULL && strstr(state, "_NET_WM_STATE_HIDDEN") != NULL) {
            event.kind = TRIAD_X11_EVENT_PROPERTY_CHANGED;
            copy_text(event.name, sizeof(event.name), "_NET_WM_STATE");
            copy_text(event.title, sizeof(event.title), state);
        } else {
            event.kind = TRIAD_X11_EVENT_WINDOW_UNMAPPED;
        }
        free(state);
        probe_event(probe, &event);
        break;
    }
    case XCB_DESTROY_NOTIFY: {
        xcb_destroy_notify_event_t *ev = (xcb_destroy_notify_event_t *)event;
        probe_log(
            probe,
            "event %s event=0x%08x window=0x%08x",
            event_name(type),
            ev->event,
            ev->window);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_WINDOW_DESTROYED;
        event.id = ev->window;
        probe_event(probe, &event);
        break;
    }
    case XCB_CONFIGURE_REQUEST: {
        xcb_configure_request_event_t *ev = (xcb_configure_request_event_t *)event;
        probe_log(
            probe,
            "event %s parent=0x%08x window=0x%08x mask=0x%04x geom=%dx%d+%d+%d sibling=0x%08x stack_mode=%u",
            event_name(type),
            ev->parent,
            ev->window,
            ev->value_mask,
            ev->width,
            ev->height,
            ev->x,
            ev->y,
            ev->sibling,
            ev->stack_mode);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_CONFIGURE_REQUESTED;
        event.id = ev->window;
        event.parent_id = ev->parent;
        event.value_mask = ev->value_mask;
        event.x = ev->x;
        event.y = ev->y;
        event.w = ev->width;
        event.h = ev->height;
        event.sibling = ev->sibling;
        event.stack_mode = ev->stack_mode;
        probe_event(probe, &event);
        break;
    }
    case XCB_CONFIGURE_NOTIFY: {
        xcb_configure_notify_event_t *ev = (xcb_configure_notify_event_t *)event;
        probe_log(
            probe,
            "event %s event=0x%08x window=0x%08x geom=%ux%u+%d+%d above=0x%08x override_redirect=%u",
            event_name(type),
            ev->event,
            ev->window,
            ev->width,
            ev->height,
            ev->x,
            ev->y,
            ev->above_sibling,
            ev->override_redirect);
        break;
    }
    case XCB_PROPERTY_NOTIFY: {
        xcb_property_notify_event_t *ev = (xcb_property_notify_event_t *)event;
        char *name = atom_name(probe, ev->atom);
        probe_log(
            probe,
            "event %s window=0x%08x atom=%s(%u) state=%u",
            event_name(type),
            ev->window,
            name,
            ev->atom,
            ev->state);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_PROPERTY_CHANGED;
        event.id = ev->window;
        copy_text(event.name, sizeof(event.name), name);
        if (ev->state == XCB_PROPERTY_NEW_VALUE) {
            if (ev->atom == probe->atoms.wm_class) {
                char *class_name = window_class(probe, ev->window);
                copy_text(event.title, sizeof(event.title), class_name);
                free(class_name);
            } else if (
                ev->atom == probe->atoms.wm_name ||
                ev->atom == probe->atoms.net_wm_name) {
                char *title = window_title(probe, ev->window);
                copy_text(event.title, sizeof(event.title), title);
                free(title);
            } else if (ev->atom == probe->atoms.net_wm_pid) {
                event.pid = (int32_t)window_pid(probe, ev->window);
            } else if (ev->atom == probe->atoms.net_wm_state) {
                char *state = window_state_atoms(probe, ev->window);
                copy_text(event.title, sizeof(event.title), state);
                free(state);
            }
        }
        probe_event(probe, &event);
        free(name);
        break;
    }
    case XCB_FOCUS_IN:
    case XCB_FOCUS_OUT: {
        xcb_focus_in_event_t *ev = (xcb_focus_in_event_t *)event;
        probe_log(
            probe,
            "event %s window=0x%08x mode=%u detail=%u",
            event_name(type),
            ev->event,
            ev->mode,
            ev->detail);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_FOCUS_CHANGED;
        event.id = ev->event;
        event.focused = type == XCB_FOCUS_IN ? 1 : 0;
        probe_event(probe, &event);
        break;
    }
    case XCB_ENTER_NOTIFY: {
        xcb_enter_notify_event_t *ev = (xcb_enter_notify_event_t *)event;
        probe_log(
            probe,
            "event %s event=0x%08x child=0x%08x root_xy=%d,%d event_xy=%d,%d mode=%u detail=%u",
            event_name(type),
            ev->event,
            ev->child,
            ev->root_x,
            ev->root_y,
            ev->event_x,
            ev->event_y,
            ev->mode,
            ev->detail);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_POINTER_ENTERED;
        event.id = ev->event;
        probe_event(probe, &event);
        break;
    }
    case XCB_MAPPING_NOTIFY: {
        xcb_mapping_notify_event_t *ev = (xcb_mapping_notify_event_t *)event;
        probe_log(
            probe,
            "event %s request=%u first_keycode=%u count=%u",
            event_name(type),
            ev->request,
            ev->first_keycode,
            ev->count);
        detect_ignored_lock_modifiers(probe);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_MAPPING_CHANGED;
        event.id = ev->request;
        event.value_mask = ((uint32_t)ev->first_keycode << 8) | ev->count;
        probe_event(probe, &event);
        break;
    }
    default:
        probe_log(probe, "event %s type=%u", event_name(type), type);
        break;
    }
}

int triad_x11_probe_run(
    const char *display_name,
    int once,
    triad_x11_log_fn log_fn,
    triad_x11_event_fn event_fn,
    triad_x11_tick_fn tick_fn,
    void *user_data)
{
    TriadX11Probe probe;
    memset(&probe, 0, sizeof(probe));
    probe.log = log_fn;
    probe.event = event_fn;
    probe.log_user_data = user_data;

    probe.conn = xcb_connect(display_name, &probe.screen_number);
    if (xcb_connection_has_error(probe.conn)) {
        probe_log(&probe, "error failed to connect to X display");
        if (probe.conn != NULL)
            xcb_disconnect(probe.conn);
        return 1;
    }

    probe.setup = xcb_get_setup(probe.conn);
    probe.screen = screen_for_number(probe.setup, probe.screen_number);
    if (probe.screen == NULL) {
        probe_log(&probe, "error failed to resolve X screen");
        xcb_disconnect(probe.conn);
        return 1;
    }

    probe_log(
        &probe,
        "connected display=\"%s\" screen=%d root=0x%08x size=%ux%u",
        display_name != NULL ? display_name : "",
        probe.screen_number,
        probe.screen->root,
        probe.screen->width_in_pixels,
        probe.screen->height_in_pixels);

    detect_ignored_lock_modifiers(&probe);
    init_atoms(&probe);
    if (!claim_wm(&probe)) {
        if (probe.ewmh_ready)
            xcb_ewmh_connection_wipe(&probe.ewmh);
        xcb_disconnect(probe.conn);
        return 2;
    }

    query_input_extensions(&probe);
    query_randr(&probe);
    query_existing_windows(&probe);
    xcb_flush(probe.conn);

    if (once) {
        probe_log(&probe, "probe complete once=true");
        if (probe.ewmh_ready)
            xcb_ewmh_connection_wipe(&probe.ewmh);
        xcb_disconnect(probe.conn);
        return 0;
    }

    int xcb_fd = xcb_get_file_descriptor(probe.conn);
    probe_log(&probe, "event loop started");
    active_probe = &probe;
    while (1) {
        xcb_generic_event_t *event = NULL;
        while ((event = xcb_poll_for_event(probe.conn)) != NULL) {
            log_event(&probe, event);
            free(event);
            xcb_flush(probe.conn);
        }

        int err = xcb_connection_has_error(probe.conn);
        if (err != 0) {
            probe_log(&probe, "event loop stopped connection_error=%d", err);
            break;
        }

        if (tick_fn != NULL)
            tick_fn(user_data);
        if (probe.stop_requested) {
            probe_log(&probe, "event loop stopped stop_requested=1");
            break;
        }

        struct pollfd pfd;
        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = xcb_fd;
        pfd.events = POLLIN;
        int ready = poll(&pfd, 1, 10);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            probe_log(&probe, "event loop stopped poll_error=%d", errno);
            break;
        }
        if (ready == 0)
            continue;
        if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            err = xcb_connection_has_error(probe.conn);
            probe_log(&probe, "event loop stopped poll_revents=0x%x connection_error=%d", pfd.revents, err);
            break;
        }
    }
    clear_key_grabs(&probe);
    clear_button_grabs(&probe);
    clear_axis_grabs(&probe);
    clear_suppressed_unmaps(&probe);
    if (active_probe == &probe)
        active_probe = NULL;

    if (probe.ewmh_ready)
        xcb_ewmh_connection_wipe(&probe.ewmh);
    xcb_disconnect(probe.conn);
    return 0;
}

int triad_x11_stop_active_probe(void)
{
    if (active_probe == NULL)
        return 1;
    active_probe->stop_requested = 1;
    probe_log(active_probe, "stop requested");
    return 0;
}

int triad_x11_configure_active_key_grabs(
    const TriadX11KeyGrab *grabs,
    uint32_t count)
{
    if (active_probe == NULL)
        return 1;

    TriadX11Probe *probe = active_probe;
    clear_key_grabs(probe);

    if (count == 0 || grabs == NULL) {
        xcb_flush(probe->conn);
        probe_log(probe, "key grabs configured count=0");
        return 0;
    }

    TriadX11ResolvedKeyGrab *resolved =
        calloc((size_t)count, sizeof(TriadX11ResolvedKeyGrab));
    if (resolved == NULL) {
        probe_log(probe, "key grabs unavailable allocation_failed=1 count=%u", count);
        return 1;
    }

    uint32_t resolved_count = 0;
    for (uint32_t i = 0; i < count; i++) {
        TriadX11ResolvedKeysym key = resolved_key_for_keysym(probe, grabs[i].keysym);
        if (key.keycode == 0) {
            probe_log(
                probe,
                "key grab unavailable binding=\"%s\" keysym=0x%08x",
                grabs[i].binding,
                grabs[i].keysym);
            continue;
        }
        uint32_t modifiers = grabs[i].modifiers | key.modifiers;
        if (!grab_key_variants(probe, key.keycode, modifiers, grabs[i].binding))
            continue;

        resolved[resolved_count].keysym = grabs[i].keysym;
        resolved[resolved_count].modifiers = modifiers;
        resolved[resolved_count].keycode = key.keycode;
        copy_text(
            resolved[resolved_count].binding,
            sizeof(resolved[resolved_count].binding),
            grabs[i].binding);
        probe_log(
            probe,
            "key grab configured binding=\"%s\" keysym=0x%08x keycode=%u modifiers=0x%04x required_modifiers=0x%04x",
            resolved[resolved_count].binding,
            resolved[resolved_count].keysym,
            resolved[resolved_count].keycode,
            resolved[resolved_count].modifiers,
            key.modifiers);
        resolved_count++;
    }

    if (resolved_count == 0) {
        free(resolved);
        resolved = NULL;
    }
    probe->key_grabs = resolved;
    probe->key_grab_count = resolved_count;
    xcb_flush(probe->conn);
    probe_log(probe, "key grabs configured count=%u requested=%u", resolved_count, count);
    return 0;
}

int triad_x11_configure_active_button_grabs(
    const TriadX11ButtonGrab *grabs,
    uint32_t count)
{
    if (active_probe == NULL)
        return 1;

    TriadX11Probe *probe = active_probe;
    clear_button_grabs(probe);

    if (count == 0 || grabs == NULL) {
        xcb_flush(probe->conn);
        probe_log(probe, "button grabs configured count=0");
        return 0;
    }

    TriadX11ResolvedButtonGrab *resolved =
        calloc((size_t)count, sizeof(TriadX11ResolvedButtonGrab));
    if (resolved == NULL) {
        probe_log(probe, "button grabs unavailable allocation_failed=1 count=%u", count);
        return 1;
    }

    uint32_t resolved_count = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (grabs[i].button == 0 || grabs[i].button > UINT8_MAX) {
            probe_log(
                probe,
                "button grab unavailable binding=\"%s\" button=%u",
                grabs[i].binding,
                grabs[i].button);
            continue;
        }
        if (!grab_button_variants(probe, grabs[i].button, grabs[i].modifiers, grabs[i].binding))
            continue;

        resolved[resolved_count].button = grabs[i].button;
        resolved[resolved_count].modifiers = grabs[i].modifiers;
        copy_text(
            resolved[resolved_count].binding,
            sizeof(resolved[resolved_count].binding),
            grabs[i].binding);
        probe_log(
            probe,
            "button grab configured binding=\"%s\" button=%u modifiers=0x%04x",
            resolved[resolved_count].binding,
            resolved[resolved_count].button,
            resolved[resolved_count].modifiers);
        resolved_count++;
    }

    if (resolved_count == 0) {
        free(resolved);
        resolved = NULL;
    }
    probe->button_grabs = resolved;
    probe->button_grab_count = resolved_count;
    xcb_flush(probe->conn);
    probe_log(
        probe, "button grabs configured count=%u requested=%u", resolved_count, count);
    return 0;
}

int triad_x11_configure_active_axis_grabs(
    const TriadX11AxisGrab *grabs,
    uint32_t count)
{
    if (active_probe == NULL)
        return 1;

    TriadX11Probe *probe = active_probe;
    clear_axis_grabs(probe);

    if (count == 0 || grabs == NULL) {
        xcb_flush(probe->conn);
        probe_log(probe, "axis grabs configured count=0");
        return 0;
    }

    TriadX11ResolvedAxisGrab *resolved =
        calloc((size_t)count, sizeof(TriadX11ResolvedAxisGrab));
    if (resolved == NULL) {
        probe_log(probe, "axis grabs unavailable allocation_failed=1 count=%u", count);
        return 1;
    }

    uint32_t resolved_count = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (grabs[i].button == 0 || grabs[i].button > UINT8_MAX) {
            probe_log(
                probe,
                "axis grab unavailable binding=\"%s\" button=%u",
                grabs[i].binding,
                grabs[i].button);
            continue;
        }
        if (!grab_button_variants(probe, grabs[i].button, grabs[i].modifiers, grabs[i].binding))
            continue;

        resolved[resolved_count].button = grabs[i].button;
        resolved[resolved_count].modifiers = grabs[i].modifiers;
        copy_text(
            resolved[resolved_count].binding,
            sizeof(resolved[resolved_count].binding),
            grabs[i].binding);
        probe_log(
            probe,
            "axis grab configured binding=\"%s\" button=%u modifiers=0x%04x",
            resolved[resolved_count].binding,
            resolved[resolved_count].button,
            resolved[resolved_count].modifiers);
        resolved_count++;
    }

    if (resolved_count == 0) {
        free(resolved);
        resolved = NULL;
    }
    probe->axis_grabs = resolved;
    probe->axis_grab_count = resolved_count;
    xcb_flush(probe->conn);
    probe_log(probe, "axis grabs configured count=%u requested=%u", resolved_count, count);
    return 0;
}

static xcb_atom_t intern_atom_for_conn(
    xcb_connection_t *conn, const char *name, int only_if_exists)
{
    xcb_intern_atom_cookie_t cookie =
        xcb_intern_atom(conn, only_if_exists, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(conn, cookie, NULL);
    if (reply == NULL)
        return XCB_ATOM_NONE;
    xcb_atom_t atom = reply->atom;
    free(reply);
    return atom;
}

static int execute_configure_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    if (request->value_count < 4) {
        request_log(
            log_fn,
            user_data,
            "error configure window=0x%08x value_count=%u",
            request->window_id,
            request->value_count);
        return 1;
    }

    uint32_t values[4] = {
        (uint32_t)request->values[0],
        (uint32_t)request->values[1],
        (uint32_t)request->values[2],
        (uint32_t)request->values[3],
    };
    xcb_void_cookie_t cookie = xcb_configure_window_checked(
        conn, request->window_id, (uint16_t)request->value_mask, values);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error configure window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        return 1;
    }
    request_log(log_fn, user_data, "applied configure window=0x%08x", request->window_id);
    return 0;
}

static int execute_focus_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    xcb_void_cookie_t cookie = xcb_set_input_focus_checked(
        conn, XCB_INPUT_FOCUS_POINTER_ROOT, request->window_id, XCB_CURRENT_TIME);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error focus window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        return 1;
    }
    request_log(log_fn, user_data, "applied focus window=0x%08x", request->window_id);
    return 0;
}

static int execute_map_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    xcb_void_cookie_t cookie = xcb_map_window_checked(conn, request->window_id);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error map window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        return 1;
    }
    request_log(log_fn, user_data, "applied map window=0x%08x", request->window_id);
    return 0;
}

static int execute_unmap_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    xcb_void_cookie_t cookie = xcb_unmap_window_checked(conn, request->window_id);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error unmap window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        return 1;
    }
    if (active_probe != NULL && active_probe->conn == conn)
        (void)suppress_unmap_notify(active_probe, request->window_id);
    request_log(log_fn, user_data, "applied unmap window=0x%08x", request->window_id);
    return 0;
}

static int execute_close_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    xcb_atom_t wm_protocols = intern_atom_for_conn(conn, "WM_PROTOCOLS", 0);
    xcb_atom_t wm_delete_window = intern_atom_for_conn(conn, "WM_DELETE_WINDOW", 0);
    if (wm_protocols == XCB_ATOM_NONE || wm_delete_window == XCB_ATOM_NONE) {
        request_log(log_fn, user_data, "error close atoms unavailable");
        return 1;
    }

    xcb_client_message_event_t event;
    memset(&event, 0, sizeof(event));
    event.response_type = XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = request->window_id;
    event.type = wm_protocols;
    event.data.data32[0] = wm_delete_window;
    event.data.data32[1] = XCB_CURRENT_TIME;

    xcb_void_cookie_t cookie = xcb_send_event_checked(
        conn, 0, request->window_id, XCB_EVENT_MASK_NO_EVENT, (const char *)&event);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error close window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        return 1;
    }
    request_log(log_fn, user_data, "applied close window=0x%08x", request->window_id);
    return 0;
}

static int read_wm_state(
    xcb_connection_t *conn,
    xcb_window_t window,
    xcb_atom_t net_wm_state,
    xcb_atom_t **atoms,
    uint32_t *count)
{
    *atoms = NULL;
    *count = 0;

    xcb_get_property_cookie_t cookie = xcb_get_property(
        conn,
        0,
        window,
        net_wm_state,
        XCB_ATOM_ATOM,
        0,
        1024);
    xcb_generic_error_t *error = NULL;
    xcb_get_property_reply_t *reply = xcb_get_property_reply(conn, cookie, &error);
    if (error != NULL) {
        free(error);
        return 1;
    }
    if (reply == NULL)
        return 1;

    int length = xcb_get_property_value_length(reply) / (int)sizeof(xcb_atom_t);
    if (length > 0) {
        *atoms = calloc((size_t)length, sizeof(xcb_atom_t));
        if (*atoms == NULL) {
            free(reply);
            return 1;
        }
        memcpy(*atoms, xcb_get_property_value(reply), (size_t)length * sizeof(xcb_atom_t));
        *count = (uint32_t)length;
    }
    free(reply);
    return 0;
}

static int state_contains_atom(const xcb_atom_t *atoms, uint32_t count, xcb_atom_t atom)
{
    for (uint32_t i = 0; i < count; i++) {
        if (atoms[i] == atom)
            return 1;
    }
    return 0;
}

static int upsert_state_atom(
    xcb_atom_t *atoms, uint32_t *count, uint32_t capacity, xcb_atom_t atom, int active)
{
    for (uint32_t i = 0; i < *count; i++) {
        if (atoms[i] == atom) {
            if (!active) {
                memmove(
                    &atoms[i],
                    &atoms[i + 1],
                    (size_t)(*count - i - 1) * sizeof(xcb_atom_t));
                (*count)--;
            }
            return 0;
        }
    }
    if (active) {
        if (*count >= capacity)
            return 1;
        atoms[*count] = atom;
        (*count)++;
    }
    return 0;
}

static int execute_state_request(
    xcb_connection_t *conn,
    const TriadX11Request *request,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    if (request->value_count < 1) {
        request_log(
            log_fn,
            user_data,
            "error state window=0x%08x value_count=%u",
            request->window_id,
            request->value_count);
        return 1;
    }

    xcb_atom_t net_wm_state = intern_atom_for_conn(conn, "_NET_WM_STATE", 0);
    xcb_atom_t fullscreen = intern_atom_for_conn(conn, "_NET_WM_STATE_FULLSCREEN", 0);
    xcb_atom_t maximized_horz =
        intern_atom_for_conn(conn, "_NET_WM_STATE_MAXIMIZED_HORZ", 0);
    xcb_atom_t maximized_vert =
        intern_atom_for_conn(conn, "_NET_WM_STATE_MAXIMIZED_VERT", 0);
    xcb_atom_t hidden = intern_atom_for_conn(conn, "_NET_WM_STATE_HIDDEN", 0);
    if (net_wm_state == XCB_ATOM_NONE ||
        (request->kind == TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE &&
         fullscreen == XCB_ATOM_NONE) ||
        (request->kind == TRIAD_X11_REQUEST_SET_MAXIMIZED_STATE &&
         (maximized_horz == XCB_ATOM_NONE || maximized_vert == XCB_ATOM_NONE)) ||
        (request->kind == TRIAD_X11_REQUEST_SET_HIDDEN_STATE &&
         hidden == XCB_ATOM_NONE)) {
        request_log(log_fn, user_data, "error state atoms unavailable");
        return 1;
    }

    xcb_atom_t *current = NULL;
    uint32_t current_count = 0;
    if (read_wm_state(conn, request->window_id, net_wm_state, &current, &current_count) !=
        0) {
        request_log(
            log_fn,
            user_data,
            "error state window=0x%08x property unavailable",
            request->window_id);
        return 1;
    }

    uint32_t capacity = current_count + 2;
    xcb_atom_t *next = calloc(capacity == 0 ? 1 : capacity, sizeof(xcb_atom_t));
    if (next == NULL) {
        free(current);
        request_log(log_fn, user_data, "error state allocation failed");
        return 1;
    }
    if (current_count > 0)
        memcpy(next, current, (size_t)current_count * sizeof(xcb_atom_t));
    uint32_t next_count = current_count;
    int active = request->values[0] != 0;

    int update_error = 0;
    if (request->kind == TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE) {
        update_error = upsert_state_atom(next, &next_count, capacity, fullscreen, active);
    } else {
        if (request->kind == TRIAD_X11_REQUEST_SET_HIDDEN_STATE) {
            update_error = upsert_state_atom(next, &next_count, capacity, hidden, active);
        } else {
        update_error =
            upsert_state_atom(next, &next_count, capacity, maximized_horz, active);
        if (update_error == 0)
            update_error =
                upsert_state_atom(next, &next_count, capacity, maximized_vert, active);
        }
    }
    if (update_error != 0) {
        free(current);
        free(next);
        request_log(log_fn, user_data, "error state atom capacity exceeded");
        return 1;
    }

    int changed = 0;
    if (request->kind == TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE) {
        changed = state_contains_atom(current, current_count, fullscreen) != active;
    } else {
        if (request->kind == TRIAD_X11_REQUEST_SET_HIDDEN_STATE) {
            changed = state_contains_atom(current, current_count, hidden) != active;
        } else {
        changed = state_contains_atom(current, current_count, maximized_horz) != active ||
            state_contains_atom(current, current_count, maximized_vert) != active;
        }
    }

    xcb_void_cookie_t cookie;
    if (next_count == 0) {
        cookie = xcb_delete_property_checked(conn, request->window_id, net_wm_state);
    } else {
        cookie = xcb_change_property_checked(
            conn,
            XCB_PROP_MODE_REPLACE,
            request->window_id,
            net_wm_state,
            XCB_ATOM_ATOM,
            32,
            next_count,
            next);
    }
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        request_log(
            log_fn,
            user_data,
            "error state window=0x%08x code=%u",
            request->window_id,
            error->error_code);
        free(error);
        free(current);
        free(next);
        return 1;
    }

    const char *name =
        request->kind == TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE ? "fullscreen" :
        request->kind == TRIAD_X11_REQUEST_SET_HIDDEN_STATE ? "hidden" : "maximized";
    request_log(
        log_fn,
        user_data,
        "applied %s window=0x%08x active=%d changed=%d",
        name,
        request->window_id,
        active,
        changed);
    free(current);
    free(next);
    return 0;
}

static int execute_requests_on_connection(
    xcb_connection_t *conn,
    const TriadX11Request *requests,
    uint32_t count,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    int status = 0;
    for (uint32_t i = 0; i < count; i++) {
        const TriadX11Request *request = &requests[i];
        int request_status = 0;
        switch (request->kind) {
        case TRIAD_X11_REQUEST_CONFIGURE_WINDOW:
            request_status = execute_configure_request(conn, request, log_fn, user_data);
            break;
        case TRIAD_X11_REQUEST_SET_INPUT_FOCUS:
            request_status = execute_focus_request(conn, request, log_fn, user_data);
            break;
        case TRIAD_X11_REQUEST_SEND_CLOSE_WINDOW:
            request_status = execute_close_request(conn, request, log_fn, user_data);
            break;
        case TRIAD_X11_REQUEST_MAP_WINDOW:
            request_status = execute_map_request(conn, request, log_fn, user_data);
            break;
        case TRIAD_X11_REQUEST_UNMAP_WINDOW:
            request_status = execute_unmap_request(conn, request, log_fn, user_data);
            break;
        case TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE:
        case TRIAD_X11_REQUEST_SET_MAXIMIZED_STATE:
        case TRIAD_X11_REQUEST_SET_HIDDEN_STATE:
            request_status = execute_state_request(conn, request, log_fn, user_data);
            break;
        default:
            request_log(log_fn, user_data, "error unknown request kind=%u", request->kind);
            request_status = 1;
            break;
        }
        if (request_status != 0)
            status = request_status;
    }
    xcb_flush(conn);
    return status;
}

int triad_x11_execute_requests_on_active_probe(
    const TriadX11Request *requests,
    uint32_t count,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    if (count > 0 && requests == NULL) {
        request_log(log_fn, user_data, "error requests pointer is null");
        return 1;
    }
    if (active_probe == NULL || active_probe->conn == NULL) {
        request_log(log_fn, user_data, "error active probe connection unavailable");
        return 1;
    }

    int status = execute_requests_on_connection(
        active_probe->conn, requests, count, log_fn, user_data);
    request_log(log_fn, user_data, "request execution complete active_probe=1 count=%u", count);
    return status;
}

int triad_x11_execute_requests(
    const char *display_name,
    const TriadX11Request *requests,
    uint32_t count,
    int dry_run,
    triad_x11_log_fn log_fn,
    void *user_data)
{
    if (count > 0 && requests == NULL) {
        request_log(log_fn, user_data, "error requests pointer is null");
        return 1;
    }

    if (dry_run) {
        for (uint32_t i = 0; i < count; i++) {
            const TriadX11Request *request = &requests[i];
            switch (request->kind) {
            case TRIAD_X11_REQUEST_CONFIGURE_WINDOW:
                if (request->value_count < 4) {
                    request_log(
                        log_fn,
                        user_data,
                        "error configure window=0x%08x value_count=%u",
                        request->window_id,
                        request->value_count);
                    return 1;
                }
                request_log(
                    log_fn,
                    user_data,
                    "dry_run configure window=0x%08x x=%d y=%d w=%d h=%d",
                    request->window_id,
                    request->values[0],
                    request->values[1],
                    request->values[2],
                    request->values[3]);
                break;
            case TRIAD_X11_REQUEST_SET_INPUT_FOCUS:
                request_log(log_fn, user_data, "dry_run focus window=0x%08x", request->window_id);
                break;
            case TRIAD_X11_REQUEST_SEND_CLOSE_WINDOW:
                request_log(log_fn, user_data, "dry_run close window=0x%08x", request->window_id);
                break;
            case TRIAD_X11_REQUEST_MAP_WINDOW:
                request_log(log_fn, user_data, "dry_run map window=0x%08x", request->window_id);
                break;
            case TRIAD_X11_REQUEST_UNMAP_WINDOW:
                request_log(log_fn, user_data, "dry_run unmap window=0x%08x", request->window_id);
                break;
            case TRIAD_X11_REQUEST_SET_FULLSCREEN_STATE:
                if (request->value_count < 1) {
                    request_log(
                        log_fn,
                        user_data,
                        "error state window=0x%08x value_count=%u",
                        request->window_id,
                        request->value_count);
                    return 1;
                }
                request_log(
                    log_fn,
                    user_data,
                    "dry_run fullscreen window=0x%08x active=%d",
                    request->window_id,
                    request->values[0] != 0);
                break;
            case TRIAD_X11_REQUEST_SET_MAXIMIZED_STATE:
                if (request->value_count < 1) {
                    request_log(
                        log_fn,
                        user_data,
                        "error state window=0x%08x value_count=%u",
                        request->window_id,
                        request->value_count);
                    return 1;
                }
                request_log(
                    log_fn,
                    user_data,
                    "dry_run maximized window=0x%08x active=%d",
                    request->window_id,
                    request->values[0] != 0);
                break;
            case TRIAD_X11_REQUEST_SET_HIDDEN_STATE:
                if (request->value_count < 1) {
                    request_log(
                        log_fn,
                        user_data,
                        "error state window=0x%08x value_count=%u",
                        request->window_id,
                        request->value_count);
                    return 1;
                }
                request_log(
                    log_fn,
                    user_data,
                    "dry_run hidden window=0x%08x active=%d",
                    request->window_id,
                    request->values[0] != 0);
                break;
            default:
                request_log(log_fn, user_data, "error unknown request kind=%u", request->kind);
                return 1;
            }
        }
        request_log(log_fn, user_data, "request execution complete dry_run=1 count=%u", count);
        return 0;
    }

    int screen_number = 0;
    xcb_connection_t *conn = xcb_connect(display_name, &screen_number);
    if (xcb_connection_has_error(conn)) {
        request_log(log_fn, user_data, "error failed to connect to X display");
        if (conn != NULL)
            xcb_disconnect(conn);
        return 1;
    }

    int status = execute_requests_on_connection(conn, requests, count, log_fn, user_data);
    xcb_disconnect(conn);
    request_log(log_fn, user_data, "request execution complete dry_run=0 count=%u", count);
    return status;
}
