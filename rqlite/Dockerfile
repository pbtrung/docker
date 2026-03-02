FROM alpine:edge

RUN apk update && \
    apk --no-cache upgrade && \
    apk --no-cache add wget rqlite

RUN addgroup -g 1000 rqlite && \
    adduser -u 1000 -G rqlite -D rqlite

WORKDIR /script
COPY entrypoint.sh /script/

EXPOSE 4001 4002
USER rqlite

ENTRYPOINT ["/script/entrypoint.sh"]
