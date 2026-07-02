#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <xcb/randr.h>
#include <xcb/xcb.h>
#include <xcb/xcb_icccm.h>
#include <xcb/xcb_ewmh.h>

typedef void (*triad_x11_log_fn)(void *user_data, const char *message);

typedef enum TriadX11RequestKind {
    TRIAD_X11_REQUEST_CONFIGURE_WINDOW = 0,
    TRIAD_X11_REQUEST_SET_INPUT_FOCUS = 1,
    TRIAD_X11_REQUEST_SEND_CLOSE_WINDOW = 2,
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

typedef void (*triad_x11_event_fn)(void *user_data, const TriadX11Event *event);

typedef struct TriadX11Atoms {
    xcb_atom_t wm_protocols;
    xcb_atom_t wm_delete_window;
    xcb_atom_t wm_class;
    xcb_atom_t wm_name;
    xcb_atom_t net_wm_name;
    xcb_atom_t net_wm_pid;
    xcb_atom_t net_wm_state;
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
    TriadX11Atoms atoms;
    triad_x11_log_fn log;
    triad_x11_event_fn event;
    void *log_user_data;
} TriadX11Probe;

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
    if (probe->event != NULL)
        probe->event(probe->log_user_data, event);
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
    default:
        return "Unknown";
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

static void log_window(TriadX11Probe *probe, xcb_window_t win, const char *source)
{
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
    event.kind = TRIAD_X11_EVENT_WINDOW_DISCOVERED;
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
        log_window(probe, children[i], "startup");
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

static void log_event(TriadX11Probe *probe, xcb_generic_event_t *event)
{
    uint8_t type = event->response_type & 0x7f;
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
        log_window(probe, ev->window, "map-request");
        break;
    }
    case XCB_UNMAP_NOTIFY: {
        xcb_unmap_notify_event_t *ev = (xcb_unmap_notify_event_t *)event;
        probe_log(
            probe,
            "event %s event=0x%08x window=0x%08x from_configure=%u",
            event_name(type),
            ev->event,
            ev->window,
            ev->from_configure);
        TriadX11Event event;
        memset(&event, 0, sizeof(event));
        event.kind = TRIAD_X11_EVENT_WINDOW_UNMAPPED;
        event.id = ev->window;
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

    init_atoms(&probe);
    if (!claim_wm(&probe)) {
        if (probe.ewmh_ready)
            xcb_ewmh_connection_wipe(&probe.ewmh);
        xcb_disconnect(probe.conn);
        return 2;
    }

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

    probe_log(&probe, "event loop started");
    while (1) {
        xcb_generic_event_t *event = xcb_wait_for_event(probe.conn);
        if (event == NULL) {
            int err = xcb_connection_has_error(probe.conn);
            probe_log(&probe, "event loop stopped connection_error=%d", err);
            break;
        }
        log_event(&probe, event);
        free(event);
        xcb_flush(probe.conn);
    }

    if (probe.ewmh_ready)
        xcb_ewmh_connection_wipe(&probe.ewmh);
    xcb_disconnect(probe.conn);
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
        default:
            request_log(log_fn, user_data, "error unknown request kind=%u", request->kind);
            request_status = 1;
            break;
        }
        if (request_status != 0)
            status = request_status;
    }
    xcb_flush(conn);
    xcb_disconnect(conn);
    request_log(log_fn, user_data, "request execution complete dry_run=0 count=%u", count);
    return status;
}
