#!/bin/bash
# Sample files in old camera formats for LegacyImportTests (2 s test pattern, 440 Hz tone). Usage: make-legacy-media.sh <dir>
set -e
cd "$1"
F="ffmpeg -loglevel error -y"
src() { echo "-f lavfi -i testsrc2=s=$1:r=25 -f lavfi -i sine=frequency=440:sample_rate=$2"; }
# AVCHD 1080i50 (192-byte packets, AC-3)
$F $(src 1920x1080 48000) -t 2 -c:v libx264 -preset ultrafast -flags +ilme+ildct -x264-params tff=1:aud=1 -pix_fmt yuv420p -c:a ac3 -ac 2 -f mpegts -mpegts_m2ts_mode 1 legacy-avchd-1080i.mts
# AVCHD 1440x1080 anamorphic, LPCM
$F $(src 1440x1080 48000) -t 2 -vf setsar=4/3 -c:v libx264 -preset ultrafast -x264-params aud=1 -pix_fmt yuv420p -c:a pcm_bluray -ac 2 -f mpegts -mpegts_m2ts_mode 1 legacy-avchd-1440.m2ts
# TV-style TS: H.264 with B-frames + AAC
$F $(src 640x360 48000) -t 2 -c:v libx264 -preset fast -bf 3 -pix_fmt yuv420p -c:a aac -f mpegts legacy-tv.ts
# HEVC in TS + MP3
$F $(src 640x360 48000) -t 2 -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p -tag:v hvc1 -c:a libmp3lame -b:a 128k -f mpegts legacy-hevc.ts
# H.264 in TS + MP2 (no MP2 decoder on iOS: imported without sound, with a note)
$F $(src 640x360 48000) -t 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a mp2 -f mpegts legacy-mp2.ts
# Old compact camera: MJPEG + 8-bit PCM mono
$F $(src 640x480 8000) -t 2 -c:v mjpeg -q:v 4 -huffman default -pix_fmt yuvj420p -c:a pcm_u8 -ac 1 legacy-camera.avi
# MJPEG + IMA ADPCM
$F $(src 320x240 22050) -t 2 -r 30 -c:v mjpeg -q:v 4 -pix_fmt yuvj420p -c:a adpcm_ima_wav -ac 1 legacy-ima.avi
# MJPEG + MS ADPCM stereo
$F $(src 320x240 22050) -t 2 -c:v mjpeg -q:v 4 -pix_fmt yuvj420p -c:a adpcm_ms -ac 2 legacy-msadpcm.avi
# Xvid-style MPEG-4 + MP3
$F $(src 640x480 44100) -t 2 -c:v mpeg4 -vtag XVID -bf 0 -q:v 4 -pix_fmt yuv420p -c:a libmp3lame -b:a 128k legacy-xvid.avi
# H.264 in AVI + 16-bit PCM
$F $(src 640x360 48000) -t 2 -c:v libx264 -preset ultrafast -bf 0 -pix_fmt yuv420p -c:a pcm_s16le legacy-h264.avi
# MKV: H.264 with B-frames + AAC
$F $(src 1280x720 48000) -t 2 -c:v libx264 -preset fast -bf 3 -pix_fmt yuv420p -c:a aac legacy-bframes.mkv
# MKV: HEVC + AC-3 5.1
$F $(src 640x360 48000) -t 2 -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p -c:a ac3 -ac 6 legacy-hevc-51.mkv
# MKV: H.264 + Opus
$F $(src 640x360 48000) -t 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a libopus -b:a 96k legacy-opus.mkv
# Not convertible: VP9 WebM, MPEG-2 program stream
$F $(src 320x240 48000) -t 1 -c:v libvpx-vp9 -deadline realtime -c:a libopus legacy-vp9.webm
$F $(src 320x240 48000) -t 1 -c:v mpeg2video -c:a mp2 -f mpeg legacy-dvd.mpg
