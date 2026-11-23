/* Direct Xlib bindings: policy and window bookkeeping live in OCaml.
 * No OCaml value may survive an allocation without a CAMLparam/CAMLlocal root.
 * Store_field writes only freshly allocated, rooted records/variants below. */
#define _POSIX_C_SOURCE 200809L
/* XKB has declarations named Atom(...), which collide with OCaml's Atom macro.
 * Parse all X headers before the OCaml runtime headers. */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/extensions/Xrandr.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/threads.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

enum {
  A_PROTOCOLS, A_DELETE, A_TYPE, A_DIALOG, A_UTILITY, A_SPLASH,
  A_TOOLBAR, A_MENU, A_STATE, A_COUNT
};

typedef struct {
  KeyCode code;
  unsigned int mask;
  unsigned int requested_mask;
  KeySym sym;
} key_grab_t;

typedef struct {
  Display *dpy;
  Window root;
  int screen;
  int randr;
  int rr_event_base;
  unsigned int numlock_mask;
  Atom atoms[A_COUNT];
  key_grab_t *grabs;
  size_t grab_count;
} mlwm_x11_t;

#define Context(v) (*(mlwm_x11_t **)Data_custom_val(v))

static mlwm_x11_t *context(value v) {
  mlwm_x11_t *ctx = Context(v);
  if (ctx == NULL || ctx->dpy == NULL)
    caml_failwith("X11 display is closed");
  return ctx;
}

static void close_context(mlwm_x11_t *ctx) {
  if (ctx != NULL && ctx->dpy != NULL) {
    XCloseDisplay(ctx->dpy);
    ctx->dpy = NULL;
    free(ctx->grabs);
    ctx->grabs = NULL;
    ctx->grab_count = 0;
  }
}

static void finalize_display(value v) {
  close_context(Context(v));
  free(Context(v));
  Context(v) = NULL;
}

static struct custom_operations display_ops = {
  .identifier = "mlwm.x11.display",
  .finalize = finalize_display,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
  .fixed_length = custom_fixed_length_default
};

static int startup_error;

static int startup_error_handler(Display *dpy, XErrorEvent *error) {
  (void)dpy;
  (void)error;
  startup_error = 1;
  return 0;
}

static int log_error(Display *dpy, XErrorEvent *error) {
  char message[256];
  XGetErrorText(dpy, error->error_code, message, sizeof message);
  /* Clients can vanish between a query and a request; BadWindow is recoverable. */
  fprintf(stderr, "mlwm: X11 %s (request %u.%u, resource 0x%lx)\n",
          message, error->request_code, error->minor_code, error->resourceid);
  return 0;
}

static void reap_children(int signal_number) {
  int saved_errno = errno;
  (void)signal_number;
  while (waitpid(-1, NULL, WNOHANG) > 0) {}
  errno = saved_errno;
}

