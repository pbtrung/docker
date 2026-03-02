FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget rqlite nginx apache2-utils su-exec

RUN addgroup -g 1000 rqlite && \
    adduser -u 1000 -G rqlite -D rqlite

WORKDIR /script
COPY entrypoint.sh /script/
COPY nginx.conf /script/nginx.conf

EXPOSE 4001 4002

ENTRYPOINT ["/script/entrypoint.sh"]
CMD ["run"]
