#pragma once
#include "bridge.h"
#include <functional>
#include <memory>
#include <string>
namespace fqapp {
inline FlValue *field(FlValue *v, const char *k) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(v, k)
             : nullptr;
}
inline std::string str(FlValue *v) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(v)
             : "";
}
inline bool flag(FlValue *v) {
  return v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(v);
}
inline double number(FlValue *v, double fallback = 0) {
  if (!v)
    return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)
    return fl_value_get_int(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
    return fl_value_get_float(v);
  return fallback;
}
inline void put(FlValue *m, const char *k, FlValue *v) {
  fl_value_set_string_take(m, k, v);
}
inline void reply(FlMethodCall *call, FlValue *value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}
inline void fail(FlMethodCall *call, const char *code, const char *message) {
  fl_method_call_respond_error(call, code, message, nullptr, nullptr);
}
inline void main_task(std::function<void()> f) {
  auto *p = new std::function<void()>(std::move(f));
  g_idle_add_full(
      G_PRIORITY_DEFAULT,
      [](gpointer p) -> gboolean {
        (*static_cast<std::function<void()> *>(p))();
        return G_SOURCE_REMOVE;
      },
      p, [](gpointer p) { delete static_cast<std::function<void()> *>(p); });
}
class Tts {
public:
  virtual ~Tts() = default;
  virtual void call(FlMethodCall *) = 0;
};
std::unique_ptr<Tts> make_tts(FlEventChannel *);
} // namespace fqapp
