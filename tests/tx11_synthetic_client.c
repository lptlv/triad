#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <xcb/xcb.h>

static xcb_atom_t intern_atom(xcb_connection_t *conn, const char *name)
{
    xcb_intern_atom_cookie_t cookie =
        xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(conn, cookie, NULL);
    if (reply == NULL)
        return XCB_ATOM_NONE;
    xcb_atom_t atom = reply->atom;
    free(reply);
    return atom;
}

static int set_text_property(
    xcb_connection_t *conn,
    xcb_window_t win,
    xcb_atom_t property,
    xcb_atom_t type,
    const char *value)
{
    xcb_void_cookie_t cookie = xcb_change_property_checked(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        property,
        type,
        8,
        (uint32_t)strlen(value),
        value);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        fprintf(stderr, "tx11_synthetic_client: property error=%u\n", error->error_code);
        free(error);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *display = argc > 1 ? argv[1] : NULL;
    int screen_number = 0;
    xcb_connection_t *conn = xcb_connect(display, &screen_number);
    if (xcb_connection_has_error(conn)) {
        fprintf(stderr, "tx11_synthetic_client: failed to connect\n");
        if (conn != NULL)
            xcb_disconnect(conn);
        return 1;
    }

    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_iterator_t iter = xcb_setup_roots_iterator(setup);
    for (int i = 0; iter.rem > 0 && i < screen_number; i++)
        xcb_screen_next(&iter);
    if (iter.rem == 0) {
        fprintf(stderr, "tx11_synthetic_client: failed to resolve screen\n");
        xcb_disconnect(conn);
        return 1;
    }

    xcb_screen_t *screen = iter.data;
    xcb_atom_t wm_class = intern_atom(conn, "WM_CLASS");
    xcb_atom_t wm_name = intern_atom(conn, "WM_NAME");
    xcb_atom_t net_wm_name = intern_atom(conn, "_NET_WM_NAME");
    xcb_atom_t net_wm_pid = intern_atom(conn, "_NET_WM_PID");
    xcb_atom_t utf8_string = intern_atom(conn, "UTF8_STRING");
    xcb_atom_t cardinal = intern_atom(conn, "CARDINAL");
    if (
        wm_class == XCB_ATOM_NONE || wm_name == XCB_ATOM_NONE ||
        net_wm_name == XCB_ATOM_NONE || net_wm_pid == XCB_ATOM_NONE ||
        utf8_string == XCB_ATOM_NONE || cardinal == XCB_ATOM_NONE) {
        fprintf(stderr, "tx11_synthetic_client: failed to intern atoms\n");
        xcb_disconnect(conn);
        return 1;
    }

    xcb_window_t win = xcb_generate_id(conn);
    uint32_t values[] = {screen->black_pixel};
    xcb_void_cookie_t create_cookie = xcb_create_window_checked(
        conn,
        XCB_COPY_FROM_PARENT,
        win,
        screen->root,
        32,
        48,
        320,
        200,
        0,
        XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen->root_visual,
        XCB_CW_BACK_PIXEL,
        values);
    xcb_generic_error_t *create_error = xcb_request_check(conn, create_cookie);
    if (create_error != NULL) {
        fprintf(stderr, "tx11_synthetic_client: create error=%u\n", create_error->error_code);
        free(create_error);
        xcb_disconnect(conn);
        return 1;
    }

    const char wm_class_value[] = "triad-smoke\0triad-smoke";
    xcb_change_property(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        wm_class,
        XCB_ATOM_STRING,
        8,
        sizeof(wm_class_value) - 1,
        wm_class_value);

    uint32_t pid = (uint32_t)getpid();
    xcb_change_property(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        net_wm_pid,
        cardinal,
        32,
        1,
        &pid);

    if (
        set_text_property(conn, win, wm_name, XCB_ATOM_STRING, "triad smoke") ||
        set_text_property(conn, win, net_wm_name, utf8_string, "triad smoke")) {
        xcb_destroy_window(conn, win);
        xcb_disconnect(conn);
        return 1;
    }

    xcb_map_window(conn, win);
    xcb_flush(conn);
    usleep(200000);

    uint32_t configure_mask = XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y |
        XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT;
    uint32_t configure_values[] = {80, 96, 360, 240};
    xcb_configure_window(conn, win, configure_mask, configure_values);
    xcb_flush(conn);
    usleep(200000);

    if (set_text_property(conn, win, net_wm_name, utf8_string, "triad smoke updated")) {
        xcb_destroy_window(conn, win);
        xcb_disconnect(conn);
        return 1;
    }
    xcb_flush(conn);
    usleep(200000);

    xcb_destroy_window(conn, win);
    xcb_flush(conn);
    usleep(100000);

    xcb_disconnect(conn);
    return 0;
}
