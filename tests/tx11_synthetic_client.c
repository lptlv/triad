#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <xcb/xcb.h>
#include <xcb/xkb.h>

#ifdef TRIAD_X11_XTEST
#include <xcb/xtest.h>

static xcb_keycode_t keycode_for_keysym(xcb_connection_t *conn, uint32_t keysym)
{
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_keycode_t min_keycode = setup->min_keycode;
    xcb_keycode_t max_keycode = setup->max_keycode;
    uint8_t count = (uint8_t)(max_keycode - min_keycode + 1);
    xcb_get_keyboard_mapping_cookie_t cookie =
        xcb_get_keyboard_mapping(conn, min_keycode, count);
    xcb_get_keyboard_mapping_reply_t *reply =
        xcb_get_keyboard_mapping_reply(conn, cookie, NULL);
    if (reply == NULL)
        return 0;

    xcb_keysym_t *keysyms = xcb_get_keyboard_mapping_keysyms(reply);
    int per_keycode = reply->keysyms_per_keycode;
    xcb_keycode_t result = 0;
    for (uint16_t keycode = min_keycode; keycode <= max_keycode && result == 0; keycode++) {
        int offset = (keycode - min_keycode) * per_keycode;
        for (int level = 0; level < per_keycode; level++) {
            if (keysyms[offset + level] == keysym) {
                result = (xcb_keycode_t)keycode;
                break;
            }
        }
    }

    free(reply);
    return result;
}
#endif

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

static int set_atom_property(
    xcb_connection_t *conn,
    xcb_window_t win,
    xcb_atom_t property,
    xcb_atom_t value)
{
    xcb_void_cookie_t cookie = xcb_change_property_checked(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        property,
        XCB_ATOM_ATOM,
        32,
        1,
        &value);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        fprintf(stderr, "tx11_synthetic_client: atom property error=%u\n", error->error_code);
        free(error);
        return 1;
    }
    return 0;
}

static xcb_screen_t *screen_for_connection(xcb_connection_t *conn, int screen_number)
{
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_iterator_t iter = xcb_setup_roots_iterator(setup);
    for (int i = 0; iter.rem > 0 && i < screen_number; i++)
        xcb_screen_next(&iter);
    if (iter.rem == 0)
        return NULL;
    return iter.data;
}

#ifdef TRIAD_X11_XTEST
static int fake_input_at(
    xcb_connection_t *conn,
    xcb_screen_t *screen,
    uint8_t type,
    xcb_keycode_t keycode,
    int16_t x,
    int16_t y)
{
    xcb_void_cookie_t cookie = xcb_test_fake_input_checked(
        conn, type, keycode, XCB_CURRENT_TIME, screen->root, x, y, 0);
    xcb_generic_error_t *error = xcb_request_check(conn, cookie);
    if (error != NULL) {
        fprintf(stderr, "tx11_synthetic_client: fake input error=%u\n", error->error_code);
        free(error);
        return 1;
    }
    xcb_flush(conn);
    usleep(20000);
    return 0;
}

static int fake_input(
    xcb_connection_t *conn,
    xcb_screen_t *screen,
    uint8_t type,
    xcb_keycode_t keycode)
{
    return fake_input_at(conn, screen, type, keycode, 0, 0);
}

static int modifier_keysyms(uint32_t modifiers, uint32_t keysyms[6])
{
    int count = 0;
    if ((modifiers & XCB_MOD_MASK_SHIFT) != 0)
        keysyms[count++] = 0xffe1; /* Shift_L */
    if ((modifiers & XCB_MOD_MASK_CONTROL) != 0)
        keysyms[count++] = 0xffe3; /* Control_L */
    if ((modifiers & XCB_MOD_MASK_1) != 0)
        keysyms[count++] = 0xffe9; /* Alt_L */
    if ((modifiers & XCB_MOD_MASK_3) != 0)
        keysyms[count++] = 0xffed; /* Hyper_L */
    if ((modifiers & XCB_MOD_MASK_4) != 0)
        keysyms[count++] = 0xffeb; /* Super_L */
    if ((modifiers & XCB_MOD_MASK_5) != 0)
        keysyms[count++] = 0xfe03; /* ISO_Level3_Shift */
    return count;
}

