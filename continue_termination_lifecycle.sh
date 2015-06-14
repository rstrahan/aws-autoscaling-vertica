#! /bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Intended for rare occasions when you need to terminate instances that, due to incomplete setup, are
# stuck in termination due to unprocessed lifecycle hooks.
# Read SQS queue - for each teremination message, continue lifecycle and delete message

. ./autoscaling_vars.sh

# Get URL for ScaleDown SQS queue
scaleDown_url=$( aws --output=text sqs list-queues | grep "${autoscaling_group_name}_ScaleDown" | awk '{print $2}')

# Read and parse all pending messages, one at a time
i=0
while [ 1 ]; do
   # read queue
   # (a scaleDown may involve multiple instances / messages - we want to read them all)
   msg=$(aws --output=json sqs receive-message --wait-time-seconds 20 --queue-url $scaleDown_url)
   [ -z "$msg" ] && break  # no more messages waiting
   msgBody=$(echo "$msg" | python -c 'import sys, json; print json.load(sys.stdin)["Messages"][0]["Body"]')
   msgHandle=$(echo "$msg" | python -c 'import sys, json; print json.load(sys.stdin)["Messages"][0]["ReceiptHandle"]')
   echo $msgBody | grep "TEST_NOTIFICATION" > /dev/null
   if [ ! $? -eq 0 ]; then
      echo "ScaleDown SQS Message Received - $msgBody"
      lifecycleTransition=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["LifecycleTransition"]')
      lifecycleActionToken=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["LifecycleActionToken"]')
      eC2InstanceId=$(echo "$msgBody" | python -c 'import sys, json; print json.load(sys.stdin)["EC2InstanceId"]')
      privateIp=$(aws --output=text ec2 describe-instances --instance-ids $eC2InstanceId --query "Reservations[*].Instances[*].PrivateIpAddress")
      echo "Issue autoscaling complete-lifecycle-action for instance: $eC2InstanceId / $privateIp"
      aws autoscaling complete-lifecycle-action --lifecycle-action-token $lifecycleActionToken --lifecycle-hook-name ${autoscaling_group_name}_ScaleDown --auto-scaling-group-name ${autoscaling_group_name} --lifecycle-action-result CONTINUE
      ((i=i+1))
   else
      echo "Skipping unimportant message: autoscaling:TEST_NOTIFICATION => $msgBody"
   fi
   aws sqs delete-message --queue-url $scaleDown_url --receipt-handle $msgHandle
   echo "Message deleted from SQS queue"
done

echo Done
