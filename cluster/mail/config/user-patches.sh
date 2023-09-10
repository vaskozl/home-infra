#!/bin/bash

set -e

##
# This user script will be executed between configuration and starting daemons
# To enable it you must save it in your config directory as "user-patches.sh"
##
echo ">>>>>>>>>>>>>>>>>>>>>>>Applying patches<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"

echo 'Populating header checks'
echo '/To: v <v/ REJECT Please address the email to my real name!' >> /etc/postfix/maps/header_checks.pcre


echo 'Enabling replication'

# Add notify and replication to the mail plugins
sed -i '/^mail_plugins =/ s/$/ notify replication/' /etc/dovecot/conf.d/10-mail.conf

cat <<EOF > /etc/dovecot/conf.d/10-replication.conf
service doveadm {
   inet_listener {
   	port = 4177
   }
}
doveadm_port = 4177
doveadm_password = ${DOVECOT_ADM_PASS}
service replicator {
   process_min_avail = 1
   unix_listener replicator-doveadm {
   	user = dovecot
       group = dovecot
   	mode = 0666
   }
}
service aggregator {
   fifo_listener replication-notify-fifo {
   	user = dovecot
       group = dovecot
       mode = 0666
   }
   unix_listener replication-notify {
   	user = dovecot
       group = dovecot
       mode = 0666
   }
}
EOF

# Check if configured
if [ -n "${DOVECOT_REPLICA_SERVER}" ]; then
   # Open the config
   sed -i '/^}/d' /etc/dovecot/conf.d/90-plugin.conf
   # Remove a possible old value of mail_replica
   sed -i '/^mail_replica/d' /etc/dovecot/conf.d/90-plugin.conf
   # Insert the config and close it back
   printf '\nmail_replica = tcp:%s\n}\n' "${DOVECOT_REPLICA_SERVER}" >> /etc/dovecot/conf.d/90-plugin.conf
fi

echo ">>>>>>>>>>>>>>>>>>>>>>>Finished applying patches<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
