#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Returns a list of public / private IP addresses for each node in the cluster

. ./autoscaling_vars.sh

instanceIds=$(aws --output=text ec2 describe-instances --filters Name=tag-key,Values=Name,Name=tag-value,Values=$autoscaling_group_name Name=instance-state-code,Values=16 --query "Reservations[*].Instances[*].InstanceId")

for instanceId in $instanceIds
do
   privateIps=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" | awk '{for (i=NF;i>0;i--){printf $i" "}}')
   publicIps=$(aws --output=text ec2 describe-instances --instance-id $instanceId --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].Association.PublicIp")
   echo "$instanceId: PublicIP [$publicIps], PrivateIP [$privateIps]"
done

