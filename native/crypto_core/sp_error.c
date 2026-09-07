#include "sp_crypto.h"

#include <stdarg.h>
#include <stdio.h>

sp_status sp_error_set(sp_error *error, sp_status code, const char *format, ...) {
    if (error != NULL) {
        error->code = code;
        if (format == NULL) {
            error->message[0] = '\0';
        } else {
            va_list args;
            va_start(args, format);
            vsnprintf(error->message, sizeof(error->message), format, args);
            va_end(args);
        }
    }
    return code;
}
