#!/bin/bash
./configure \
  --enable-decoder=myzigh264 \
  --extra-ldflags="-L/home/leoz/sources/FFmpeg/zig-out/lib -lmyzigh264" \
  --extra-libs="-lmyzigh264"
