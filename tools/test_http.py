#!/usr/bin/env python3
"""Isolated HTTP integration: real Caddy plus deliberately broken range/listing servers.
Uses generated media and synthetic credentials only; never contacts a saved connection.
Run sequentially with other playback probes. Requires caddy and ffmpeg on PATH.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

metrics = {'unranged': 0, 'redirect_leaks': 0, 'ignored_sent': 0, 'slow_reads': 0}
class Faults(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def handle(self):
        try: super().handle()
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        try: self.respond()
        except (BrokenPipeError, ConnectionResetError): pass
    def respond(self):
        mode = self.path.strip('/').split('/')[0]
        credentials = {
            'credentials-anonymous': None,
            'credentials-username': 'fixture:',
            'credentials-password': ':test-only',
            'credentials-both': 'fixture:test-only',
        }
        if mode in credentials:
            pair = credentials[mode]
            expected = None if pair is None else 'Basic ' + base64.b64encode(pair.encode()).decode()
            if self.headers.get('Authorization') != expected:
                self.send_error(403); return
        if mode == 'leak': metrics['redirect_leaks'] += 1
        if mode == 'slow': time.sleep(3)
        if self.path.endswith('/'):
            if self.headers.get('Accept') != 'application/json': raise AssertionError('No JSON Accept header')
            if mode == 'html': data, mime = b'<html>not json</html>', 'text/html'
            elif mode == 'bad-json': data, mime = b'{bad}', 'application/json'
            elif mode == 'speed-test': data, mime = b'[{"name":"movie.bin","size":1048576}]', 'application/json'
            elif mode == 'bad-name': data, mime = b'[{"name":"../outside","size":1,"is_dir":false}]', 'application/json'
            else: data, mime = b'[]', 'application/json'
            self.send_response(200); self.send_header('Content-Type', mime)
            self.send_header('Content-Length', 10 * 1024 * 1024 if mode == 'large-listing' else len(data))
            self.end_headers(); self.wfile.write(data)
            return
        byte_range = self.headers.get('Range')
        if not byte_range:
            metrics['unranged'] += 1
            self.send_error(400); return
        start, end = map(int, byte_range.removeprefix('bytes=').split('-'))
        probe = end == 0
        if mode == 'slow-probe' and probe: time.sleep(3)
        if mode == 'slow-read' and not probe:
            metrics['slow_reads'] += 1
            if metrics['slow_reads'] == 1: time.sleep(3)
        if mode in ('outside', 'cross-origin'):
            self.send_response(302)
            host = 'localhost' if mode == 'cross-origin' else '127.0.0.1'
            self.send_header('Location', f'http://{host}:{self.server.server_port}/leak/movie.bin')
            self.send_header('Content-Length', 0); self.end_headers(); return
        if mode == 'ignored' and not probe:
            self.send_response(200); self.send_header('Content-Length', 512 * 1024 * 1024); self.end_headers()
            try:
                for _ in range(512):
                    self.wfile.write(b'x' * 16384); self.wfile.flush()
                    metrics['ignored_sent'] += 16384
                    time.sleep(0.002)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if mode == 'unsatisfiable': self.send_error(416); return
        self.send_response(206)
        count = end - start + 1
        wrong = mode == 'wrong-range' and not probe
        self.send_header('Content-Range', f'bytes {start + (1 if wrong else 0)}-{end}/1048576')
        self.send_header('ETag', '"changed"' if mode == 'changed' and not probe else '"fixture"')
        if mode == 'encoded': self.send_header('Content-Encoding', 'gzip')
        if mode == 'oversized' and not probe:
            self.send_header('Transfer-Encoding', 'chunked'); self.end_headers()
            data = b'x' * (count + 1)
            self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n0\r\n\r\n'); return
        self.send_header('Content-Length', count + (1 if mode == 'wrong-length' and not probe else 0))
        self.end_headers()
        data = b'x' * count
        if mode == 'speed-test':
            # Deliver a prefix, then leave the response open until the client cancels.
            self.wfile.write(data[:65536]); self.wfile.flush()
            self.connection.settimeout(20)
            try: self.connection.recv(1)
            except TimeoutError: pass
            self.close_connection = True
        elif mode == 'truncated' and not probe:
            self.wfile.write(data[:10]); self.close_connection = True
        else: self.wfile.write(data)

with tempfile.TemporaryDirectory(prefix='boramin-http-') as temporary:
    folder = Path(temporary)
    media = folder/'media'; media.mkdir()
    (media/'Folder').mkdir(); (media/'Folder/child.txt').write_text('fixture')
    (media/'.hidden.mp4').write_text('hidden fixture')
    (media/'Movie #1% 日本.srt').write_text('1\n00:00:00,000 --> 00:00:07,000\nHTTP subtitle fixture\n')
    subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i','testsrc2=size=320x180:rate=24',
                    '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','8',
                    '-c:v','libx264','-preset','fast','-g','24','-c:a','aac','-movflags','+faststart',
                    str(media/'Movie #1% 日本.mp4')], check=True)
    (media/'Engines').mkdir()
    for filename, video_codec, audio_codec, extra in [
        ('native.mkv', 'copy', 'copy', []),
        ('software.avi', 'mpeg4', 'libmp3lame', ['-q:v', '5']),
        ('vp9.webm', 'libvpx-vp9', 'libopus', ['-deadline', 'realtime', '-cpu-used', '8', '-g', '24'])
    ]:
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(media/'Movie #1% 日本.mp4'),
                        '-c:v', video_codec, '-c:a', audio_codec, *extra, str(media/'Engines'/filename)], check=True)
    with (media/'big.bin').open('wb') as output:
        output.truncate(140 * 1024 * 1024)
        for index in range(560):
            output.seek(index * 256 * 1024); output.write(struct.pack('<Q', index))
    port = free_port()
    password_hash = subprocess.check_output(['caddy','hash-password','--plaintext','test-only'], text=True).strip()
    config = folder/'Caddyfile'
    config.write_text('''{\n admin off\n auto_https off\n}\nhttp://127.0.0.1:%d {
 handle_path /media/* {
  root * "%s"
  file_server browse
 }
 handle_path /auth/* {
  basic_auth {
   fixture %s
  }
  root * "%s"
  file_server browse
 }
}
''' % (port, media, password_hash, media))
    logs = root/'build/HTTPValidation'; logs.mkdir(parents=True, exist_ok=True)
    fault_server = ThreadingHTTPServer(('127.0.0.1', 0), Faults)
    threading.Thread(target=fault_server.serve_forever, daemon=True).start()
    with (logs/'caddy.log').open('w') as log:
        process = subprocess.Popen(['caddy','run','--config',str(config),'--adapter','caddyfile'], stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(('127.0.0.1',port), timeout=0.1): break
                except OSError:
                    if process.poll() is not None: raise RuntimeError('Caddy failed; see build/HTTPValidation/caddy.log')
                    time.sleep(0.05)
            urls = [f'http://127.0.0.1:{port}/media/', f'http://127.0.0.1:{fault_server.server_port}/']
            app = root/'build/AetherSoftwareTests/Derived/Build/Products/Release/BoraMin.app'
            if args.skip_build: command = [str(app/'Contents/MacOS/BoraMin'), *urls]
            else: command = [sys.executable, str(root/'tools/run_playback_probe.py'), 'http', *urls]
            subprocess.run(command, cwd=root, check=True, timeout=300)
            assert metrics['unranged'] == 0, metrics
            assert metrics['redirect_leaks'] == 0, metrics
            assert metrics['ignored_sent'] < 8 * 1024 * 1024, metrics
            print('PASS: no unbounded file GET, no credential-bearing redirect, ignored-range body stopped early', flush=True)
        finally:
            process.terminate(); process.wait(timeout=10)
            fault_server.shutdown(); fault_server.server_close()
            # Remove the generated diagnostic app to avoid duplicate BoraMin copies.
            if app.exists(): shutil.rmtree(app)
