#include "common.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <libspeechd.h>
#include <map>
#include <mutex>
#include <poll.h>
#include <thread>
namespace fqapp {
class Speech final : public Tts {
  struct Events {
    FlEventChannel *channel;
    std::atomic<unsigned> generation{0};
    std::atomic<bool> alive{true};
    explicit Events(FlEventChannel *c)
        : channel(FL_EVENT_CHANNEL(g_object_ref(c))) {}
    ~Events() {
      if (channel)
        g_object_unref(channel);
    }
  };
  std::shared_ptr<Events> events;
  SPDConnection *connection = nullptr;
  std::mutex jobs_mutex;
  std::condition_variable ready;
  std::deque<std::function<void()>> jobs;
  std::map<size_t, std::string> ids;
  std::deque<std::pair<std::string, std::string>> pending;
  bool quitting = false;
  std::thread worker;
  static std::atomic<Speech *> active;
  static std::mutex active_mutex;
  void emit(const char *type, const std::string &id, unsigned generation) {
    auto e = events;
    std::string t = type;
    main_task([e, t, id, generation] {
      if (!e->alive || e->generation != generation)
        return;
      g_autoptr(FlValue) v = fl_value_new_map();
      put(v, "type", fl_value_new_string(t.c_str()));
      if (!id.empty())
        put(v, "id", fl_value_new_string(id.c_str()));
      fl_event_channel_send(e->channel, v, nullptr, nullptr);
    });
  }
  static void callback(size_t msg, size_t, SPDNotificationType type) {
    std::lock_guard<std::mutex> guard(active_mutex);
    auto *self = active.load();
    if (!self)
      return;
    unsigned generation = self->events->generation;
    self->post([self, msg, type, generation] {
      if (!self->events->alive || generation != self->events->generation)
        return;
      auto found = self->ids.find(msg);
      if (found == self->ids.end())
        return;
      const char *event = type == SPD_EVENT_BEGIN    ? "start"
                          : type == SPD_EVENT_END    ? "done"
                          : type == SPD_EVENT_CANCEL ? "error"
                                                     : nullptr;
      if (event)
        self->emit(event, found->second, generation);
      if (type == SPD_EVENT_END || type == SPD_EVENT_CANCEL) {
        self->ids.erase(found);
        while (self->ids.empty() && !self->pending.empty()) {
          auto next = std::move(self->pending.front());
          self->pending.pop_front();
          if (!self->say(next.first, next.second))
            self->emit("error", next.second, generation);
        }
      }
    });
  }
  bool say(const std::string &text, const std::string &id) {
    // SPD_TEXT may cancel a prior message: only submit after its terminal
    // event.
    int message = spd_say(connection, SPD_TEXT, text.c_str());
    if (message < 0)
      return false;
    ids[message] = id;
    return true;
  }
  bool open() {
    if (connection)
      return true;
    // Do not start or reconfigure a user's daemon. Missing service is a visible
    // error.
    connection = spd_open2("fqapp", "reader", nullptr, SPD_MODE_THREADED,
                           nullptr, 0, nullptr);
    if (!connection)
      return false;
    {
      std::lock_guard<std::mutex> guard(active_mutex);
      if (events->alive)
        active = this;
    }
    connection->callback_begin = callback;
    connection->callback_end = callback;
    connection->callback_cancel = callback;
    if (spd_set_notification_on(connection,
                                static_cast<SPDNotification>(
                                    SPD_BEGIN | SPD_END | SPD_CANCEL)) < 0) {
      close();
      return false;
    }
    return true;
  }
  bool cancel() {
    ++events->generation;
    ids.clear();
    pending.clear();
    return !connection || spd_cancel(connection) >= 0;
  }
  void close() {
    {
      std::lock_guard<std::mutex> guard(active_mutex);
      if (active == this)
        active = nullptr;
    }
    cancel();
    if (connection) {
      spd_close(connection);
      connection = nullptr;
    }
  }
  void post(std::function<void()> f) {
    {
      std::lock_guard<std::mutex> guard(jobs_mutex);
      jobs.push_back(std::move(f));
    }
    ready.notify_one();
  }

public:
  explicit Speech(FlEventChannel *c)
      : events(std::make_shared<Events>(c)), worker([this] {
          for (;;) {
            std::function<void()> job;
            {
              std::unique_lock<std::mutex> lock(jobs_mutex);
              ready.wait_for(lock, std::chrono::milliseconds(250),
                             [this] { return quitting || !jobs.empty(); });
              if (jobs.empty() && quitting)
                break;
              if (!jobs.empty()) {
                job = std::move(jobs.front());
                jobs.pop_front();
              }
            }
            if (job)
              job();
            if (connection) {
              pollfd fd{spd_fd(connection), 0, 0};
              // libspeechd closes its socket and sets -1 on its reader thread.
              if (fd.fd < 0 ||
                  (poll(&fd, 1, 0) > 0 &&
                   (fd.revents & (POLLHUP | POLLERR | POLLNVAL)))) {
                close();
                emit("engine_stopped", "", events->generation);
              }
            }
          }
          close();
        }) {}
  ~Speech() override {
    // The bridge's unique_ptr destroys Speech on the GTK main thread.
    {
      // Fence pointer acquisition and enqueue before draining the worker.
      std::lock_guard<std::mutex> guard(active_mutex);
      if (active == this)
        active = nullptr;
      events->alive = false;
    }
    {
      std::lock_guard<std::mutex> guard(jobs_mutex);
      quitting = true;
    }
    ready.notify_one();
    worker.join();
    // Queued event closures retain only the dead token, not an engine channel.
    g_clear_object(&events->channel);
    events.reset();
  }
  void call(FlMethodCall *call) override {
    g_object_ref(call);
    std::string method = fl_method_call_get_name(call);
    FlValue *args = fl_method_call_get_args(call);
    if (args)
      fl_value_ref(args);
    post([this, call, args, method] {
      FlValue *result = nullptr;
      std::string error;
      if (method == "shutdown") {
        close();
      } else if (method == "settings")
        error = "请使用系统 Speech Dispatcher 配置工具配置中文语音（例如 "
                "espeak-ng），然后重新初始化。";
      else if (method == "pause" || method == "stop") {
        if (!cancel()) {
          error = "无法取消上次朗读";
          close();
        }
      } else if (method != "engines" && method != "initialize" &&
                 method != "speak" && method != "setVolume" &&
                 method != "setRate" && method != "getPlaybackSettings")
        error = "未知朗读方法";
      else if (!open())
        error =
            "无法连接 Speech Dispatcher；请安装并启用用户会话服务及中文语音。";
      else if (method == "engines") {
        result = fl_value_new_map();
        auto *engines = fl_value_new_list();
        char **modules = spd_list_modules(connection);
        if (!modules)
          error = "无法查询 Speech Dispatcher 音源";
        else {
          for (size_t i = 0; modules[i]; ++i) {
            auto *e = fl_value_new_map();
            put(e, "package", fl_value_new_string(modules[i]));
            put(e, "label", fl_value_new_string(modules[i]));
            fl_value_append_take(engines, e);
          }
          free_spd_modules(modules);
        }
        put(result, "engines", engines);
        char *current = spd_get_output_module(connection);
        if (current) {
          put(result, "defaultEngine", fl_value_new_string(current));
          free(current);
        }
      } else if (method == "initialize") {
        bool cancelled = cancel();
        auto engine = str(field(args, "engine"));
        double rate = number(field(args, "rate"), 1);
        double volume = number(field(args, "volume"), 1);
        if (!cancelled)
          error = "无法取消上次朗读";
        else if (!std::isfinite(rate) || rate < 0.25 || rate > 4)
          error = "语速超出范围";
        else if (!std::isfinite(volume) || volume < 0 || volume > 1)
          error = "音量超出范围";
        else if ((!engine.empty() &&
                  spd_set_output_module(connection, engine.c_str()) < 0) ||
                 spd_set_language(connection, "zh") < 0)
          error = "中文音源配置失败";
        else {
          SPDVoice **voices = spd_list_synthesis_voices(connection);
          const char *voice = nullptr;
          if (voices)
            for (size_t i = 0; voices[i]; ++i)
              if (voices[i]->language &&
                  (g_str_has_prefix(voices[i]->language, "zh") ||
                   g_str_has_prefix(voices[i]->language, "cmn"))) {
                voice = voices[i]->name;
                break;
              }
          if (!voice || spd_set_synthesis_voice(connection, voice) < 0)
            error = "当前引擎没有可用中文语音";
          if (voices)
            free_spd_voices(voices);
          if (error.empty() &&
              spd_set_voice_rate(
                  connection, std::clamp(static_cast<int>(std::log2(rate) * 50),
                                         -100, 100)) < 0)
            error = "无法设置朗读语速";
          if (error.empty() && field(args, "volume") &&
              spd_set_volume(connection, static_cast<int>(std::lround(
                                             volume * 200 - 100))) < 0)
            error = "无法设置朗读音量";
          if (error.empty())
            result = fl_value_new_int(4000);
        }
      } else if (method == "getPlaybackSettings") {
        // libspeechd's integer getters discard the reply error status.
        int values[2] = {0, 0};
        const char *commands[] = {"GET VOLUME", "GET RATE"};
        for (int i = 0; i < 2; ++i) {
          char *response = nullptr;
          int status = spd_execute_command_with_reply(connection, commands[i],
                                                      &response);
          if (status < 0 || !response ||
              std::sscanf(response, "%*d-%d", &values[i]) != 1 ||
              values[i] < -100 || values[i] > 100)
            error = "无法读取朗读设置";
          free(response);
        }
        int volume = values[0], rate = values[1];
        if (error.empty()) {
          result = fl_value_new_map();
          put(result, "volume", fl_value_new_float((volume + 100) / 200.0));
          put(result, "rate", fl_value_new_float(std::pow(2.0, rate / 50.0)));
        }
      } else if (method == "setRate") {
        double rate = number(field(args, "rate"));
        if (!std::isfinite(rate) || rate < 0.25 || rate > 4)
          error = "语速超出范围";
        else if (spd_set_voice_rate(connection, static_cast<int>(std::lround(
                                                    std::log2(rate) * 50))) < 0)
          error = "无法设置朗读语速";
      } else if (method == "setVolume") {
        double volume = number(field(args, "volume"), -1);
        if (!std::isfinite(volume) || volume < 0 || volume > 1)
          error = "音量超出范围";
        else if (spd_set_volume(connection, static_cast<int>(std::lround(
                                                volume * 200 - 100))) < 0)
          error = "无法设置朗读音量";
      } else if (method == "speak") {
        auto text = str(field(args, "text")), id = str(field(args, "id"));
        if (text.empty() || id.empty() || text.size() > 64 * 1024)
          error = "朗读文本或 ID 无效";
        else {
          if (!flag(field(args, "queue")) && !cancel()) {
            error = "无法取消上次朗读";
            close();
          }
          if (error.empty()) {
            if (pending.size() >= 32)
              error = "朗读队列已满";
            else if (!ids.empty())
              pending.emplace_back(text, id);
            else if (!say(text, id))
              error = "Speech Dispatcher 拒绝朗读请求";
          }
        }
      }
      if (!error.empty() && method == "initialize")
        close();
      main_task([call, args, result, error] {
        if (args)
          fl_value_unref(args);
        if (error.empty())
          reply(call, result);
        else
          fail(call, "TTS_ERROR", error.c_str());
        if (result)
          fl_value_unref(result);
        g_object_unref(call);
      });
    });
  }
};
std::atomic<Speech *> Speech::active{nullptr};
std::mutex Speech::active_mutex;
std::unique_ptr<Tts> make_tts(FlEventChannel *c) {
  return std::make_unique<Speech>(c);
}
} // namespace fqapp
