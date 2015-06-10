#! /bin/sh

# make launch.sh from template and config

. ./autoscaling_vars.sh

cat launch.sh.template | \
   sed -e "s/YOUR_ACCESS_KEY_ID/$aws_access_key_id/g; \
     s/YOUR_SECRET_ACCESS_KEY/$aws_secret_access_key/g; \
     s/YOUR_REGION/$region/g; \
     s/YOUR_AUTOSCALING_GROUP_NAME/$autoscaling_group_name/g"\
     > launch.sh

echo Created launch.sh
