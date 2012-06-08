#!/bin/sh

./configure \
  --prefix=$NGINX_HOME \
  --sbin-path=$NGINX_HOME/sbin/nginx \
  --conf-path=$NGINX_HOME/nginx.conf \
  --error-log-path=$NGINX_TMP/nginx.log \
  --pid-path=$NGINX_TMP/nginx.pid \
  --lock-path=$NGINX_TMP/nginx.lock \
  --http-log-path=$NGINX_TMP/access.log \
  --with-http_stub_status_module \
  --with-debug