CAMLprim value mlwm_x11_open(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(handle);
  static char *atom_names[A_COUNT] = {
    "WM_PROTOCOLS", "WM_DELETE_WINDOW", "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_DIALOG", "_NET_WM_WINDOW_TYPE_UTILITY",
    "_NET_WM_WINDOW_TYPE_SPLASH", "_NET_WM_WINDOW_TYPE_TOOLBAR",
    "_NET_WM_WINDOW_TYPE_MENU", "WM_STATE"
  };
  /* Allocate the finalizable owner before acquiring any external resources. */
  handle = caml_alloc_custom(&display_ops, sizeof(mlwm_x11_t *), 0, 1);
  Context(handle) = NULL;
  mlwm_x11_t *ctx = calloc(1, sizeof *ctx);
  if (ctx == NULL) caml_raise_out_of_memory();
  Context(handle) = ctx;
  ctx->dpy = XOpenDisplay(NULL);
  if (ctx->dpy == NULL) caml_failwith("cannot open X11 display");
  int fd = ConnectionNumber(ctx->dpy);
  int flags = fcntl(fd, F_GETFD);
  if (flags == -1 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == -1) {
    close_context(ctx);
    caml_failwith("cannot set close-on-exec on X11 socket");
  }
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = reap_children;
  action.sa_flags = SA_RESTART | SA_NOCLDSTOP;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGCHLD, &action, NULL) == -1) {
    close_context(ctx);
    caml_failwith("cannot install SIGCHLD reaper");
  }
  ctx->screen = DefaultScreen(ctx->dpy);
  ctx->root = RootWindow(ctx->dpy, ctx->screen);
  /* Selecting redirect is asynchronous: XSync must run under the trap. */
  startup_error = 0;
  XErrorHandler previous = XSetErrorHandler(startup_error_handler);
  XSelectInput(ctx->dpy, ctx->root, SubstructureRedirectMask |
               SubstructureNotifyMask | PropertyChangeMask);
  XSync(ctx->dpy, False);
  if (startup_error) {
    close_context(ctx);
    XSetErrorHandler(previous);
    caml_failwith("another window manager is already running");
  }
  XSetErrorHandler(log_error);
  XInternAtoms(ctx->dpy, atom_names, A_COUNT, False, ctx->atoms);
  int rr_error_base;
  ctx->randr = XRRQueryExtension(ctx->dpy, &ctx->rr_event_base, &rr_error_base);
  if (ctx->randr)
    XRRSelectInput(ctx->dpy, ctx->root, RRScreenChangeNotifyMask |
                   RROutputChangeNotifyMask | RRCrtcChangeNotifyMask);
  CAMLreturn(handle);
}

