FROM alpine:3.20

# NOTE: Alpine 3.20's unversioned "luarocks" package is an empty stub (zero
# files) -- the real binary is luarocks-5.1, from the luarocks5.1 package.
# Same gotcha already hit and fixed for the 13 music bots' Dockerfiles this
# session; do not revert to plain "luarocks".
RUN apk add --no-cache \
      luajit luajit-dev luarocks5.1 \
      build-base \
      libsodium-dev openssl-dev \
      git ca-certificates

# luarocks-5.1's own Lua-detection defaults don't find LuaJIT's headers/libs
# (it looks for /usr/include/lua/5.1, not where luajit-dev actually installs
# them), so point it at the real paths before installing anything.
RUN luarocks-5.1 config variables.LUA_INCDIR /usr/include/luajit-2.1 \
 && luarocks-5.1 config variables.LUA_LIBDIR /usr/lib

# Same rock set as the bots (lua-shared/README.md), pinned to Lua 5.1
# semantics so pgmoon/luasec/etc build against LuaJIT's ABI. cjson.safe
# (used by httpd.lua so a malformed request body 500s cleanly instead of
# throwing) ships inside the lua-cjson rock, no separate install needed.
RUN luarocks-5.1 install luasocket \
 && luarocks-5.1 install luasec \
 && luarocks-5.1 install lua-cjson \
 && luarocks-5.1 install pgmoon \
 && luarocks-5.1 install luasodium \
 && luarocks-5.1 install lua-websockets \
 && luarocks-5.1 install copas

WORKDIR /app

# Copy backend source (including the vendored lib/swarmlua/pg.lua + rest.lua,
# copied verbatim from lua-shared/swarmlua/ — same tested Postgres/Discord-
# REST plumbing the bots use, not reinvented here).
COPY . .

EXPOSE 8003

# PANEL_DB_PG_PORT / other env vars come from the compose env_file (see the
# orchestrator deployment notes in the final report — this backend talks to
# Postgres on 5432, not the MariaDB port 3306 still set as PANEL_DB_PORT).
CMD ["luajit", "main.lua"]
