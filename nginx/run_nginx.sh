#!/bin/bash

echo "Starting nginx on port $1, with user $2 password $3"
CONF_NAME="nginx.conf.$1"
cp mime.types /tmp/mime.types
sed s/LISTEN_PORT/$1/ < nginx.conf > /tmp/$CONF_NAME
printf "$2:$(openssl passwd -apr1 $3)\n" > /tmp/nginx_password_file
exec ./sbin/nginx -c /tmp/$CONF_NAME