CAMLprim value mlwm_x11_close(value handle) {
  CAMLparam1(handle);
  close_context(Context(handle));
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_flush(value handle) {
  CAMLparam1(handle);
  XFlush(context(handle)->dpy);
  CAMLreturn(Val_unit);
}

static value rectangle(int x, int y, int width, int height) {
  CAMLparam0();
  CAMLlocal1(result);
  result = caml_alloc(4, 0);
  Store_field(result, 0, Val_int(x));
  Store_field(result, 1, Val_int(y));
  Store_field(result, 2, Val_int(width));
  Store_field(result, 3, Val_int(height));
  CAMLreturn(result);
}

static value output_info(unsigned long id, const char *name, size_t name_length,
                         int x, int y, int width, int height, int primary) {
  CAMLparam0();
  CAMLlocal3(result, geometry, label);
  geometry = rectangle(x, y, width, height);
  label = caml_alloc_initialized_string(name_length, name);
  result = caml_alloc(4, 0);
  Store_field(result, 0, Val_long(id));
  Store_field(result, 1, label);
  Store_field(result, 2, geometry);
  Store_field(result, 3, Val_bool(primary));
  CAMLreturn(result);
}

CAMLprim value mlwm_x11_outputs(value handle) {
  CAMLparam1(handle);
  CAMLlocal3(list, item, cell);
  mlwm_x11_t *ctx = context(handle);
  list = Val_emptylist;
  XRRScreenResources *resources = ctx->randr ?
    XRRGetScreenResourcesCurrent(ctx->dpy, ctx->root) : NULL;
  RROutput primary = ctx->randr ? XRRGetOutputPrimary(ctx->dpy, ctx->root) : None;
  if (resources != NULL) {
    for (int i = resources->noutput - 1; i >= 0; --i) {
      RROutput id = resources->outputs[i];
      XRROutputInfo *output = XRRGetOutputInfo(ctx->dpy, resources, id);
      if (output == NULL) continue;
      XRRCrtcInfo *crtc = NULL;
      if (output->connection == RR_Connected && output->crtc != None)
        crtc = XRRGetCrtcInfo(ctx->dpy, resources, output->crtc);
      if (crtc != NULL && crtc->width > 0 && crtc->height > 0) {
        item = output_info(id, output->name, (size_t)output->nameLen,
                           crtc->x, crtc->y, (int)crtc->width,
                           (int)crtc->height, id == primary);
        cell = caml_alloc(2, 0);
        Store_field(cell, 0, item);
        Store_field(cell, 1, list);
        list = cell;
      }
      if (crtc != NULL) XRRFreeCrtcInfo(crtc);
      XRRFreeOutputInfo(output);
    }
    XRRFreeScreenResources(resources);
  }
  /* Bare Xvfb can advertise RandR but have no connected output/CRTC. */
  if (list == Val_emptylist) {
    item = output_info(0, "default", 7, 0, 0,
                       DisplayWidth(ctx->dpy, ctx->screen),
                       DisplayHeight(ctx->dpy, ctx->screen), 1);
    list = caml_alloc(2, 0);
    Store_field(list, 0, item);
    Store_field(list, 1, Val_emptylist);
  }
  CAMLreturn(list);
}

static int normal_window(mlwm_x11_t *ctx, Window w, XWindowAttributes *attrs) {
  return w != ctx->root && XGetWindowAttributes(ctx->dpy, w, attrs) &&
    !attrs->override_redirect;
}

static value window_info(mlwm_x11_t *ctx, Window w, XWindowAttributes *attrs) {
  CAMLparam0();
  CAMLlocal3(result, geometry, transient);
  Window parent = None;
  int floating = XGetTransientForHint(ctx->dpy, w, &parent);
  transient = Val_none;
  if (floating) {
    transient = caml_alloc(1, 0);
    Store_field(transient, 0, Val_long(parent));
  }
  Atom actual_type;
  int format;
  unsigned long count, remaining;
  unsigned char *data = NULL;
  if (XGetWindowProperty(ctx->dpy, w, ctx->atoms[A_TYPE], 0, 64, False,
                         XA_ATOM, &actual_type, &format, &count,
                         &remaining, &data) == Success &&
      actual_type == XA_ATOM && format == 32) {
    Atom *types = (Atom *)data;
    for (unsigned long i = 0; i < count; ++i)
      for (int j = A_DIALOG; j <= A_MENU; ++j)
        if (types[i] == ctx->atoms[j]) floating = 1;
  }
  if (data != NULL) XFree(data);
  XSizeHints hints;
  long supplied;
  if (XGetWMNormalHints(ctx->dpy, w, &hints, &supplied) &&
      (hints.flags & PMinSize) && (hints.flags & PMaxSize) &&
      hints.min_width > 0 && hints.min_height > 0 &&
      hints.min_width == hints.max_width && hints.min_height == hints.max_height)
    floating = 1;
  geometry = rectangle(attrs->x, attrs->y, attrs->width, attrs->height);
  result = caml_alloc(4, 0);
  Store_field(result, 0, Val_long(w));
  Store_field(result, 1, geometry);
  Store_field(result, 2, Val_bool(floating));
  Store_field(result, 3, transient);
  CAMLreturn(result);
}

CAMLprim value mlwm_x11_windows(value handle) {
  CAMLparam1(handle);
  CAMLlocal3(list, item, cell);
  mlwm_x11_t *ctx = context(handle);
  Window root, parent, *children = NULL;
  unsigned int count = 0;
  list = Val_emptylist;
  if (XQueryTree(ctx->dpy, ctx->root, &root, &parent, &children, &count)) {
    for (unsigned int i = count; i > 0; --i) {
      XWindowAttributes attrs;
      Window w = children[i - 1];
      if (!normal_window(ctx, w, &attrs) || attrs.map_state != IsViewable)
        continue;
      item = window_info(ctx, w, &attrs);
      cell = caml_alloc(2, 0);
      Store_field(cell, 0, item);
      Store_field(cell, 1, list);
      list = cell;
    }
  }
  if (children != NULL) XFree(children);
  CAMLreturn(list);
}

static void find_numlock(mlwm_x11_t *ctx) {
  ctx->numlock_mask = 0;
  XModifierKeymap *mapping = XGetModifierMapping(ctx->dpy);
  if (mapping == NULL) return;
  KeyCode code = XKeysymToKeycode(ctx->dpy, XK_Num_Lock);
  if (code != 0)
    for (int mod = 0; mod < 8; ++mod)
      for (int i = 0; i < mapping->max_keypermod; ++i)
        if (mapping->modifiermap[mod * mapping->max_keypermod + i] == code)
          ctx->numlock_mask |= 1u << mod;
  XFreeModifiermap(mapping);
}

static unsigned int modifier_mask(value mods) {
  static const unsigned int masks[] = { Mod4Mask, Mod1Mask, ShiftMask, ControlMask };
  unsigned int mask = 0;
  for (; mods != Val_emptylist; mods = Field(mods, 1))
    mask |= masks[Int_val(Field(mods, 0))];
  return mask;
}

static const KeySym named_keys[] = {
  XK_Return, XK_Tab, XK_space, XK_Escape, XK_BackSpace,
  XK_Left, XK_Right, XK_Up, XK_Down
};

static KeySym keysym(value sym) {
  if (Is_long(sym)) return named_keys[Int_val(sym)];
  /* Latin-1 KeySyms equal their character codes, including ASCII punctuation. */
  unsigned int c = (unsigned int)Int_val(Field(sym, 0));
  return (c >= 0x20 && c <= 0x7e) || c >= 0xa0 ? (KeySym)c : NoSymbol;
}

CAMLprim value mlwm_x11_grab_keys(value handle, value bindings) {
  CAMLparam2(handle, bindings);
  mlwm_x11_t *ctx = context(handle);
  size_t count = 0;
  for (value it = bindings; it != Val_emptylist; it = Field(it, 1)) ++count;
  key_grab_t *grabs = count == 0 ? NULL : calloc(count, sizeof *grabs);
  if (count != 0 && grabs == NULL) caml_raise_out_of_memory();
  free(ctx->grabs);
  ctx->grabs = grabs;
  ctx->grab_count = 0;
  find_numlock(ctx);
  XUngrabKey(ctx->dpy, AnyKey, AnyModifier, ctx->root);
  unsigned int locks[] = { 0, LockMask, ctx->numlock_mask,
                           LockMask | ctx->numlock_mask };
  for (value it = bindings; it != Val_emptylist; it = Field(it, 1)) {
    value binding = Field(it, 0);
    KeySym sym = keysym(Field(binding, 1));
    KeyCode code = XKeysymToKeycode(ctx->dpy, sym);
    if (sym == NoSymbol || code == 0) continue;
    unsigned int requested_mask = modifier_mask(Field(binding, 0));
    unsigned int mask = requested_mask;
    /* '?' and uppercase Char bindings need the shifted level of their key.
     * Keep the requested symbol separately so the core receives its own binding. */
    KeySym base = XkbKeycodeToKeysym(ctx->dpy, code, 0, 0);
    if (sym != base && sym == XkbKeycodeToKeysym(ctx->dpy, code, 0, 1))
      mask |= ShiftMask;
    ctx->grabs[ctx->grab_count++] = (key_grab_t){code, mask, requested_mask, sym};
    for (int i = 0; i < 4; ++i)
      XGrabKey(ctx->dpy, code, mask | locks[i], ctx->root, True,
                GrabModeAsync, GrabModeAsync);
  }
  CAMLreturn(Val_unit);
}

static value key_binding(mlwm_x11_t *ctx, XKeyEvent *key) {
  CAMLparam0();
  CAMLlocal5(binding, sym, mods, cell, event);
  /* Group/level zero preserves lowercase even for Super+Shift+c. */
  KeySym base = XkbKeycodeToKeysym(ctx->dpy, key->keycode, 0, 0);
  unsigned int supported = Mod4Mask | Mod1Mask | ShiftMask | ControlMask;
  unsigned int state = key->state & supported & ~(LockMask | ctx->numlock_mask);
  for (size_t i = 0; i < ctx->grab_count; ++i) {
    key_grab_t *grab = &ctx->grabs[i];
    if (grab->code == key->keycode && grab->mask == state) {
      base = grab->sym;
      state = grab->requested_mask;
      break;
    }
  }
  int named = -1;
  for (int i = 0; i < 9; ++i)
    if (named_keys[i] == base) named = i;
  if (named >= 0) sym = Val_int(named);
  else if ((base >= 0x20 && base <= 0x7e) || (base >= 0xa0 && base <= 0xff)) {
    sym = caml_alloc(1, 0);
    Store_field(sym, 0, Val_int(base));
  } else CAMLreturn(Val_int(0)); /* Ignored */
  static const unsigned int masks[] = { Mod4Mask, Mod1Mask, ShiftMask, ControlMask };
  mods = Val_emptylist;
  for (int i = 3; i >= 0; --i) {
    if (!(state & masks[i])) continue;
    cell = caml_alloc(2, 0);
    Store_field(cell, 0, Val_int(i));
    Store_field(cell, 1, mods);
    mods = cell;
  }
  binding = caml_alloc(2, 0);
  Store_field(binding, 0, mods);
  Store_field(binding, 1, sym);
  event = caml_alloc(1, 5); /* Key_press */
  Store_field(event, 0, binding);
  CAMLreturn(event);
}

CAMLprim value mlwm_x11_next_event(value handle) {
  CAMLparam1(handle);
  CAMLlocal2(result, payload);
  mlwm_x11_t *ctx = context(handle);
  XEvent ev;
  /* ctx is separately malloc'd: another domain's GC cannot move this pointer.
   * The rooted handle keeps its finalizer away while the runtime is released.
   * Do not touch OCaml values until caml_leave_blocking_section has returned. */
  caml_enter_blocking_section();
  XNextEvent(ctx->dpy, &ev);
  caml_leave_blocking_section();
  if (ctx->randr && (ev.type == ctx->rr_event_base + RRScreenChangeNotify ||
                     ev.type == ctx->rr_event_base + RRNotify)) {
    XRRUpdateConfiguration(&ev);
    CAMLreturn(Val_int(1)); /* Outputs_changed */
  }
  switch (ev.type) {
    case MapRequest: {
      XWindowAttributes attrs;
      if (!normal_window(ctx, ev.xmaprequest.window, &attrs))
        CAMLreturn(Val_int(0));
      payload = window_info(ctx, ev.xmaprequest.window, &attrs);
      result = caml_alloc(1, 0);
      Store_field(result, 0, payload);
      break;
    }
    case ConfigureRequest: {
      XConfigureRequestEvent *request = &ev.xconfigurerequest;
      payload = caml_alloc(9, 0);
      Store_field(payload, 0, Val_long(request->window));
      Store_field(payload, 1, Val_int(request->x));
      Store_field(payload, 2, Val_int(request->y));
      Store_field(payload, 3, Val_int(request->width));
      Store_field(payload, 4, Val_int(request->height));
      Store_field(payload, 5, Val_int(request->border_width));
      Store_field(payload, 6, Val_long(request->above));
      Store_field(payload, 7, Val_int(request->detail));
      Store_field(payload, 8, Val_long(request->value_mask));
      result = caml_alloc(1, 1);
      Store_field(result, 0, payload);
      break;
    }
    case UnmapNotify:
      /* Root-only StructureNotify subscription avoids duplicate unmap counts. */
      if (ev.xunmap.event != ctx->root && !ev.xunmap.send_event)
        CAMLreturn(Val_int(0));
      result = caml_alloc(2, 2);
      Store_field(result, 0, Val_long(ev.xunmap.window));
      Store_field(result, 1, Val_bool(ev.xunmap.send_event));
      break;
    case DestroyNotify:
      result = caml_alloc(1, 3);
      Store_field(result, 0, Val_long(ev.xdestroywindow.window));
      break;
    case ButtonPress:
      result = caml_alloc(1, 4);
      Store_field(result, 0, Val_long(ev.xbutton.window));
      break;
    case KeyPress:
      CAMLreturn(key_binding(ctx, &ev.xkey));
    case MappingNotify:
      XRefreshKeyboardMapping(&ev.xmapping);
      CAMLreturn(Val_int(2)); /* Mapping_changed: OCaml regrabs configured keys. */
    default:
      CAMLreturn(Val_int(0));
  }
  CAMLreturn(result);
}

CAMLprim value mlwm_x11_configure(value handle, value request) {
  CAMLparam2(handle, request);
  mlwm_x11_t *ctx = context(handle);
  XWindowChanges changes;
  changes.x = Int_val(Field(request, 1));
  changes.y = Int_val(Field(request, 2));
  changes.width = Int_val(Field(request, 3));
  changes.height = Int_val(Field(request, 4));
  changes.border_width = Int_val(Field(request, 5));
  changes.sibling = Long_val(Field(request, 6));
  changes.stack_mode = Int_val(Field(request, 7));
  /* Unmanaged/override-redirect clients own their own requested geometry. */
  XConfigureWindow(ctx->dpy, Long_val(Field(request, 0)),
                    (unsigned int)Long_val(Field(request, 8)), &changes);
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_notify_configure(value handle, value id,
                                        value geometry, value border) {
  CAMLparam4(handle, id, geometry, border);
  mlwm_x11_t *ctx = context(handle);
  XEvent event;
  memset(&event, 0, sizeof event);
  event.xconfigure.type = ConfigureNotify;
  event.xconfigure.display = ctx->dpy;
  event.xconfigure.event = Long_val(id);
  event.xconfigure.window = Long_val(id);
  event.xconfigure.x = Int_val(Field(geometry, 0));
  event.xconfigure.y = Int_val(Field(geometry, 1));
  event.xconfigure.width = Int_val(Field(geometry, 2));
  event.xconfigure.height = Int_val(Field(geometry, 3));
  event.xconfigure.border_width = Int_val(border);
  event.xconfigure.above = None;
  event.xconfigure.override_redirect = False;
  /* ICCCM 4.1.5: acknowledge refused geometry requests in root coordinates. */
  XSendEvent(ctx->dpy, Long_val(id), False, StructureNotifyMask, &event);
  CAMLreturn(Val_unit);
}

static void decorate(mlwm_x11_t *ctx, Window w, unsigned long color, int grab) {
  XSetWindowBorder(ctx->dpy, w, color);
  XUngrabButton(ctx->dpy, Button1, AnyModifier, w);
  if (grab)
    XGrabButton(ctx->dpy, Button1, AnyModifier, w, False, ButtonPressMask,
                 GrabModeSync, GrabModeAsync, None, None);
}

CAMLprim value mlwm_x11_decorate(value handle, value id, value color, value grab) {
  CAMLparam4(handle, id, color, grab);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  if (normal_window(ctx, Long_val(id), &attrs))
    decorate(ctx, Long_val(id), Long_val(color), Bool_val(grab));
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_place(value handle, value id, value geometry,
                             value border, value color) {
  CAMLparam5(handle, id, geometry, border, color);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  if (normal_window(ctx, Long_val(id), &attrs)) {
    int width = Int_val(Field(geometry, 2)), height = Int_val(Field(geometry, 3));
    XSetWindowBorderWidth(ctx->dpy, Long_val(id), (unsigned int)Int_val(border));
    XMoveResizeWindow(ctx->dpy, Long_val(id), Int_val(Field(geometry, 0)),
                       Int_val(Field(geometry, 1)),
                       (unsigned int)(width > 0 ? width : 1),
                       (unsigned int)(height > 0 ? height : 1));
    XSetWindowBorder(ctx->dpy, Long_val(id), Long_val(color));
  }
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_focus(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  Window w = id == Val_none ? ctx->root : (Window)Long_val(Field(id, 0));
  XWindowAttributes attrs;
  if (w == ctx->root || normal_window(ctx, w, &attrs))
    XSetInputFocus(ctx->dpy, w, RevertToPointerRoot, CurrentTime);
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_replay_pointer(value handle) {
  CAMLparam1(handle);
  XAllowEvents(context(handle)->dpy, ReplayPointer, CurrentTime);
  CAMLreturn(Val_unit);
}

static void set_wm_state(mlwm_x11_t *ctx, Window w, long state) {
  long data[] = { state, None };
  XChangeProperty(ctx->dpy, w, ctx->atoms[A_STATE], ctx->atoms[A_STATE],
                    32, PropModeReplace, (unsigned char *)data, 2);
}

CAMLprim value mlwm_x11_show(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  if (normal_window(ctx, Long_val(id), &attrs)) {
    set_wm_state(ctx, Long_val(id), NormalState);
    XMapWindow(ctx->dpy, Long_val(id));
  }
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_hide(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  /* Keep a client withdrawal from racing this query/unmap pair: otherwise the
   * counter could swallow the client's event when our unmap became a no-op. */
  XGrabServer(ctx->dpy);
  int mapped = normal_window(ctx, Long_val(id), &attrs) &&
    attrs.map_state != IsUnmapped;
  if (mapped) {
    set_wm_state(ctx, Long_val(id), IconicState);
    XUnmapWindow(ctx->dpy, Long_val(id));
  }
  XUngrabServer(ctx->dpy);
  XFlush(ctx->dpy);
  CAMLreturn(Val_bool(mapped));
}

CAMLprim value mlwm_x11_raise(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  if (normal_window(ctx, Long_val(id), &attrs)) XRaiseWindow(ctx->dpy, Long_val(id));
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_close_window(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  Window w = Long_val(id);
  XWindowAttributes attrs;
  if (!normal_window(ctx, w, &attrs)) CAMLreturn(Val_unit);
  Atom *protocols = NULL;
  int count = 0, supports_delete = 0;
  if (XGetWMProtocols(ctx->dpy, w, &protocols, &count)) {
    for (int i = 0; i < count; ++i)
      if (protocols[i] == ctx->atoms[A_DELETE]) supports_delete = 1;
  }
  if (protocols != NULL) XFree(protocols);
  if (supports_delete) {
    XEvent event;
    memset(&event, 0, sizeof event);
    event.xclient.type = ClientMessage;
    event.xclient.window = w;
    event.xclient.message_type = ctx->atoms[A_PROTOCOLS];
    event.xclient.format = 32;
    event.xclient.data.l[0] = (long)ctx->atoms[A_DELETE];
    event.xclient.data.l[1] = CurrentTime;
    XSendEvent(ctx->dpy, w, False, NoEventMask, &event);
  } else XKillClient(ctx->dpy, w);
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_spawn(value arguments) {
  CAMLparam1(arguments);
  mlsize_t count = Wosize_val(arguments);
  if (count == 0) CAMLreturn(Val_unit);
  char **argv = calloc(count + 1, sizeof *argv);
  if (argv == NULL) caml_raise_out_of_memory();
  /* Copy before fork: the child must use only C memory and never the runtime. */
  for (mlsize_t i = 0; i < count; ++i) {
    argv[i] = strdup(String_val(Field(arguments, i)));
    if (argv[i] == NULL) {
      for (mlsize_t j = 0; j < i; ++j) free(argv[j]);
      free(argv);
      caml_raise_out_of_memory();
    }
  }
  pid_t pid = fork();
  if (pid == 0) {
    (void)setsid();
    execvp(argv[0], argv);
    _exit(127);
  }
  for (mlsize_t i = 0; i < count; ++i) free(argv[i]);
  free(argv);
  if (pid < 0) caml_failwith("fork failed");
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_manage(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  if (normal_window(ctx, Long_val(id), &attrs))
    XAddToSaveSet(ctx->dpy, Long_val(id));
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_unmanage(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XRemoveFromSaveSet(ctx->dpy, Long_val(id));
  XUngrabButton(ctx->dpy, Button1, AnyModifier, Long_val(id));
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_release(value handle, value id) {
  CAMLparam2(handle, id);
  mlwm_x11_t *ctx = context(handle);
  XWindowAttributes attrs;
  Window w = Long_val(id);
  if (normal_window(ctx, w, &attrs)) {
    if (attrs.map_state == IsUnmapped) XMapWindow(ctx->dpy, w);
    set_wm_state(ctx, w, NormalState);
    XSetWindowBorderWidth(ctx->dpy, w, 0);
    XUngrabButton(ctx->dpy, Button1, AnyModifier, w);
    XRemoveFromSaveSet(ctx->dpy, w);
  }
  CAMLreturn(Val_unit);
}

CAMLprim value mlwm_x11_sync(value handle) {
  CAMLparam1(handle);
  XSync(context(handle)->dpy, False);
  CAMLreturn(Val_unit);
}
