"""Real private SSIP/MPRIS integration driver for linux_desktop_runtime.dart.

Build the test target first; this script starts only task-owned services.
Requires Arch Speech Dispatcher/espeak-ng, Xvfb, dbus-run-session and gdbus.
"""
import os,pathlib,subprocess,tempfile,time,ctypes
base=pathlib.Path(tempfile.mkdtemp(prefix='fqapp-linux-desktop-'))
for name in ['home','config','data','cache','runtime','speech','speech-log']:(base/name).mkdir(mode=0o700)
env=os.environ.copy()
for name in ['DISPLAY','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS','GNOME_KEYRING_CONTROL','XAUTHORITY','DBUS_STARTER_ADDRESS','DBUS_STARTER_BUS_TYPE']:env.pop(name,None)
env.update(HOME=str(base/'home'),XDG_CONFIG_HOME=str(base/'config'),XDG_DATA_HOME=str(base/'data'),XDG_CACHE_HOME=str(base/'cache'),XDG_RUNTIME_DIR=str(base/'runtime'),DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(base/'no-system'),PULSE_SERVER='unix:'+str(base/'no-pulse'),LIBGL_ALWAYS_SOFTWARE='1',GDK_BACKEND='x11',FQAPP_DESKTOP_TEST_ROOT=str(base),SPEECHD_ADDRESS='unix_socket:'+str(base/'speech.sock'))
(base/'speech/speechd.conf').write_text('''LogLevel 3
DefaultLanguage "zh"
DefaultModule espeak-ng
AddModule "espeak-ng" "/usr/lib/speech-dispatcher/speech-dispatcher-modules/sd_espeak-ng" "/etc/speech-dispatcher/modules/espeak-ng.conf"
AudioOutputMethod "alsa"
AudioALSADevice "null"
''')
(base/'alsa.conf').write_text('pcm.null { type null }\npcm.!default { type null }\nctl.!default { type hw card 999 }\n')
env.update(SPEECHD_PLUGIN_DIR='/usr/lib/speech-dispatcher', GIO_USE_VFS='local', GTK_USE_PORTAL='0', NO_AT_BRIDGE='1')
env['ALSA_CONFIG_PATH']=str(base/'alsa.conf')
driver=base/'driver.py'
driver.write_text(r"""
import os,pathlib,subprocess,time,ctypes,socket,threading,re
base=pathlib.Path(os.environ['FQAPP_DESKTOP_TEST_ROOT'])
def wait(name):
 deadline=time.monotonic()+40
 while not (base/name).exists():
  if app.poll() is not None: raise RuntimeError((base/'app.log').read_text())
  assert time.monotonic()<deadline,name
  time.sleep(.05)
def mark(name):(base/name).write_text('')
def call(method,*args, dest='org.mpris.MediaPlayer2.fqapp',path='/org/mpris/MediaPlayer2'):
 r=subprocess.run(['gdbus','call','--session','--dest',dest,'--object-path',path,'--method',method,*args],text=True,capture_output=True,timeout=6)
 assert r.returncode==0,(r.stdout,r.stderr)
 return r.stdout
# Task-owned SSIP proxy: reject CANCEL only while the test requests it.
def proxy():
 listener=socket.socket(socket.AF_UNIX);listener.bind(str(base/'proxy.sock'));listener.listen()
 def connection(client):
  server=socket.socket(socket.AF_UNIX)
  try:server.connect(str(base/'speech.sock'))
  except OSError:
   client.close();server.close();return
  def replies():
   try:
    while data:=server.recv(65536):client.sendall(data)
   except OSError:pass
   finally:
    try:client.shutdown(socket.SHUT_RDWR)
    except OSError:pass
    client.close();server.close()
  threading.Thread(target=replies,daemon=True).start()
  try:
   for line in client.makefile('rb'):
    if line.strip().upper()==b'CANCEL SELF' and (base/'reject-cancel').exists():
     client.sendall(b'300 CANCEL REJECTED BY TEST\r\n')
    elif line.upper().startswith(b'SET SELF VOLUME ') and (base/'reject-volume').exists():
     client.sendall(b'300 VOLUME REJECTED BY TEST\r\n')
    else:server.sendall(line)
  except OSError:pass
  finally:
   # Clean only the proxy's abandoned test client after exercising rejection.
   try:server.sendall(b'CANCEL SELF\r\n');server.shutdown(socket.SHUT_RDWR)
   except OSError:pass
   server.close()
 while True:
  client,_=listener.accept();threading.Thread(target=connection,args=(client,),daemon=True).start()
threading.Thread(target=proxy,daemon=True).start()
def speech():
 p=subprocess.Popen(['speech-dispatcher','--run-single','--communication-method=unix_socket','--socket-path='+str(base/'speech.sock'),'--config-dir='+str(base/'speech'),'--log-dir='+str(base/'speech-log'),'--pid-file='+str(base/'speech.pid')],stdout=open(base/'speech-console.log','a'),stderr=subprocess.STDOUT)
 children.append(p)
 for _ in range(100):
  if (base/'speech.sock').exists():break
  time.sleep(.05)
 return p
children=[]
app=None
try:
 with open(base/'display','w') as display:
  x=subprocess.Popen(['Xvfb','-displayfd',str(display.fileno()),'-screen','0','1280x800x24','-nolisten','tcp'],pass_fds=[display.fileno()],stdout=open(base/'xvfb.log','w'),stderr=subprocess.STDOUT);children.append(x)
  for _ in range(100):
   if (base/'display').read_text().strip():break
   time.sleep(.05)
 os.environ['DISPLAY']=':'+(base/'display').read_text().strip()
 # Real GIO connection holds a competing MPRIS name throughout startup.
 gio=ctypes.CDLL('libgio-2.0.so.0')
 gio.g_bus_get_sync.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p];gio.g_bus_get_sync.restype=ctypes.c_void_p
 bus=gio.g_bus_get_sync(2,None,None)
 gio.g_variant_new=ctypes.CDLL('libglib-2.0.so.0').g_variant_new
 gio.g_variant_new.restype=ctypes.c_void_p
 gio.g_variant_new.argtypes=[ctypes.c_char_p]
 gio.g_dbus_connection_call_sync.argtypes=[ctypes.c_void_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
 gio.g_dbus_connection_call_sync.restype=ctypes.c_void_p
 def name(method):
  params=gio.g_variant_new(b'(su)' if method==b'RequestName' else b'(s)',ctypes.c_char_p(b'org.mpris.MediaPlayer2.fqapp'),ctypes.c_uint(4))
  assert gio.g_dbus_connection_call_sync(bus,b'org.freedesktop.DBus',b'/org/freedesktop/DBus',b'org.freedesktop.DBus',method,params,None,0,2000,None,None)
 name(b'RequestName')
 sp=speech()
 os.environ['SPEECHD_ADDRESS']='unix_socket:'+str(base/'proxy.sock')
 app=subprocess.Popen([os.environ['FQAPP_RUNTIME_EXE']],stdout=open(base/'app.log','w'),stderr=subprocess.STDOUT);children.append(app)
 wait('disconnect');sp.terminate();sp.wait(timeout=8)
 wait('reconnect')
 (base/'speech.sock').unlink(missing_ok=True)
 sp=speech();mark('restarted')
 wait('release-name');name(b'ReleaseName');mark('name-released')
 wait('mpris')
 out=call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Metadata')
 assert 'Synthetic book' in out and 'Chapter' in out,out
 assert 'Playing' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','PlaybackStatus')
 print('METADATA',out,flush=True)
 for action in ['Pause','Play','PlayPause']:call('org.mpris.MediaPlayer2.Player.'+action)
 call('org.mpris.MediaPlayer2.Player.Seek','1000000')
 call('org.mpris.MediaPlayer2.Player.SetPosition','/org/mpris/MediaPlayer2/track/1','5000000')
 # Distinct absolute/relative boundaries, stale track, and signed overflow.
 call('org.mpris.MediaPlayer2.Player.SetPosition','/org/mpris/MediaPlayer2/track/1','31000000')
 call('org.mpris.MediaPlayer2.Player.SetPosition','/org/mpris/MediaPlayer2/track/999','5000000')
 call('org.mpris.MediaPlayer2.Player.SetPosition','/org/mpris/MediaPlayer2/track/1','--','-1')
 call('org.mpris.MediaPlayer2.Player.Seek','31000000')
 call('org.mpris.MediaPlayer2.Player.Seek','9223372036854775807')
 call('org.mpris.MediaPlayer2.Player.Seek','--','-9223372036854775808')
 assert '0.400000' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Volume')
 monitor=subprocess.Popen(['gdbus','monitor','--session','--dest','org.mpris.MediaPlayer2.fqapp'],stdout=open(base/'signals.log','w'))
 children.append(monitor);time.sleep(.2)
 for prop,value in [('Volume','0.6'),('Volume','-1.0')]:
  call('org.freedesktop.DBus.Properties.Set','org.mpris.MediaPlayer2.Player',prop,'<'+value+'>')
 def position():
  return int(re.search(r'int64 (\d+)',call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Position')).group(1))
 time.sleep(2)
 started=time.monotonic()
 before=position()
 call('org.freedesktop.DBus.Properties.Set','org.mpris.MediaPlayer2.Player','Rate','<1.5>')
 after=position()
 allowance=int((time.monotonic()-started)*2*1000000)+250000
 print('RATE_POSITION',before,after,'allowance',allowance,flush=True)
 assert -1000 <= after-before <= allowance, 'Rate changed the current position anchor'
 print('PASS MPRIS rate preserves position anchor',flush=True)
 assert '0.0' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Volume')
 def rejected_setting(prop,value):
  r=subprocess.run(['gdbus','call','--session','--dest','org.mpris.MediaPlayer2.fqapp','--object-path','/org/mpris/MediaPlayer2','--method','org.freedesktop.DBus.Properties.Set','org.mpris.MediaPlayer2.Player',prop,value],capture_output=True,text=True)
  assert r.returncode!=0,(prop,value,r.stdout)
 (base/'reject-volume').touch()
 rejected_setting('Volume','<0.9>')
 (base/'reject-volume').unlink()
 assert '0.0' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Volume')
 rejected_setting('Rate','<0.1>')
 rejected_setting('Rate','<5.0>')
 rate=call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Rate')
 assert '1.49' in rate,rate
 assert '0.25' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','MinimumRate')
 assert '4.0' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','MaximumRate')
 time.sleep(.2)
 assert 'Volume' in (base/'signals.log').read_text() and 'PropertiesChanged' in (base/'signals.log').read_text()
 print('PASS MPRIS volume/rate actual SSIP acknowledgement and PropertiesChanged',flush=True)
 print('POSITION' ,call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Position'),flush=True)
 call('org.freedesktop.DBus.Properties.Set','org.mpris.MediaPlayer2.Player','Rate','<0.0>')
 assert call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','Rate') == rate
 seek_before=position()
 call('org.mpris.MediaPlayer2.Player.Seek','10000000')
 seek_after=position()
 (base/'rate-seek-range').write_text(str(seek_before//1000+10000)+' '+str(seek_after//1000+10000))
 mark('controls-done')
 wait('no-next')
 call('org.mpris.MediaPlayer2.Player.Seek','9223372036854775807')
 mark('no-next-done')
 wait('no-seek')
 call('org.mpris.MediaPlayer2.Player.Seek','1000000')
 call('org.mpris.MediaPlayer2.Player.SetPosition','/org/mpris/MediaPlayer2/track/1','5000000')
 mark('no-seek-done')
 wait('stale-stop')
 assert 'Playing' in call('org.freedesktop.DBus.Properties.Get','org.mpris.MediaPlayer2.Player','PlaybackStatus')
 zero=subprocess.run(['gdbus','call','--session','--dest','org.mpris.MediaPlayer2.fqapp','--object-path','/org/mpris/MediaPlayer2','--method','org.freedesktop.DBus.Properties.Set','org.mpris.MediaPlayer2.Player','Rate','<0.0>'],capture_output=True,text=True,timeout=6)
 print('RATE_ZERO',zero.returncode,zero.stdout,zero.stderr,flush=True)
 mark('stale-checked')
 wait('released')
 assert 'false' in call('org.freedesktop.DBus.NameHasOwner','org.mpris.MediaPlayer2.fqapp',dest='org.freedesktop.DBus',path='/org/freedesktop/DBus')
 mark('released-checked')
 result=app.wait(timeout=20)
 print((base/'app.log').read_text(),flush=True)
 assert result==0,result
 assert 'READY_CLOSE' in (base/'app.log').read_text()
 # Keep every exit diagnostic; exit=0 does not assert a warning-free process.
 print('EXIT DIAGNOSTICS', (base/'app.log').read_text().count('without an engine'), 'messenger warnings; retained, not a clean-exit assertion',flush=True)
 print('PASS real engine active-speech close exit=0',flush=True)
 assert zero.returncode==0, 'MPRIS Rate=0 must act as Pause, not reject Unsupported setting'
finally:
 for child in reversed(children):
  if child.poll() is None:child.terminate()
 for child in children:
  try:child.wait(timeout=5)
  except subprocess.TimeoutExpired:child.kill();child.wait()
""")
env['FQAPP_RUNTIME_EXE']=str(pathlib.Path.cwd()/'build/linux/x64/release/bundle/fqapp')
print(base,flush=True)
r=subprocess.run(['dbus-run-session','--','python3',str(driver)],env=env)
raise SystemExit(r.returncode)
