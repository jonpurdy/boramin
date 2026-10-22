#!/usr/bin/env python3
"""Build pinned minimal FFmpeg libraries for physical tvOS or iOS (arm64)."""
from pathlib import Path
import argparse, hashlib, os, shutil, subprocess, tarfile, tempfile, urllib.request
parser = argparse.ArgumentParser()
parser.add_argument("--platform", choices=["tvos", "ios"], default="tvos")
platform = parser.parse_args().platform
sdk_name = "iphoneos" if platform == "ios" else "appletvos"
target = "arm64-apple-ios26.0" if platform == "ios" else "arm64-apple-tvos26.6"
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
        '--enable-parser=vp9,opus,aac,ac3,vorbis,flac,mpegaudio',
        '--enable-decoder=opus,vorbis,aac,ac3,eac3,flac,mp3,pcm_s16le,pcm_s24le,pcm_s32le,alac,dca',
        '--enable-static','--disable-shared']
    for command in [[str(source/'configure'),*args],['make',f'-j{min(os.cpu_count() or 4,8)}'],['make','install']]:
        subprocess.run(command,cwd=source,check=True)
    destination = ROOT/'vendor'/('ffmpeg-ios' if platform == 'ios' else 'ffmpeg')
    for folder in ['include','lib']:
        shutil.copytree(install/folder,destination/folder,dirs_exist_ok=True)
    shutil.copy2(source/'COPYING.LGPLv2.1',ROOT/'vendor'/'FFmpeg-LICENSE.txt')
print(f'Built physical {platform} arm64 FFmpeg libraries in',destination)