static int fake_keypress(
    xcb_connection_t *conn,
    xcb_screen_t *screen,
    uint32_t keysym,
    uint32_t modifiers)
{
    xcb_keycode_t keycode = keycode_for_keysym(conn, keysym);
    if (keycode == 0) {
        fprintf(stderr, "tx11_synthetic_client: keysym unavailable=0x%08x\n", keysym);
        return 1;
    }

    uint32_t mod_keysyms[6];
    xcb_keycode_t mod_keycodes[6];
    int mod_count = modifier_keysyms(modifiers, mod_keysyms);
    for (int i = 0; i < mod_count; i++) {
        mod_keycodes[i] = keycode_for_keysym(conn, mod_keysyms[i]);
        if (mod_keycodes[i] == 0) {
            fprintf(
                stderr,
                "tx11_synthetic_client: modifier keysym unavailable=0x%08x\n",
                mod_keysyms[i]);
            return 1;
        }
    }

    for (int i = 0; i < mod_count; i++) {
        if (fake_input(conn, screen, XCB_KEY_PRESS, mod_keycodes[i]) != 0)
            return 1;
    }
    if (fake_input(conn, screen, XCB_KEY_PRESS, keycode) != 0)
        return 1;
    if (fake_input(conn, screen, XCB_KEY_RELEASE, keycode) != 0)
        return 1;
    for (int i = mod_count - 1; i >= 0; i--) {
        if (fake_input(conn, screen, XCB_KEY_RELEASE, mod_keycodes[i]) != 0)
            return 1;
    }

    printf("fake-key keysym=0x%08x keycode=%u modifiers=0x%04x\n", keysym, keycode, modifiers);
    fflush(stdout);
    return 0;
}

static int fake_button_press(
    xcb_connection_t *conn,
    xcb_screen_t *screen,
    uint32_t button,
    uint32_t modifiers)
{
    if (button == 0 || button > UINT8_MAX) {
        fprintf(stderr, "tx11_synthetic_client: invalid button=%u\n", button);
        return 1;
    }

    uint32_t mod_keysyms[6];
    xcb_keycode_t mod_keycodes[6];
    int mod_count = modifier_keysyms(modifiers, mod_keysyms);
    for (int i = 0; i < mod_count; i++) {
        mod_keycodes[i] = keycode_for_keysym(conn, mod_keysyms[i]);
        if (mod_keycodes[i] == 0) {
            fprintf(
                stderr,
                "tx11_synthetic_client: modifier keysym unavailable=0x%08x\n",
                mod_keysyms[i]);
            return 1;
        }
    }

    for (int i = 0; i < mod_count; i++) {
        if (fake_input(conn, screen, XCB_KEY_PRESS, mod_keycodes[i]) != 0)
            return 1;
    }
    if (fake_input(conn, screen, XCB_BUTTON_PRESS, (xcb_keycode_t)button) != 0)
        return 1;
    if (fake_input(conn, screen, XCB_BUTTON_RELEASE, (xcb_keycode_t)button) != 0)
        return 1;
    for (int i = mod_count - 1; i >= 0; i--) {
        if (fake_input(conn, screen, XCB_KEY_RELEASE, mod_keycodes[i]) != 0)
            return 1;
    }

    printf("fake-button button=%u modifiers=0x%04x\n", button, modifiers);
    fflush(stdout);
    return 0;
}

