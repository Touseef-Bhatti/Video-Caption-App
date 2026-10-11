FROM ghcr.io/cirruslabs/flutter:3.27.3 AS renderer
WORKDIR /renderer-src
COPY frontend/pubspec.yaml frontend/pubspec.lock ./
RUN flutter pub get
COPY frontend/ ./
RUN flutter build web --release --target lib/render_main.dart --output build/renderer --no-web-resources-cdn --pwa-strategy=none

FROM python:3.12-slim AS base

# FFmpeg + libass + RTL-capable fonts. Never assume these exist on the host.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    chromium \
    libass9 \
    fonts-noto \
    fonts-noto-core \
    fonts-noto-extra \
    fonts-noto-ui-core \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    fonts-dejavu-core \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/share/fonts/truetype/noto-rtl && \
    curl -fsSL -o /usr/share/fonts/truetype/noto-rtl/NotoNaskhArabic-Regular.ttf \
      https://raw.githubusercontent.com/google/fonts/main/ofl/notonaskharabic/NotoNaskhArabic%5Bwght%5D.ttf || true && \
    curl -fsSL -o /usr/share/fonts/truetype/noto-rtl/NotoNastaliqUrdu-Regular.ttf \
      https://raw.githubusercontent.com/google/fonts/main/ofl/notonastaliqurdu/NotoNastaliqUrdu%5Bwght%5D.ttf || true && \
    fc-cache -f

WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ .
COPY --from=renderer /renderer-src/build/renderer /opt/caption-renderer
RUN mkdir -p /tmp/caption_app/uploads /tmp/caption_app/processing /tmp/caption_app/outputs

EXPOSE 8000
CMD ["gunicorn", "app.main:app", "-k", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000", "--workers", "4", "--timeout", "120"]
