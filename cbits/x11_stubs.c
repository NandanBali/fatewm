/* M0 compile-verification stub — implemented in M1/M2 by the X11/C agent.
 * Links against libX11 and libXrandr via direct OCaml C FFI. */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>

CAMLprim value mlwm_x11_stub_ping(value unit) {
  CAMLparam1(unit);
  /* Reference both X11 and Xrandr symbols so M0 verifies header & lib linkage. */
  (void)XOpenDisplay;
  (void)XRRQueryExtension;
  CAMLreturn(Val_int(1));
}
