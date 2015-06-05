#!/bin/sh
# Adds nodes to cluster and currently active DB.  Expects AWS reservation ID as argument
# Run as external procedure from vertica server.

. /home/dbadmin/.bashrc
autoscaleDir=/home/dbadmin/autoscale
. $autoscaleDir/autoscaling_vars.sh

resId=$1

# in non terminal mode, redirect stdout and stderr to logfile
if [ ! -t 0 ]; then exec >> $autoscaleDir/add_nodes.log 2>&1; fi
echo -e "\n\nadd_nodes $resId: [`date`]\n================================================\n"

# Get this node's IP
myIp=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4); echo PrivateIP: $privateIp

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

# if there are active terminations in progress, wait for them to finish, so 
# we are not removing and adding nodes at the same time
terminations_count=$(vsql -qAt -c "select count(*) from autoscale.terminations where not is_terminated")
while [ $terminations_count -gt 0 ]; do
   echo "Nodes are currently being terminated."
   echo "We will wait for the terminations to complete before adding new nodes"
   echo "Check again in 1 minute"
   sleep 60
   terminations_count=$(vsql -qAt -c "select count(*) from autoscale.terminations where not is_terminated")
done

echo retrieve private IPs for specified reservationId: $resId [`date`]
nodes=$(aws --output=text ec2 describe-instances --filters "Name=reservation-id,Values=$resId" --query "Reservations[*].Instances[*].PrivateIpAddress" | sed -e 's/\s/,/g')

echo add new nodes [$nodes] to cluster [`date`]
start_time=$(date +"%Y-%m-%d %H:%M:%S")
vsql -c "UPDATE autoscale.launches SET added_by_node='$myIp', start_time='$start_time', status='ADD TO CLUSTER' WHERE reservationid='$resId'; COMMIT" ;
sudo /opt/vertica/sbin/install_vertica --add-hosts $nodes --point-to-point -L $autoscaleDir/license.dat --dba-user-password-disabled --data-dir /vertica/data --ssh-identity $autoscaleDir/key.pem --failure-threshold HALT
DB=$(admintools -t show_active_db)

echo add nodes [$nodes] to active DB [$DB] [`date`]
vsql -c "UPDATE autoscale.launches SET added_by_node='$myIp', start_time='$start_time', status='ADD TO DATABASE' WHERE reservationid='$resId'; COMMIT" ;
admintools -t db_add_node -s $nodes -i -d $DB
echo rebalance cluster [`date`]
admintools -t rebalance_data -d $DB -k $k_safety

echo install autoscale scripts and crontab schedule on each new node [$nodes] [`date`]
for n in `echo $nodes | sed -e 's/,/ /g'`
do
   ssh $n mkdir -p /home/dbadmin/autoscale
   scp -r $autoscaleDir/*.sh $autoscaleDir/key.pem $autoscaleDir/license.dat $n:/home/dbadmin/autoscale
   ssh $n chmod ug+sx $autoscaleDir/*.sh
   ssh $n '(echo "* * * * * /home/dbadmin/autoscale/read_scaledown_queue.sh" | crontab -)'
done

echo configure external stored procedures on new nodes [`date`]
admintools -t install_procedure -d VMart -f $autoscaleDir/add_nodes.sh
admintools -t install_procedure -d VMart -f $autoscaleDir/remove_nodes.sh

echo Updating launches table - COMPLETE
end_time=$(date +"%Y-%m-%d %H:%M:%S")
cat > /tmp/update_launches.sql <<EOF
UPDATE autoscale.launches SET added_by_node='$myIp', start_time='$start_time', end_time='$end_time', status = 'COMPLETE' where reservationid='$resId';
UPDATE autoscale.launches SET duration_s = datediff(SECOND,start_time,end_time) where reservationid='$resId';
UPDATE autoscale.launches SET is_launched=1 where reservationid='$resId';
COMMIT
EOF
vsql -f /tmp/update_launches.sql ;

echo Done! [`date`]
exit 0

