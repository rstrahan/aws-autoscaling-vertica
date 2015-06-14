#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Bootstraps first cluster instance
. ./autoscaling_vars.sh

echo "Wait for first cluster instance to be in running state"
while [ 1 ]; do
   aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].State.Name" | grep running > /dev/null
   [ $? -eq 0 ] && break
   echo "Waiting another 60s for instance to be in running state"
   sleep 60
done

echo "Get public IP address of first instance"
publicIp=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name --query "Reservations[*].Instances[*].PublicIpAddress") 

echo "Copy files to node [$publicIp]"
while [ 1 ]; do
   ssh -i $pem_file -o "StrictHostKeyChecking no" dbadmin@$publicIp mkdir -p /home/dbadmin/autoscale 
   [ $? -eq 0 ] && break
   echo "Waiting another 60s for instance to accept connections"
   sleep 60
done
scp -i $pem_file $pem_file dbadmin@$publicIp:/home/dbadmin/autoscale/key.pem
scp -i $pem_file * dbadmin@$publicIp:/home/dbadmin/autoscale/
[ "$license_file" != "CE" ] && scp -i $pem_file $license_file dbadmin@$publicIp:/home/dbadmin/autoscale/license.dat
ssh -i $pem_file -o "StrictHostKeyChecking no" dbadmin@$publicIp chmod 400 /home/dbadmin/autoscale/key.pem

echo "Configure Vertica 1-node cluster on node [$publicIp]"
ssh -i $pem_file dbadmin@$publicIp '(
   cd ~/autoscale
   sh cluster_init.sh
)'
if [ $? -ne 0 ]; then
   echo "Failed to create cluster"
   exit 1
fi

echo "Configure Vertica 1-node cluster on node [$publicIp]"
ssh -i $pem_file dbadmin@$publicIp '(
   cd ~/autoscale
   sh database_init.sh
)'
if [ $? -ne 0 ]; then
   echo "Failed to create database"
   exit 1
fi

echo "Configure cron to check for ScaleDown SQS messages and DOWN nodes, every minute"
ssh -i $pem_file dbadmin@$publicIp '(
   echo -e "* * * * * /home/dbadmin/autoscale/read_scaledown_queue.sh\n* * * * * /home/dbadmin/autoscale/down_node_check.sh" | crontab -
)'
if [ $? -ne 0 ]; then
   echo "Failed to setup cron task"
   exit 1
fi

cat <<EOF

Summary
========
First Cluster Node: $publicIp  (ssh -i $pem_file dbadmin@$publicIp)
Database Name: $database_name  (vsql -h $publicIp -U dbadmin)

EOF
exit 0
