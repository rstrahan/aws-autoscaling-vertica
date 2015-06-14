#!/bin/sh
# Copyright (c) 2011-2015 by Vertica, an HP Company.  All rights reserved.
# Validate config settings
# TODO - validate AWS settings - keypair, subnet, etc.

. ./autoscaling_vars.sh

# PEM file
if [ ! -f "$pem_file" ]; then
   echo "SSH key .pem file [$pem_file] does not exist. Aborting.";
   exit 1
fi

# VERTICA LICENSE
if [ "$license_file" != "CE" ]; then
   if [ ! -f "$license_file" ]; then
      echo "Vertica license file [$license_file] does not exist. Aborting."
      exit 1
   fi
else
   echo "Using Vertica Community Edition (CE) license."
   if [ $min -gt 3 -o $max -gt 3 -o $desired -gt 3 ]; then
      echo "Community Edition license is limited to 3 nodes or less."
      echo "You autoscaling settings (min[$min], max[$max], desired[$desired]) must all be set to no more than 3."
      echo "Aborting"
      exit 1
   fi
fi

# K-SAFETY
[ $k_safety -eq 0 ] && echo "Database K-Safety is set to 0. No data redundancy!"
if [ $k_safety -ne 0 -a $k_safety -ne 1 -a $k_safety -ne 2 ]; then
   echo "Invalid value for k_safety [$k_safety]. Database K-Safety must be 0, 1, or 2 (1 recommended). Aborting"
   exit 1
fi

# DOWN Node Replacement
[ $replace_down_node_after -eq 0 ] \
   && echo "DOWN Nodes will not be automatically replaced" \
   || echo "DOWN Nodes will be automatically terminated and replaced after $replace_down_node_after minutes"
                                                              
if [ $min -gt $max -o $desired -lt $min -o $desired -gt $max ]; then
   echo "Cluster size error: min <= desired <= max [min $min, desired $desired, max $max]"
   exit 1
else
   echo "Cluster size: [min $min, desired $desired, max $max]"
fi

echo "Configuration OK"
