#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Run as part of bootstrapping first instance.. creates and configures 1-node auto scale compatible database


. ./autoscaling_vars.sh

# get instance configuration
resId=$(curl -s http://169.254.169.254/latest/meta-data/reservation-id); echo Reservation: $resId
instId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id); echo InstanceId: $instId
privateIp=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4); echo PrivateIP: $privateIp
publicIp=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4); echo PublicIP: $publicIp
macs=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/) 
subnetCIDR=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/$macs/subnet-ipv4-cidr-block/); echo Subnet CIDR: $subnetCIDR

# create database
admintools -t create_db -s $privateIp -d $database_name -p $password

# configure trust for local host and local subnet – avoids need to transmit / store password on local subnet
vsql -w $password -c "CREATE AUTHENTICATION trustLocal METHOD 'trust' LOCAL; GRANT AUTHENTICATION trustLocal TO dbadmin;"
vsql  -c "CREATE AUTHENTICATION trustSubnet METHOD 'trust' HOST '$subnetCIDR'; GRANT AUTHENTICATION trustSubnet TO dbadmin;"
# configure default password authentication from everywhere else
vsql  -c "CREATE AUTHENTICATION passwd METHOD 'hash' HOST '0.0.0.0/0'; GRANT AUTHENTICATION passwd TO dbadmin;"

# install external stored procedures used to expand and contract cluster
chmod ug+sx /home/dbadmin/autoscale/*.sh
admintools -t install_procedure -d $database_name -f /home/dbadmin/autoscale/add_nodes.sh
admintools -t install_procedure -d $database_name -f /home/dbadmin/autoscale/remove_nodes.sh
vsql -c "CREATE SCHEMA autoscale"
vsql -c "CREATE PROCEDURE autoscale.add_nodes() AS 'add_nodes.sh' LANGUAGE 'external' USER 'dbadmin'"
vsql -c "CREATE PROCEDURE autoscale.remove_nodes() AS 'remove_nodes.sh' LANGUAGE 'external' USER 'dbadmin'"

# enable Vertica’s elastic cluster with local segmentation for faster rebalancing. See documentation for details on tuning elastic cluster parameters, such as scaling factor, maximum skew, etc.
vsql -c " SELECT ENABLE_ELASTIC_CLUSTER();"
vsql -c " SELECT ENABLE_LOCAL_SEGMENTS();"

# Create logging tables - 
vsql -c "CREATE TABLE autoscale.launches (added_by_node varchar(15), start_time timestamp, end_time timestamp, duration_s int, reservationid varchar(20), ec2_instanceid varchar(20), node_address varchar(15), replace_node_address varchar(15), node_public_address varchar(15), status varchar(40), is_running boolean, comment varchar(128)) ORDER BY start_time UNSEGMENTED ALL NODES";
vsql -c "CREATE TABLE autoscale.terminations (queued_by_node varchar(15), removed_by_node varchar(15), start_time timestamp, end_time timestamp, duration_s int, ec2_instanceid varchar(20), node_address varchar(15), node_public_address varchar(15), lifecycle_action_token varchar(128), status varchar(128), is_running boolean) ORDER BY start_time UNSEGMENTED ALL NODES";
vsql -c "CREATE TABLE autoscale.downNodes (detected_by_node varchar(15), trigger_termination_time timestamp, node_down_since timestamp, ec2_instanceid varchar(20), node_address varchar(15), status varchar(128)) UNSEGMENTED ALL NODES";


# Add first log entry for bootstrap node
time=$( date +"%Y-%m-%d %H:%M:%S")
echo "$privateIp|$time|$time|0|$resId|$instId|$privateIp||$publicIp|SUCCESS|0|Initial Bootstrap node" | vsql -c "COPY autoscale.launches FROM STDIN" 


