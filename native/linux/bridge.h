#pragma once
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
G_BEGIN_DECLS
typedef struct FqappLinuxBridge FqappLinuxBridge;
// Call on GTK main thread after the view has a messenger. Free before engine
// teardown.
FqappLinuxBridge *fqapp_linux_bridge_new(FlBinaryMessenger *, GtkWindow *);
void fqapp_linux_bridge_free(FqappLinuxBridge *);
G_END_DECLS
