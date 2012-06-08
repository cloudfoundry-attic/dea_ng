#!/bin/bash

#just change this when nginx version is upgraded.
export NGINX_VERSION='1.0.4'
export NGINX_HOME="/var/vcap.local/dea2/nginx"
export NGINX_TMP="/tmp/nginx"

export NGINX_NAME="nginx-$NGINX_VERSION"
export NGINX_DIR=$NGINX_NAME
export NGINX_SRC="$NGINX_NAME.tar.gz"

echo "Building version $NGINX_VERSION"
echo "NGINX_HOME=$NGINX_HOME"
echo "NGINX_TMP=$NGINX_TMP"

echo "Removing previous build"
rm -rf $NGINX_DIR
rm -rf current

echo "Unpacking src"
tar xzf src/$NGINX_SRC
ln -s $NGINX_DIR current

echo "Configuring build, details in setup.out"
cp setup.sh current
cd $NGINX_DIR ; source ./setup.sh &> setup.out
cd ..

echo "Building nginx, details in $NGINX_DIR/make.out"
cd $NGINX_DIR ; make &> make.out;
cd ..

echo "Installing nginx, details in $NGINX_DIR/install.out"
cd $NGINX_DIR ; make install &> install.out
cd ..

echo "Configuring nginx"
cp nginx.conf $NGINX_HOME
cp run_nginx.sh  $NGINX_HOME
