"""ASan regression for a callback paused after taking the real Speech pointer."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
engine = Path(os.environ["FLUTTER_ROOT"]) / "bin/cache/artifacts/engine/linux-x64"
source = (root / "native/linux/tts.cc").read_text()
load = "    auto *self = active.load();"
destructor = "  ~Speech() override {"
assert source.count(load) == source.count(destructor) == 1
source = source.replace("class Speech final : public Tts {",
                        "class Speech final : public Tts {\n  friend struct SpeechLifetimeProbe;")
source = source.replace(load, load + "\n    lifetime_after_load();")
source = source.replace(destructor, destructor + "\n    lifetime_destructor_entered();")
source = ("namespace fqapp { void lifetime_after_load(); "
          "void lifetime_destructor_entered(); }\n" + source)
source += (root / "native/tests/linux_tts_lifetime.cc").read_text()
scratch = Path(tempfile.mkdtemp(prefix="fqapp-tts-lifetime-"))
print("evidence=" + str(scratch), flush=True)
(scratch / "probe.cc").write_text(source)
flags = shlex.split(subprocess.check_output(
    ["pkg-config", "--cflags", "--libs", "gtk+-3.0", "speech-dispatcher"], text=True))
subprocess.run(["c++", "-std=c++17", "-g", "-O1", "-pthread", "-fsanitize=address",
                "-fno-omit-frame-pointer", "-I" + str(root / "native/linux"),
                "-I" + str(engine), str(scratch / "probe.cc"), "-L" + str(engine),
                "-lflutter_linux_gtk", "-Wl,-rpath," + str(engine), *flags,
                "-o", str(scratch / "probe")], check=True)
subprocess.run([str(scratch / "probe")], check=True, timeout=30,
               env=dict(os.environ, ASAN_OPTIONS="detect_leaks=1:halt_on_error=1",
                        G_DEBUG="fatal-criticals"))
