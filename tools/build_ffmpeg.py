#!/usr/bin/env python3
"""Build pinned minimal FFmpeg libraries for tvOS, iOS, or macOS (arm64)."""
from pathlib import Path
import argparse, hashlib, os, shutil, subprocess, tarfile, tempfile, urllib.request
parser = argparse.ArgumentParser()
parser.add_argument("--platform", choices=["tvos", "ios", "macos"], default="tvos")
platform = parser.parse_args().platform
sdk_name = {"ios": "iphoneos", "tvos": "appletvos", "macos": "macosx"}[platform]
target = {"ios": "arm64-apple-ios26.0", "tvos": "arm64-apple-tvos26.6", "macos": "arm64-apple-macos15.0"}[platform]
ROOT = Path(__file__).resolve().parent.parent
VERSION = '8.0.1'
SHA256 = '05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41'
with tempfile.TemporaryDirectory(prefix='boramin-ffmpeg-') as temp:
    work = Path(temp)
    archive = work/'source.tar.xz'
    urllib.request.urlretrieve(f'https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz', archive)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == SHA256, 'FFmpeg archive checksum mismatch'
    with tarfile.open(archive) as tar: tar.extractall(work, filter='data')
    source = work/f'ffmpeg-{VERSION}'
    sdk = work/'sdk'
    sdk.symlink_to(subprocess.check_output(['xcrun','--sdk',sdk_name,'--show-sdk-path'],text=True).strip())
    install = work/'install'
    args = [f'--prefix={install}', '--enable-cross-compile','--target-os=darwin','--arch=arm64',
        f'--cc=xcrun --sdk {sdk_name} clang',f'--sysroot={sdk}',
        f'--extra-cflags=-target {target} -O3',f'--extra-ldflags=-target {target}',
        '--disable-programs','--disable-doc','--disable-debug','--disable-network','--disable-autodetect','--disable-everything',
        '--enable-avformat','--enable-avcodec','--enable-avutil','--enable-swresample','--enable-protocol=file',
        '--enable-demuxer=matroska,mov,avi,mpegts,mp3,aac,flac',
        '--enable-muxer=mp4',
        '--enable-parser=vp9,h264,hevc,av1,mpeg4video,mpegvideo,opus,aac,ac3,vorbis,flac,mpegaudio',
        '--enable-decoder=opus,vorbis,aac,ac3,eac3,flac,mp3,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be,alac,dca',
        '--enable-static','--disable-shared']
    for command in [[str(source/'configure'),*args],['make',f'-j{min(os.cpu_count() or 4,8)}'],['make','install']]:
        subprocess.run(command,cwd=source,check=True)
    destination = ROOT/'vendor'/{'ios': 'ffmpeg-ios', 'tvos': 'ffmpeg', 'macos': 'ffmpeg-macos'}[platform]
    for folder in ['include','lib']:
        shutil.copytree(install/folder,destination/folder,dirs_exist_ok=True)
    shutil.copy2(source/'COPYING.LGPLv2.1',ROOT/'vendor'/'FFmpeg-LICENSE.txt')
print(f'Built physical {platform} arm64 FFmpeg libraries in',destination)
