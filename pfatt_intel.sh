#!/usr/bin/env sh

EAP_SUPPLICANT_IDENTITY="XX:XX:XX:XX:XX:XX"
LOG=/var/log/pfatt.log
ONT_IF="igb1"

getTimestamp(){
    echo `date "+%Y-%m-%d %H:%M:%S :: [pfatt_intel.sh] ::"`
}

##### DO NOT EDIT BELOW #################################################################################
/usr/bin/logger -st "pfatt" "starting pfatt..."
/usr/bin/logger -st "pfatt" "configuration:"
/usr/bin/logger -st "pfatt" "  ONT_IF = $ONT_IF"
/usr/bin/logger -st "pfatt" "  EAP_SUPPLICANT_IDENTITY = $EAP_SUPPLICANT_IDENTITY"

# Netgraph cleanup.
/usr/bin/logger -st "pfatt" "resetting netgraph..."
/usr/sbin/ngctl shutdown $ONT_IF: >/dev/null 2>&1
/usr/sbin/ngctl shutdown vlan0: >/dev/null 2>&1
/usr/sbin/ngctl shutdown ngeth0: >/dev/null 2>&1

/usr/bin/logger -st "pfatt" "your ONT should be connected to pyshical interface $ONT_IF"
/usr/bin/logger -st "pfatt" "creating vlan node and ngeth0 interface..."
/usr/sbin/ngctl mkpeer $ONT_IF: vlan lower downstream
/usr/sbin/ngctl name $ONT_IF:lower vlan0
/usr/sbin/ngctl mkpeer vlan0: eiface vlan0 ether
/usr/sbin/ngctl msg vlan0: 'addfilter { vlan=0 hook="vlan0" }'
/usr/sbin/ngctl msg ngeth0: set $EAP_SUPPLICANT_IDENTITY

/usr/bin/logger -st "pfatt" "enabling promisc for $ONT_IF..."
/sbin/ifconfig $ONT_IF ether $EAP_SUPPLICANT_IDENTITY
/sbin/ifconfig $ONT_IF up
/sbin/ifconfig $ONT_IF promisc

/usr/bin/logger -st "pfatt" "starting wpa_supplicant..."

WPA_PARAMS="\
  set eapol_version 2,\
  set fast_reauth 1,\
  ap_scan 0,\
  add_network,\
  set_network 0 ca_cert \\\"/root/pfatt/wpa/ca.pem\\\",\
  set_network 0 client_cert \\\"/root/pfatt/wpa/client.pem\\\",\
  set_network 0 eap TLS,\
  set_network 0 eapol_flags 0,\
  set_network 0 identity \\\"$EAP_SUPPLICANT_IDENTITY\\\",\
  set_network 0 key_mgmt IEEE8021X,\
  set_network 0 phase1 \\\"allow_canned_success=1\\\",\
  set_network 0 private_key \\\"/root/pfatt/wpa/private.pem\\\",\
  enable_network 0\
"
WPA_DAEMON_CMD="/usr/sbin/wpa_supplicant -Dwired -i$ONT_IF -B -C /var/run/wpa_supplicant"

# Kill any existing wpa_supplicant process.
PID=$(pgrep -f "wpa_supplicant")
if [ ${PID} > 0 ];
then
	/usr/bin/logger -st "pfatt" "terminating existing wpa_supplicant on PID ${PID}..."
	RES=$(kill ${PID})
fi

# Start wpa_supplicant daemon.
RES=$(${WPA_DAEMON_CMD})
PID=$(pgrep -f "wpa_supplicant")
/usr/bin/logger -st "pfatt" "wpa_supplicant running on PID ${PID}..."

# Set WPA configuration parameters.
/usr/bin/logger -st "pfatt" "setting wpa_supplicant network configuration..."
IFS=","
for STR in ${WPA_PARAMS};
do
	STR="$(echo -e "${STR}" | sed -e 's/^[[:space:]]*//')"
	RES=$(eval wpa_cli ${STR})
done

# Create variables to check authentication status.
WPA_STATUS_CMD="wpa_cli status | grep 'suppPortStatus' | cut -d= -f2"
IP_STATUS_CMD="ifconfig ngeth0 | grep 'inet\ ' | cut -d' ' -f2"
/usr/bin/logger -st "pfatt" "waiting for EAP authorization..."

# Check authentication once per 5 seconds for 25 seconds (5 attempts). Continue without authentication if necessary (no WAN).
i=1
until [ "$i" -eq "5" ]
do
	sleep 5
	WPA_STATUS=$(eval ${WPA_STATUS_CMD})
	if [ X${WPA_STATUS} = X"Authorized" ];
	then
		/usr/bin/logger -st "pfatt" "EAP authorization completed..."

		IP_STATUS=$(eval ${IP_STATUS_CMD})

		if [ -z ${IP_STATUS} ] || [ ${IP_STATUS} = "0.0.0.0" ];
		then
			/usr/bin/logger -st "pfatt" "no IP address assigned, force restarting DHCP..."
			RES=$(eval /etc/rc.d/dhclient forcerestart ngeth0)
			IP_STATUS=$(eval ${IP_STATUS_CMD})
		fi
		/usr/bin/logger -st "pfatt" "IP address is ${IP_STATUS}..."
		/usr/bin/logger -st "pfatt" "ngeth0 should now be available to configure as your WAN..."
		sleep 5
		/usr/bin/logger -st "pfatt" "set mac address on ngeth0..."
		/sbin/ifconfig ngeth0 ether $EAP_SUPPLICANT_IDENTITY
		break
	else
		/usr/bin/logger -st "pfatt" "no authentication, retrying ${i}/5..."
		i=$((i+1))
	fi
done
