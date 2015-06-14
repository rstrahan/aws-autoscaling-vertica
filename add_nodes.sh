#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Adds nodes to cluster and currently active DB.
# Run as external procedure from vertica server.

. /home/dbadmin/.bashrc
autoscaleDir=/home/dbadmin/autoscale
. $autoscaleDir/autoscaling_vars.sh

# in non terminal mode, redirect stdout and stderr to logfile
if [ ! -t 0 ]; then exec >> $autoscaleDir/add_nodes.log 2>&1; fi
echo -e "\n\nadd_nodes: [`date`]\n================================================\n"

# prevent concurrent executions
IAM=(`pgrep -d " " -f ${0//*\//}`)
[ ${#IAM[@]} -gt 1 ] && { echo add_nodes.sh already running - exiting 1>&2; exit 1; }

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

# update launches table
start_time=$(date +"%Y-%m-%d %H:%M:%S")
vsql -c "UPDATE autoscale.launches SET added_by_node = '$myIp', start_time='$start_time' where is_running; COMMIT" ; > /dev/null


# if there are active terminations in progress, wait for them to finish, so 
# we are not removing and adding nodes at the same time
terminations_count=$(vsql -qAt -c "SELECT count(*) FROM autoscale.terminations WHERE is_running")
while [ $terminations_count -gt 0 ]; do
   echo "Nodes are currently being terminated."
   echo "We will wait for the terminations to complete before adding new nodes"
   echo "Check again in 1 minute"
   vsql -c "UPDATE autoscale.launches SET status='WAIT FOR RUNNING TERMINATIONS' WHERE is_running; COMMIT" > /dev/null
   sleep 60
   terminations_count=$(vsql -qAt -c "SELECT count(*) FROM autoscale.terminations WHERE is_running")
done

echo Retrieve details for instances queued for addition [`date`]
new_nodes=$(vsql -qAt -c "SELECT node_address FROM autoscale.launches WHERE is_running AND replace_node_address IS NULL" | paste -d, -s);
replace_nodes=$(vsql -qAt -c "SELECT replace_node_address FROM autoscale.launches WHERE is_running AND replace_node_address IS NOT NULL" | paste -d, -s);
down_nodes=$(vsql -qAt -c "SELECT node_address FROM nodes WHERE node_state='DOWN'" | paste -d, -s);

echo "Check that we have enough 'replace_nodes' for all the 'down_nodes'."
# If not, exit now, and we'll pick up pending entries next time when new instances launch
replace_nodes_count=$(echo $replace_nodes | awk -F, '{print NF}')
down_nodes_count=$(echo $down_nodes | awk -F, '{print NF}')
if [ $down_nodes_count -gt $replace_nodes_count ]; then
   status="Insufficient replacement nodes [$replace_nodes_count] to replace down nodes [down_nodes_count]. Wait for new launch(es)."
   echo $status
   vsql -c "UPDATE autoscale.launches SET status='$status' WHERE is_running; COMMIT" > /dev/null
   exit 1;
fi

# remove .ssh/known_hosts to avoid host key changed error when IP addresses are reused
for existingNode in `vsql -qAt -c "select node_address from nodes"`
do
   echo "Remove .ssh/known_hosts on node [$existingNode]"
   ssh -o "StrictHostKeyChecking no" $existingNode '(
      # for root user
      sudo rm -f /root/.ssh/known_hosts 
      # for dbadmin user
      rm -f /home/dbadmin/.ssh/known_hosts 
   )'
done

# process new nodes
if [ ! -z "$new_nodes" ]; then
   echo add new nodes [$new_nodes] to cluster [`date`]
   vsql -c "UPDATE autoscale.launches SET status='ADD TO CLUSTER' WHERE is_running AND replace_node_address IS NULL; COMMIT" > /dev/null
   sudo /opt/vertica/sbin/install_vertica --add-hosts $new_nodes --point-to-point -L $autoscaleDir/license.dat --dba-user-password-disabled --data-dir /vertica/data --ssh-identity $autoscaleDir/key.pem --failure-threshold HALT
   DB=$(admintools -t show_active_db)
   echo add nodes [$new_nodes] to active DB [$DB] [`date`]
   vsql -c "UPDATE autoscale.launches SET status='ADD TO DATABASE' WHERE is_running AND replace_node_address IS NULL; COMMIT" > /dev/null
   admintools -t db_add_node -s $new_nodes -i -d $DB
   echo rebalance cluster [`date`]
   admintools -t rebalance_data -d $DB -k $k_safety
fi

# process replacement nodes
if [ ! -z "$replace_nodes" ]; then
   echo Sync replacement nodes [$replace_nodes] to cluster [`date`]
   vsql -c "UPDATE autoscale.launches SET status='SYNC REPLACEMENT NODES IN CLUSTER' WHERE is_running AND replace_node_address IS NOT NULL; COMMIT" > /dev/null
   # run install_vertica with no --add-hosts argument - this will setup keys etc. on replacement nodes
   sudo /opt/vertica/sbin/install_vertica --point-to-point -L $autoscaleDir/license.dat --dba-user-password-disabled --data-dir /vertica/data --ssh-identity $autoscaleDir/key.pem --failure-threshold HALT
   DB=$(admintools -t show_active_db)
   for repNode in `echo $replace_nodes | sed -e 's/,/ /g'`
   do
      vsql -c "UPDATE autoscale.launches SET status='START VERTICA ON REPLACEMENT NODE' WHERE replace_node_address='$repNode' and is_running; COMMIT" > /dev/null
      echo Create empty catalog directory on [$repNode] to active DB [$DB] [`date`]
      node_name=$(vsql -qAt -c "SELECT node_name from nodes where node_address='$repNode'" )
      catalog_dir="/vertica/data/$DB/${node_name}_catalog"
      ssh -o "StrictHostKeyChecking no" $repNode mkdir -p $catalog_dir
      echo Starting Vertica on [$repNode] [`date`]
      admintools -t restart_node -s $repNode -d $DB
   done
fi


echo install autoscale scripts and crontab schedule on each new node [$new_nodes,$replace_nodes] [`date`]
for n in `echo $new_nodes,$replace_nodes | sed -e 's/,/ /g'`
do
   ssh $n -o "StrictHostKeyChecking no" mkdir -p /home/dbadmin/autoscale
   scp -r $autoscaleDir/*.sh $autoscaleDir/key.pem $autoscaleDir/license.dat $n:/home/dbadmin/autoscale
   ssh $n chmod ug+sx $autoscaleDir/*.sh
   ssh $n '(echo -e "* * * * * /home/dbadmin/autoscale/read_scaledown_queue.sh\n* * * * * /home/dbadmin/autoscale/down_node_check.sh"  | crontab -)'
done

echo configure external stored procedures on new nodes [`date`]
admintools -t install_procedure -d VMart -f $autoscaleDir/add_nodes.sh
admintools -t install_procedure -d VMart -f $autoscaleDir/remove_nodes.sh

echo check if nodes are successfully added and update status in 'launches' [`date`]
end_time=$(date +"%Y-%m-%d %H:%M:%S")
for n in `echo $new_nodes,$replace_nodes | sed -e 's/,/ /g'`
do
is_inDB=$(vsql -qAt -c "select count(*) from nodes where node_address='$n'")
[ $is_inDB -eq 0 ] && complete="FAIL - NOT IN DB" || complete="SUCCESS"
cat > /tmp/update_launches.sql <<EOF
UPDATE autoscale.launches SET end_time='$end_time', status = '$complete' where node_address='$n' or replace_node_address='$n' and is_running ;
UPDATE autoscale.launches SET duration_s = datediff(SECOND,start_time,end_time) where node_address='$n' or replace_node_address='$n' and is_running ;
UPDATE autoscale.launches SET is_running=0 where node_address='$n' or replace_node_address='$n' and is_running ;
COMMIT
EOF
vsql -f /tmp/update_launches.sql > /dev/null ;
done

echo Done! [`date`]
exit 0

