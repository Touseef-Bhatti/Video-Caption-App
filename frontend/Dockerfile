FROM ghcr.io/cirruslabs/flutter:3.27.3 AS builder

WORKDIR /app/frontend
COPY frontend/pubspec.yaml frontend/pubspec.lock ./
RUN flutter pub get
COPY frontend/ ./

ARG API_BASE_URL=http://localhost:9001
RUN flutter build web --release \
    --dart-define=API_BASE_URL=${API_BASE_URL} \
    --no-web-resources-cdn \
    --pwa-strategy=none

FROM nginx:1.27-alpine
COPY frontend/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/frontend/build/web/ /usr/share/nginx/html/
EXPOSE 80
