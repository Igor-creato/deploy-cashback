# F-S1-004: digest-pinned. Update flow: `docker pull python:3.13-slim`
# затем подставить новый digest сюда.
FROM python:3.13-slim@sha256:a0779d7c12fc20be6ec6b4ddc901a4fd7657b8a6bc9def9d3fde89ed5efe0a3d

WORKDIR /srv

RUN apt-get update && apt-get install -y --no-install-recommends wget && rm -rf /var/lib/apt/lists/*

# starlette ЯВНО запинен для воспроизводимости (FastAPI 0.136.1 требует
# `starlette>=0.46.0` без верхней границы). 1.0.0 — первый stable; миграция
# на lifespan выполнена (app/receiver.py использует FastAPI(lifespan=...),
# не снятый в 1.0 @app.on_event). Бампать осознанно, проверяя CHANGELOG.
RUN pip install --no-cache-dir \
    fastapi==0.136.1 \
    starlette==1.0.0 \
    uvicorn[standard]==0.47.0 \
    redis==7.4.0 \
    pymysql==1.1.3 \
    cryptography==47.0.0 \
    jinja2==3.1.6 \
    python-multipart==0.0.29 \
    httptools==0.7.1 \
    prometheus_client==0.25.0 \
    phpserialize==1.3

COPY . .

ENV PYTHONPATH=/srv
ENV PYTHONUNBUFFERED=1

EXPOSE 8098 8099 9100
