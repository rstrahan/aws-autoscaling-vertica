#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Will terminate the autoscaling cluster - entirely!
. ./autoscaling_vars.sh

echo "WARNING: You are about to terminate your Vertica cluster [$autoscaling_group_name]. All data will be lost!"
echo -n "Are you sure? Y/N [N]"
read ans
if [ "$ans" != "Y" -a "$ans" != "y" ]; then
   echo "Aborting on user request"
   exit 1
fi

echo "Delete Lifecycle Hook [${autoscaling_group_name}_ScaleDown]"
aws autoscaling delete-lifecycle-hook --lifecycle-hook-name ${autoscaling_group_name}_ScaleDown --auto-scaling-group-name $autoscaling_group_name

echo "Delete Autoscaling Group [$autoscaling_group_name] - this will terminate all associated instances"
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $autoscaling_group_name --force-delete

echo "Delete Launch Configuration [$launch_configuration_name]"
aws autoscaling delete-launch-configuration --launch-configuration-name $launch_configuration_name 

echo "Done"
