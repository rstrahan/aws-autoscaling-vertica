#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run as part of bootstrapping first instance.. creates 1-node cluster
. ./autoscaling_vars.sh

autoscale_dir=/home/dbadmin/autoscale

privateIp=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].PrivateIpAddress"); echo PrivateIP: $privateIp

[ -e $autoscale_dir/license.dat ] && license=$autoscale_dir/license.dat || license=CE
sudo /opt/vertica/sbin/install_vertica --add-hosts $privateIp --point-to-point --ssh-identity $autoscale_dir/key.pem -L $license --dba-user-password-disabled --data-dir /vertica/data -Y


