#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Setup auto scaling, and initiate a 1-node group for bootstrapping
. ./autoscaling_vars.sh

echo "Create placement group for new cluster"
aws ec2 create-placement-group --group-name $placement_group --strategy cluster

echo "Create Launch Configuration"
aws autoscaling create-launch-configuration --launch-configuration-name $launch_configuration_name --image-id $image_id --key-name $key_name --security-groups $security_group_id --instance-type $instance_type --associate-public-ip-address --instance-monitoring Enabled=false --user-data file://launch.sh

echo "Create Autoscaling Group  (one node only for bootstrapping) – this will launch one new EC2 instance"
# termination policy "NewestInstance" - Last in First Out - makes it easier to maintain client connection to earliest provisioned nodes
aws autoscaling create-auto-scaling-group --auto-scaling-group-name $autoscaling_group_name --launch-configuration-name $launch_configuration_name --min-size 1 --max-size $max --desired-capacity 1 --default-cooldown $cooldown --placement-group $placement_group --vpc-zone-identifier $subnet_id --termination-policies "NewestInstance" --tags Key=Name,Value=$autoscaling_group_name

echo "Create SQS queue to use for Autoscaling Lifecycle Hook Notifications"
aws sqs create-queue --queue-name ${autoscaling_group_name}_ScaleDown > /dev/null

echo "Add EC2_INSTANCE_TERMINATING lifecycle hook to the autoscaling group"
role_arn=$(aws --output json iam get-role --role-name autoscale_lifecyclehook | grep -i "Arn" | awk '{print $2}' | tr -d '"')
down_url=$( aws --output=text sqs list-queues | grep "${autoscaling_group_name}_ScaleDown" | awk '{print $2}')
down_arn=$(aws --output=json sqs get-queue-attributes --queue-url $down_url --attribute-names QueueArn | grep "QueueArn" | awk '{print $2}' | tr -d '"')
aws autoscaling put-lifecycle-hook --lifecycle-hook-name ${autoscaling_group_name}_ScaleDown --auto-scaling-group-name $autoscaling_group_name --lifecycle-transition autoscaling:EC2_INSTANCE_TERMINATING --notification-target-arn $down_arn --role-arn $role_arn

echo "Create SNS Topic"
aws sns create-topic --name $sns_topic > /dev/null

echo "Add SNS Notification topic to Autoscaling group"
sns_arn=$(aws --output text sns list-topics | egrep ":$sns_topic\s*$" | awk '{ print $2 }')
aws autoscaling put-notification-configuration --auto-scaling-group-name $autoscaling_group_name --topic-arn $sns_arn --notification-types autoscaling:EC2_INSTANCE_LAUNCH autoscaling:EC2_INSTANCE_LAUNCH_ERROR autoscaling:EC2_INSTANCE_TERMINATE autoscaling:EC2_INSTANCE_TERMINATE_ERROR


cat << EOF

Summary:
========
Placement Group: 	$placement_group
Launch Configuration: 	$launch_configuration_name (min=1,desired=1,max=$max)
Autoscaling Group: 	$autoscaling_group_name
SQS Queue:		${autoscaling_group_name}_ScaleDown 
LifeCycle Hook:		${autoscaling_group_name}_ScaleDown (autoscaling:EC2_INSTANCE_TERMINATING)
SNS Topic:		$sns_topic
EOF

