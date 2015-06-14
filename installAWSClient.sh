#! /bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Automates installation of AWS CLI

sudo sh -c '(
. ./autoscaling_vars.sh
echo Install & configure AWS CLI
cd /tmp
curl https://s3.amazonaws.com/aws-cli/awscli-bundle.zip -o awscli-bundle.zip
unzip -o awscli-bundle.zip
./awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
mkdir -p ~/.aws
cat > ~/.aws/credentials <<EOF
[default]
aws_access_key_id = $aws_access_key_id
aws_secret_access_key = $aws_secret_access_key
EOF
cat > ~/.aws/config <<EOF
[default]
output = table
region = $region
EOF
chmod 600 ~/.aws/*
cp -R ~/.aws ~dbadmin
chown -R dbadmin.verticadba ~dbadmin/.aws
chmod 600 ~dbadmin/.aws/*
)'
echo AWS CLI installed
