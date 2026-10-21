"""Exercise the actual Windows DLL + C decoder + loopback Range transport.

Requires FFmpeg on PATH. No upstream account/content or third-party Python deps.
"""
import ctypes
import hashlib
import http.client
import http.server
import json
import pathlib
import random
import subprocess
import threading
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'build' / 'validation' / 'windows-media'
OUTPUT.mkdir(parents=True, exist_ok=True)
LIB = ctypes.CDLL(str(ROOT / 'rust/target/release/fqapi_core.dll'))
LIB.fq_desktop_media_open.argtypes = [ctypes.c_char_p]
LIB.fq_desktop_media_open.restype = ctypes.c_void_p
LIB.fq_desktop_media_free.argtypes = [ctypes.c_void_p]
LIB.fq_desktop_media_close.argtypes = [ctypes.c_char_p]
KEY = '00112233445566778899aabbccddeeff'


def ffmpeg(*args):
    return subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin', *args],
                          check=True, capture_output=True).stdout


def open_media(source, key=''):
    pointer = LIB.fq_desktop_media_open(json.dumps({'url': source, 'key': key}).encode())
    assert pointer, 'Native open returned null'
    try:
        value = json.loads(ctypes.string_at(pointer))
    finally:
        LIB.fq_desktop_media_free(pointer)
    assert 'error' not in value, value
    assert KEY not in value['url'] and '127.0.0.1:' in value['url']
    return value


def request(url, headers=None, method='GET'):
    parsed = urllib.parse.urlsplit(url)
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=20)
    try:
        connection.request(method, parsed.path, headers=headers or {})
        response = connection.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        connection.close()


class RangeSource(http.server.BaseHTTPRequestHandler):
    data = b''
    bytes_sent = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        value = self.headers.get('Range', '')
        assert value.startswith('bytes=')
        start, end = value[6:].split('-')
        start, end = int(start), min(int(end or len(self.data) - 1), len(self.data) - 1)
        body = self.data[start:end + 1]
        type(self).bytes_sent += len(body)
        self.send_response(206)
        self.send_header('Content-Range', f'bytes {start}-{end}/{len(self.data)}')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def check_ranges(session, expected):
    url = session['url']
    status, headers, body = request(url, method='HEAD')
    assert status == 200 and body == b'' and int(headers['Content-Length']) == len(expected)
    rng = random.Random(20261020)
    for _ in range(24):
        start = rng.randrange(len(expected))
        end = min(start + rng.randrange(1, 8192), len(expected) - 1)
        status, headers, body = request(url, {'Range': f'bytes={start}-{end}'})
        assert status == 206 and body == expected[start:end + 1]
        assert headers['Content-Range'] == f'bytes {start}-{end}/{len(expected)}'
    assert request(url, {'Range': 'bytes=-17'})[2] == expected[-17:]
    assert request(url, {'Range': f'bytes={len(expected)}-'})[0] == 416
    assert request(url, {'Range': 'bytes=0-1,3-4'})[0] == 416
    assert request(url, {'Host': 'evil.example'})[0] == 403
    assert request(url, {'Origin': 'https://evil.example'})[0] == 403
    assert request(url + '-invalid')[0] == 403
    LIB.fq_desktop_media_close(session['id'].encode())
    time.sleep(.1)
    try:
        status = request(url)[0]
        assert status == 403
    except (ConnectionError, OSError):
        pass


def main():
    clear = OUTPUT / 'reference.mp4'
    encrypted = OUTPUT / 'encrypted.mp4'
    decoded = OUTPUT / 'decoded.mp4'
    ffmpeg('-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12',
           '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100',
           '-t', '1.25', '-c:v', 'libx264', '-preset', 'ultrafast',
           '-pix_fmt', 'yuv420p', '-c:a', 'aac', str(clear))
    ffmpeg('-y', '-i', str(clear), '-map', '0', '-c', 'copy',
           '-encryption_scheme', 'cenc-aes-ctr', '-encryption_key', KEY,
           '-encryption_kid', '102132435465768798a9bacbdcedfe0f', str(encrypted))
    plain = clear.read_bytes()
    check_ranges(open_media(clear.as_uri()), plain)
    session = open_media(encrypted.as_uri(), KEY)
    status, _, decrypted = request(session['url'])
    assert status == 200
    decoded.write_bytes(decrypted)
    reference_hashes = ffmpeg('-i', str(clear), '-map', '0:v:0', '-map', '0:a:0', '-f', 'framemd5', '-')
    decoded_hashes = ffmpeg('-i', str(decoded), '-map', '0:v:0', '-map', '0:a:0', '-f', 'framemd5', '-')
    assert reference_hashes == decoded_hashes, 'Decrypted video/audio frames differ'
    check_ranges(session, decrypted)
    RangeSource.data = encrypted.read_bytes()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RangeSource)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        online = open_media(f'http://127.0.0.1:{server.server_port}/video', KEY)
        check_ranges(online, decrypted)
    finally:
        server.shutdown()
        server.server_close()
    report = {'passed': True, 'checks': ['plain local playback', 'CENC local video+audio frame parity',
              'online encrypted Range source', 'random seek/range bytes', 'HEAD/suffix/416',
              'Host/Origin/capability validation', 'session cleanup'],
              'decoded_sha256': hashlib.sha256(decrypted).hexdigest(), 'upstream_bytes_read': RangeSource.bytes_sent}
    (OUTPUT / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
