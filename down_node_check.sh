#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run from cron schedule - checks for lifecycle hook termination messages on the SQS queue, and initiates cluster scaledown

. /home/dbadmin/.bashrc
PATH=/usr/local/bin:/opt/vertica/bin:${PATH}
autoscaleDir=/home/dbadmin/autoscale
. $autoscaleDir/autoscaling_vars.sh
time=$( date +"%Y-%m-%d %H:%M:%S")

# in non terminal mode, redirect stdout and stderr to logfile
if [ ! -t 0 ]; then exec >> $autoscaleDir/down_node_check.log 2>&1; fi
echo down_node_check.sh: [`date`]

myIp=$(hostname -I | awk '{print $NF}')

# check nodes table for DOWN nodes
if [ ! -z "$replace_down_node_after" -a $replace_down_node_after -gt 0 ]; then
   downNodes=$(vsql -qAt -c "SELECT node_address FROM nodes WHERE node_state='DOWN' AND node_down_since < now()-'$replace_down_node_after minutes'::INTERVAL")
   [ -z "$downNodes" ] && exit 0  # nothing to do!
   for downNode in $downNodes
   do
      echo "Node [$downNode] DOWN for more than $replace_down_node_after minutes."
      downSince=$(vsql -qAt -c "SELECT node_down_since FROM nodes WHERE node_address='$downNode'")
      # already detected? 
        # random short delay minimises chances of multiple simultaneous detection / duplicate downNodes entries
      sleep `shuf -i0-20 -n1` 
      isDetected=$(vsql -qAt -c "select count(*) from autoscale.downNodes WHERE node_address='$downNode' AND datediff(MINUTE,node_down_since,'$downSince') = 0")
      if [ $isDetected -eq 0 ]; then
         # not already detected.. initiate termination
         instId=$(vsql -qAt -c "SELECT ec2_instanceid FROM autoscale.launches WHERE node_address='$downNode' OR replace_node_address='$downNode' ORDER BY start_time DESC LIMIT 1")
         time=$(date +"%Y-%m-%d %H:%M:%S")
         echo "$myIp|$time|$downSince|$instId|$downNode" | \
            vsql -c "COPY autoscale.downNodes (detected_by_node, trigger_termination_time, node_down_since, ec2_instanceid, node_address) FROM STDIN"
         echo "Terminating EC2 instanceId [$instId]"
         aws ec2 terminate-instances --instance-ids $instId
         if [ $? -eq 0 ]; then
            status="AWS EC2 instance [$instId] / IP [$downNode] terminated. This will trigger auto scale to launch a replacement."
         else
            status="Error Returned [$?]: Cmd> aws ec2 terminate-instances --instance-ids $instId"
         fi
         echo "Update status: $status"
         vsql -c "UPDATE autoscale.downNodes SET status='$status' WHERE node_address='$downNode' AND node_down_since='$downSince'; COMMIT;"
      else
         detectedBy=$(vsql -qAt -c "select detected_by_node from autoscale.downNodes WHERE node_address='$downNode' AND node_down_since='$downSince'")
         echo "Node [$downNode] already terminated by node [$detectedBy]"
      fi
   done
fi

echo Done! [`date`]
exit 0
