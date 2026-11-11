// Appended to the real tts.cc with test-only friend and scheduling hooks.
#include <cassert>
#include <iostream>
namespace fqapp {
namespace {
std::mutex schedule_mutex;
std::condition_variable schedule;
bool loaded, resume_callback, destructor_entered, destroyed;
} // namespace
void lifetime_after_load() {
  std::unique_lock<std::mutex> lock(schedule_mutex);
  loaded = true;
  schedule.notify_all();
  schedule.wait(lock, [] { return resume_callback; });
}
void lifetime_destructor_entered() {
  std::lock_guard<std::mutex> lock(schedule_mutex);
  destructor_entered = true;
  schedule.notify_all();
}
struct SpeechLifetimeProbe {
  static void run(FlEventChannel *channel) {
    for (int iteration = 0; iteration < 32; ++iteration) {
      {
        std::lock_guard<std::mutex> lock(schedule_mutex);
        loaded = resume_callback = destructor_entered = destroyed = false;
      }
      auto speech = std::make_unique<Speech>(channel);
      Speech::active = speech.get();
      std::thread callback_thread(
          [] { Speech::callback(999, 0, SPD_EVENT_END); });
      {
        std::unique_lock<std::mutex> lock(schedule_mutex);
        schedule.wait(lock, [] { return loaded; });
      }
      std::thread destructor_thread([&] {
        speech.reset();
        std::lock_guard<std::mutex> lock(schedule_mutex);
        destroyed = true;
        schedule.notify_all();
      });
      bool freed_while_callback_held;
      {
        std::unique_lock<std::mutex> lock(schedule_mutex);
        schedule.wait(lock, [] { return destructor_entered; });
        freed_while_callback_held = schedule.wait_for(
            lock, std::chrono::milliseconds(30), [] { return destroyed; });
        resume_callback = true;
        schedule.notify_all();
      }
      callback_thread.join();
      destructor_thread.join();
      assert(!freed_while_callback_held);
      assert(Speech::active.load() == nullptr);
    }
  }
};
} // namespace fqapp
// No engine or Dart traffic is needed; registrations are immediately released.
struct LifetimeMessenger {
  GObject parent_instance;
};
struct LifetimeMessengerClass {
  GObjectClass parent_class;
};
static void
lifetime_messenger_interface_init(FlBinaryMessengerInterface *iface) {
  iface->set_message_handler_on_channel =
      [](FlBinaryMessenger *, const gchar *, FlBinaryMessengerMessageHandler,
         gpointer data, GDestroyNotify destroy) {
        if (destroy)
          destroy(data);
      };
}
G_DEFINE_TYPE_WITH_CODE(
    LifetimeMessenger, lifetime_messenger, G_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(fl_binary_messenger_get_type(),
                          lifetime_messenger_interface_init))
static void lifetime_messenger_class_init(LifetimeMessengerClass *) {}
static void lifetime_messenger_init(LifetimeMessenger *) {}
int main() {
  // Unknown ids never emit; the channel is only used for actual GObject
  // ownership.
  auto *messenger =
      FL_BINARY_MESSENGER(g_object_new(lifetime_messenger_get_type(), nullptr));
  auto *codec = fl_standard_method_codec_new();
  auto *channel =
      fl_event_channel_new(messenger, "lifetime-test", FL_METHOD_CODEC(codec));
  fqapp::SpeechLifetimeProbe::run(channel);
  g_object_unref(channel);
  g_object_unref(codec);
  g_object_unref(messenger);
  std::cout
      << "PASS 32 in-flight callback/destructor interleavings under ASan\n";
}
