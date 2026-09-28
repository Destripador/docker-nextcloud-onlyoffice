FROM python:3.13.7-alpine

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apk add --no-cache \
    bash \
    coreutils \
    docker-cli \
    docker-cli-compose \
    git \
    gzip \
    jq \
    openssl \
    tar

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY backup_job.py .
COPY update_job.py .
COPY templates ./templates
COPY static ./static

RUN addgroup -S manager && adduser -S -G manager manager

EXPOSE 8090

CMD ["gunicorn", "--bind", "0.0.0.0:8090", "--workers", "2", "--threads", "4", "--timeout", "30", "app:app"]