static int fake_drag(
    xcb_connection_t *conn,
    xcb_screen_t *screen,
    uint32_t button,
    uint32_t modifiers,
    int16_t start_x,
    int16_t start_y,
    int16_t end_x,
    int16_t end_y)
{
    if (button == 0 || button > UINT8_MAX) {
        fprintf(stderr, "tx11_synthetic_client: invalid button=%u\n", button);
        return 1;
    }

    uint32_t mod_keysyms[6];
    xcb_keycode_t mod_keycodes[6];
    int mod_count = modifier_keysyms(modifiers, mod_keysyms);
    for (int i = 0; i < mod_count; i++) {
        mod_keycodes[i] = keycode_for_keysym(conn, mod_keysyms[i]);
        if (mod_keycodes[i] == 0) {
            fprintf(
                stderr,
                "tx11_synthetic_client: modifier keysym unavailable=0x%08x\n",
                mod_keysyms[i]);
            return 1;
        }
    }

    if (fake_input_at(conn, screen, XCB_MOTION_NOTIFY, 0, start_x, start_y) != 0)
        return 1;
    for (int i = 0; i < mod_count; i++) {
        if (fake_input_at(conn, screen, XCB_KEY_PRESS, mod_keycodes[i], start_x, start_y) != 0)
            return 1;
    }
    if (fake_input_at(conn, screen, XCB_BUTTON_PRESS, (xcb_keycode_t)button, start_x, start_y) != 0)
        return 1;
    if (fake_input_at(conn, screen, XCB_MOTION_NOTIFY, 0, end_x, end_y) != 0)
        return 1;
    if (fake_input_at(conn, screen, XCB_BUTTON_RELEASE, (xcb_keycode_t)button, end_x, end_y) != 0)
        return 1;
    for (int i = mod_count - 1; i >= 0; i--) {
        if (fake_input_at(conn, screen, XCB_KEY_RELEASE, mod_keycodes[i], end_x, end_y) != 0)
            return 1;
    }

    printf(
        "fake-drag button=%u modifiers=0x%04x start=%d,%d end=%d,%d\n",
        button,
        modifiers,
        start_x,
        start_y,
        end_x,
        end_y);
    fflush(stdout);
    return 0;
}
#endif

static int wait_for_close(
    xcb_connection_t *conn,
    xcb_window_t win,
    xcb_atom_t wm_protocols,
    xcb_atom_t wm_delete_window)
{
    while (1) {
        xcb_generic_event_t *event = xcb_wait_for_event(conn);
        if (event == NULL)
            return 1;
        uint8_t type = event->response_type & ~0x80;
        if (type == XCB_CLIENT_MESSAGE) {
            xcb_client_message_event_t *client = (xcb_client_message_event_t *)event;
            if (
                client->window == win && client->type == wm_protocols &&
                client->data.data32[0] == wm_delete_window) {
                free(event);
                return 0;
            }
        } else if (type == XCB_CONFIGURE_NOTIFY) {
            xcb_configure_notify_event_t *configure =
                (xcb_configure_notify_event_t *)event;
            if (configure->window == win) {
                printf(
                    "configure=%ux%u+%d+%d\n",
                    configure->width,
                    configure->height,
                    configure->x,
                    configure->y);
                fflush(stdout);
            }
        } else if (type == XCB_DESTROY_NOTIFY) {
            xcb_destroy_notify_event_t *destroy = (xcb_destroy_notify_event_t *)event;
            if (destroy->window == win) {
                free(event);
                return 0;
            }
        }
        free(event);
    }
}

