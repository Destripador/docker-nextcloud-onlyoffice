# La imagen base es obligatoria y debe incluir la variante FPM Alpine.
ARG NEXTCLOUD_IMAGE
FROM ${NEXTCLOUD_IMAGE}

ARG SMBCLIENT_VERSION=1.1.2

USER root

RUN set -eux; \
    mkdir -p /usr/share/man/man1; \
    apk add --no-cache \
        ffmpeg \
        imagemagick \
        libreoffice \
        procps \
        samba-client \
        supervisor

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        $PHPIZE_DEPS \
        bzip2-dev \
        samba-dev; \
    docker-php-ext-install -j"$(nproc)" \
        bz2 \
        mysqli; \
    pecl install "smbclient-${SMBCLIENT_VERSION}"; \
    docker-php-ext-enable smbclient; \
    runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .nextcloud-phpext-rundeps ${runDeps}; \
    apk del .build-deps

RUN set -eux; \
    mkdir -p \
        /var/log/supervisord \
        /var/run/supervisord

COPY supervisord.conf /supervisord.conf

# Se reemplaza el CMD oficial, pero se conserva su entrypoint. Esta variable
# mantiene la inicialización/actualización antes de que Supervisor arranque FPM.
ENV NEXTCLOUD_UPDATE=1

CMD ["/usr/bin/supervisord", "-c", "/supervisord.conf"]
