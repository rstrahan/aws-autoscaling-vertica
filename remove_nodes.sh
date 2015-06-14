#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Removes nodes from currently active DB and cluster.
# Run as external procedure from vertica server.
. /home/dbadmin/.bashrc
autoscaleDir=/home/dbadmin/autoscale
. $autoscaleDir/autoscaling_vars.sh

# in non terminal mode, redirect stdout and stderr to logfile
if [ ! -t 0 ]; then exec >> $autoscaleDir/remove_nodes.log 2>&1; fi
echo -e "\n\nremove_nodes: [`date`]\n=======================================\n"

# prevent concurrent executions
IAM=(`pgrep -d " " -f ${0//*\//}`)
[ ${#IAM[@]} -gt 1 ] && { echo remove_nodes.sh already running - exiting 1>&2; exit 1; }

# close file descriptors inherited from Vertica when run as an external procedure
for fd in $(ls /proc/$$/fd); do
  case "$fd" in
    0|1|2|255)
      ;;
    *)
      eval "exec $fd>&-"
      ;;
  esac
done

# Get this node's IP
myIp=$(hostname -I | awk '{print $NF}'); echo My IP: $myIp

echo retrieve details for instances queued for termination, and update their status [`date`]
nodes=$(vsql -qAt -c "select node_address from autoscale.terminations where is_running" | paste -d, -s); 
instances=$(vsql -qAt -c "select ec2_instanceid from autoscale.terminations where is_running" | paste -d, -s); 
tokens=$(vsql -qAt -c "select lifecycle_action_token from autoscale.terminations where is_running");
vsql -c "UPDATE autoscale.terminations SET removed_by_node = '$myIp', status = 'REMOVING' where is_running; COMMIT" ;

# If there are any DOWN nodes, no point continuing since database cannot be modified.
downNodes=$(vsql -qAt -c "SELECT node_address FROM nodes WHERE node_state='DOWN'" | paste -s -d" ")
if [ ! -z "$downNodes" ]; then
   status="DOWN NODES [$downNodes] will be replaced rather than removed"
   echo "$status. Will not remove [$nodes]"
   end_time=$(date +"%Y-%m-%d %H:%M:%S")
   cat > /tmp/update_terminations.sql <<EOF
UPDATE autoscale.terminations SET end_time='$end_time', status = '$status' where is_running;
UPDATE autoscale.terminations SET duration_s = datediff(SECOND,start_time,end_time) where is_running;
UPDATE autoscale.terminations SET is_running=0 where is_running;
COMMIT
EOF
   vsql -f /tmp/update_terminations.sql ;
   echo "Done! [`date`]"
   exit 0
fi

# No DOWN nodes - continue..

# Remove Node from Database
# This step does a rebalance - could take a while, so we'll run it as a background job
# monitor progress, and extend termination lifecycle heartbeat timer periodically to ensure
# instance doesn't terminate before rebalancing is done.
DB=$(admintools -t show_active_db)
echo remove nodes [$nodes] from active DB [$DB] [`date`]
admintools -t db_remove_node -s $nodes -i -d $DB &
# wait for db_remove_node to complete
c=1
while [ 1 ]; do
   sleep 60
   jobs | grep Running > /dev/null
   [ $? -ne 0 ] && break
   ((c=c+1))
   # every 5 minutes, send a lifecycle heartbeat to AWS for all terminating instances
   if [ $((c%5)) -eq 0 ]; then
      echo "db_remove_node still running [`date`]"
      echo "Sending record-lifecycle-action-heartbeat for each terminating instance"
      for token in $tokens
      do
         aws autoscaling record-lifecycle-action-heartbeat --lifecycle-action-token $token --lifecycle-hook-name ${autoscaling_group_name}_ScaleDown --auto-scaling-group-name ${autoscaling_group_name} 
      done
   fi
done
echo Done removing nodes [$nodes] from active DB [$DB] [`date`]


echo remove nodes [$nodes] from cluster [`date`]
sudo /opt/vertica/sbin/install_vertica --remove-hosts $nodes --point-to-point --dba-user-password-disabled --ssh-identity $autoscaleDir/key.pem 

echo Instruct AWS to proceed with instance termination by completing lifecycle actions [`date`]
for token in $tokens
do
   aws autoscaling complete-lifecycle-action --lifecycle-action-token $token --lifecycle-hook-name ${autoscaling_group_name}_ScaleDown --auto-scaling-group-name ${autoscaling_group_name} --lifecycle-action-result CONTINUE
done

echo Check if nodes are successfully removed and update status in 'terminations' [`date`]
end_time=$(date +"%Y-%m-%d %H:%M:%S")
for n in `echo $nodes | sed -e 's/,/ /g'`
do
is_inDB=$(vsql -qAt -c "select count(*) from nodes where node_address='$n'")
[ $is_inDB -eq 0 ] && complete="SUCCESS" || complete="FAIL - NODE NOT REMOVED"
cat > /tmp/update_terminations.sql <<EOF
UPDATE autoscale.terminations SET end_time='$end_time', status = '$complete' where node_address='$n' and is_running;
UPDATE autoscale.terminations SET duration_s = datediff(SECOND,start_time,end_time) where node_address='$n' and is_running;
UPDATE autoscale.terminations SET is_running=0 where node_address='$n' and is_running;
COMMIT
EOF
vsql -f /tmp/update_terminations.sql ;
done

echo Done! [`date`]
exit 0