int main(int argc, char **argv)
{
    const char *display = argc > 1 ? argv[1] : NULL;
    int fake_key = argc > 2 && strcmp(argv[2], "--fake-key") == 0;
    int fake_button = argc > 2 && strcmp(argv[2], "--fake-button") == 0;
    int fake_drag_requested = argc > 2 && strcmp(argv[2], "--fake-drag") == 0;
    int send_mapping_notify = argc > 2 && strcmp(argv[2], "--send-mapping-notify") == 0;
    int send_xkb_state = argc > 2 && strcmp(argv[2], "--send-xkb-state") == 0;
    int hold = argc > 2 &&
        (strcmp(argv[2], "--hold") == 0 || strcmp(argv[2], "--managed-hold") == 0);
    int override_redirect = argc > 2 && strcmp(argv[2], "--hold") == 0;
    int screen_number = 0;
    xcb_connection_t *conn = xcb_connect(display, &screen_number);
    if (xcb_connection_has_error(conn)) {
        fprintf(stderr, "tx11_synthetic_client: failed to connect\n");
        if (conn != NULL)
            xcb_disconnect(conn);
        return 1;
    }

    xcb_screen_t *screen = screen_for_connection(conn, screen_number);
    if (screen == NULL) {
        fprintf(stderr, "tx11_synthetic_client: failed to resolve screen\n");
        xcb_disconnect(conn);
        return 1;
    }
    if (send_mapping_notify) {
        xcb_mapping_notify_event_t event;
        memset(&event, 0, sizeof(event));
        event.response_type = XCB_MAPPING_NOTIFY;
        event.request = XCB_MAPPING_KEYBOARD;
        event.first_keycode = 8;
        event.count = 1;
        xcb_void_cookie_t cookie = xcb_send_event_checked(
            conn,
            0,
            screen->root,
            XCB_EVENT_MASK_STRUCTURE_NOTIFY,
            (const char *)&event);
        xcb_generic_error_t *error = xcb_request_check(conn, cookie);
        if (error != NULL) {
            fprintf(
                stderr,
                "tx11_synthetic_client: mapping notify send error=%u\n",
                error->error_code);
            free(error);
            xcb_disconnect(conn);
            return 1;
        }
        xcb_flush(conn);
        printf(
            "send-mapping-notify request=%u first_keycode=%u count=%u\n",
            event.request,
            event.first_keycode,
            event.count);
        xcb_disconnect(conn);
        return 0;
    }
    if (send_xkb_state) {
        const xcb_query_extension_reply_t *xkb_ext =
            xcb_get_extension_data(conn, &xcb_xkb_id);
        if (xkb_ext == NULL || !xkb_ext->present) {
            fprintf(stderr, "tx11_synthetic_client: xkb unavailable\n");
            xcb_disconnect(conn);
            return 1;
        }
        xcb_xkb_use_extension_cookie_t use_cookie =
            xcb_xkb_use_extension(conn, XCB_XKB_MAJOR_VERSION, XCB_XKB_MINOR_VERSION);
        xcb_generic_error_t *use_error = NULL;
        xcb_xkb_use_extension_reply_t *use_reply =
            xcb_xkb_use_extension_reply(conn, use_cookie, &use_error);
        if (use_error != NULL) {
            fprintf(
                stderr,
                "tx11_synthetic_client: xkb use-extension error=%u\n",
                use_error->error_code);
            free(use_error);
            xcb_disconnect(conn);
            return 1;
        }
        if (use_reply == NULL || !use_reply->supported) {
            fprintf(stderr, "tx11_synthetic_client: xkb unsupported\n");
            free(use_reply);
            xcb_disconnect(conn);
            return 1;
        }
        free(use_reply);

        xcb_void_cookie_t lock_cookie = xcb_xkb_latch_lock_state_checked(
            conn,
            XCB_XKB_ID_USE_CORE_KBD,
            XCB_MOD_MASK_LOCK,
            XCB_MOD_MASK_LOCK,
            0,
            0,
            0,
            0,
            0);
        xcb_generic_error_t *lock_error = xcb_request_check(conn, lock_cookie);
        if (lock_error != NULL) {
            fprintf(
                stderr,
                "tx11_synthetic_client: xkb lock-state error=%u\n",
                lock_error->error_code);
            free(lock_error);
            xcb_disconnect(conn);
            return 1;
        }

        xcb_void_cookie_t unlock_cookie = xcb_xkb_latch_lock_state_checked(
            conn,
            XCB_XKB_ID_USE_CORE_KBD,
            XCB_MOD_MASK_LOCK,
            0,
            0,
            0,
            0,
            0,
            0);
        xcb_generic_error_t *unlock_error = xcb_request_check(conn, unlock_cookie);
        if (unlock_error != NULL) {
            fprintf(
                stderr,
                "tx11_synthetic_client: xkb unlock-state error=%u\n",
                unlock_error->error_code);
            free(unlock_error);
            xcb_disconnect(conn);
            return 1;
        }
        xcb_flush(conn);
        printf("send-xkb-state affect_mod_locks=0x%02x\n", XCB_MOD_MASK_LOCK);
        xcb_disconnect(conn);
        return 0;
    }
    if (fake_key) {
        if (argc < 5) {
            fprintf(stderr, "tx11_synthetic_client: --fake-key requires keysym modifiers\n");
            xcb_disconnect(conn);
            return 1;
        }
#ifdef TRIAD_X11_XTEST
        uint32_t keysym = (uint32_t)strtoul(argv[3], NULL, 0);
        uint32_t modifiers = (uint32_t)strtoul(argv[4], NULL, 0);
        int status = fake_keypress(conn, screen, keysym, modifiers);
        xcb_disconnect(conn);
        return status;
#else
        fprintf(stderr, "tx11_synthetic_client: XTEST support not compiled\n");
        xcb_disconnect(conn);
        return 1;
#endif
    }
    if (fake_button) {
        if (argc < 5) {
            fprintf(stderr, "tx11_synthetic_client: --fake-button requires button modifiers\n");
            xcb_disconnect(conn);
            return 1;
        }
#ifdef TRIAD_X11_XTEST
        uint32_t button = (uint32_t)strtoul(argv[3], NULL, 0);
        uint32_t modifiers = (uint32_t)strtoul(argv[4], NULL, 0);
        int status = fake_button_press(conn, screen, button, modifiers);
        xcb_disconnect(conn);
        return status;
#else
        fprintf(stderr, "tx11_synthetic_client: XTEST support not compiled\n");
        xcb_disconnect(conn);
        return 1;
#endif
    }
    if (fake_drag_requested) {
        if (argc < 9) {
            fprintf(
                stderr,
                "tx11_synthetic_client: --fake-drag requires button modifiers start-x start-y end-x end-y\n");
            xcb_disconnect(conn);
            return 1;
        }
#ifdef TRIAD_X11_XTEST
        uint32_t button = (uint32_t)strtoul(argv[3], NULL, 0);
        uint32_t modifiers = (uint32_t)strtoul(argv[4], NULL, 0);
        int16_t start_x = (int16_t)strtol(argv[5], NULL, 0);
        int16_t start_y = (int16_t)strtol(argv[6], NULL, 0);
        int16_t end_x = (int16_t)strtol(argv[7], NULL, 0);
        int16_t end_y = (int16_t)strtol(argv[8], NULL, 0);
        int status = fake_drag(
            conn, screen, button, modifiers, start_x, start_y, end_x, end_y);
        xcb_disconnect(conn);
        return status;
#else
        fprintf(stderr, "tx11_synthetic_client: XTEST support not compiled\n");
        xcb_disconnect(conn);
        return 1;
#endif
    }
    xcb_atom_t wm_class = intern_atom(conn, "WM_CLASS");
    xcb_atom_t wm_name = intern_atom(conn, "WM_NAME");
    xcb_atom_t wm_protocols = intern_atom(conn, "WM_PROTOCOLS");
    xcb_atom_t wm_delete_window = intern_atom(conn, "WM_DELETE_WINDOW");
    xcb_atom_t net_wm_name = intern_atom(conn, "_NET_WM_NAME");
    xcb_atom_t net_wm_pid = intern_atom(conn, "_NET_WM_PID");
    xcb_atom_t net_wm_state = intern_atom(conn, "_NET_WM_STATE");
    xcb_atom_t net_wm_state_fullscreen = intern_atom(conn, "_NET_WM_STATE_FULLSCREEN");
    xcb_atom_t net_wm_state_maximized_horz =
        intern_atom(conn, "_NET_WM_STATE_MAXIMIZED_HORZ");
    xcb_atom_t net_wm_state_demands_attention =
        intern_atom(conn, "_NET_WM_STATE_DEMANDS_ATTENTION");
    xcb_atom_t net_wm_window_type = intern_atom(conn, "_NET_WM_WINDOW_TYPE");
    xcb_atom_t net_wm_window_type_dialog =
        intern_atom(conn, "_NET_WM_WINDOW_TYPE_DIALOG");
    xcb_atom_t utf8_string = intern_atom(conn, "UTF8_STRING");
    xcb_atom_t cardinal = intern_atom(conn, "CARDINAL");
    if (
        wm_class == XCB_ATOM_NONE || wm_name == XCB_ATOM_NONE ||
        wm_protocols == XCB_ATOM_NONE || wm_delete_window == XCB_ATOM_NONE ||
        net_wm_name == XCB_ATOM_NONE || net_wm_pid == XCB_ATOM_NONE ||
        net_wm_state == XCB_ATOM_NONE ||
        net_wm_state_fullscreen == XCB_ATOM_NONE ||
        net_wm_state_maximized_horz == XCB_ATOM_NONE ||
        net_wm_state_demands_attention == XCB_ATOM_NONE ||
        net_wm_window_type == XCB_ATOM_NONE ||
        net_wm_window_type_dialog == XCB_ATOM_NONE ||
        utf8_string == XCB_ATOM_NONE || cardinal == XCB_ATOM_NONE) {
        fprintf(stderr, "tx11_synthetic_client: failed to intern atoms\n");
        xcb_disconnect(conn);
        return 1;
    }

    xcb_window_t win = xcb_generate_id(conn);
    uint32_t event_mask = XCB_EVENT_MASK_STRUCTURE_NOTIFY | XCB_EVENT_MASK_FOCUS_CHANGE;
    uint32_t value_mask =
        XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK |
        (override_redirect ? XCB_CW_OVERRIDE_REDIRECT : 0);
    uint32_t values[3];
    values[0] = screen->black_pixel;
    if (override_redirect) {
        values[1] = 1;
        values[2] = event_mask;
    } else {
        values[1] = event_mask;
    }
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
        value_mask,
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
    xcb_change_property(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        wm_protocols,
        XCB_ATOM_ATOM,
        32,
        1,
        &wm_delete_window);

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

    if (set_atom_property(conn, win, net_wm_window_type, net_wm_window_type_dialog)) {
        xcb_destroy_window(conn, win);
        xcb_disconnect(conn);
        return 1;
    }
    xcb_flush(conn);
    usleep(200000);

    if (hold) {
        printf("window=0x%08x\n", win);
        fflush(stdout);
        int status = wait_for_close(conn, win, wm_protocols, wm_delete_window);
        xcb_destroy_window(conn, win);
        xcb_flush(conn);
        xcb_disconnect(conn);
        return status;
    }

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

    xcb_atom_t states[] = {
        net_wm_state_fullscreen,
        net_wm_state_maximized_horz,
        net_wm_state_demands_attention,
    };
    xcb_change_property(
        conn,
        XCB_PROP_MODE_REPLACE,
        win,
        net_wm_state,
        XCB_ATOM_ATOM,
        32,
        sizeof(states) / sizeof(states[0]),
        states);
    xcb_flush(conn);
    usleep(200000);

    xcb_destroy_window(conn, win);
    xcb_flush(conn);
    usleep(100000);

    xcb_disconnect(conn);
    return 0;
}
