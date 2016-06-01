#!/bin/sh
#Script to put the private LAN into pseudo bridge mode

#source /etc/utopia/service.d/interface_functions.sh
source /etc/utopia/service.d/hostname_functions.sh
source /etc/utopia/service.d/ulog_functions.sh
#source /etc/utopia/service.d/service_lan/wlan.sh
source /etc/utopia/service.d/event_handler_functions.sh
#source /etc/utopia/service.d/brcm_ethernet_helper.sh

SERVICE_NAME="bridge"

#TODO: Should we get these from CCSP instead of hardcoding them?
LAN_IP="10.0.0.1"
LAN_NETMASK="255.255.255.0"

#Separate routing table used to ensure that responses from the web UI go directly to the LAN interface, not out erouter0 
BRIDGE_MODE_TABLE=69

#Mode passed in by commandline, can be "enable" or "disable"
SCRIPT_MODE="$1"

wait_till_steady_state ()
{
	LSERVICE=$1
	TRIES=1
	while [ "30" -ge "$TRIES" ] ; do
		LSTATUS=`sysevent get ${LSERVICE}-status`
		if [ "starting" = "$LSTATUS" ] || [ "stopping" = "$LSTATUS" ] || [ "partial" = "$LSTATUS" ] ; then
			sleep 1
			TRIES=`expr $TRIES + 1`
		else
			return
		fi
	done
	echo "$0: Timed out waiting for $LSERVICE to be in a steady state"
}

wait_till_started ()
{
	LSERVICE=$1
	TRIES=1
	while [ "30" -ge "$TRIES" ] ; do
		LSTATUS=`sysevent get ${LSERVICE}-status`
		if [ "started" = "$LSTATUS" -o "ready" = "$LSTATUS" ] ; then
			return
		else
			sleep 1
			TRIES=`expr $TRIES + 1`
		fi
	done
	echo "$0: Timed out waiting for $LSERVICE to be started or ready"
}


wait_till_stopped()
{
	LSERVICE=$1
	TRIES=1
	while [ "30" -ge "$TRIES" ] ; do
		LSTATUS=`sysevent get ${LSERVICE}-status`
		if [ "stopped" = "$LSTATUS" -o "" = "$LSTATUS" ] ; then
			return
		else
			sleep 1
			TRIES=`expr $TRIES + 1`
		fi
	done
	echo "$0: Timed out waiting for $LSERVICE to be stopped"
}

disable_packet_processor(){
	ncpu_exec -e "(echo disable > /proc/net/ti_pp)"
}

enable_packet_processor(){
	ncpu_exec -e "(echo enable > /proc/net/ti_pp)"
}

flush_connection_info(){
	#Flush packet processor sessions on NPCPU
	#ncpu_exec -e "(echo flush_all_sessions > /proc/net/ti_pp)"

	#Flush connection tracking entries on both arm and atom sides
	ncpu_exec -e "conntrack_flush"
	conntrack_flush

	#Flush CPE table
	ncpu_exec -e "(echo \"LearnFrom=CPE_DYNAMIC\" > /proc/net/dbrctl/delalt)"
}

#Add any iptables rules which are needed while in bridged mode
#Normally these rules would be added by the firewall, but in bridged
#mode the firewall is not started
iptables_rules(){
	WAN_IF=`sysevent get wan_ifname`

        if [ "$1" = "enable" ] ; then
		#Block DHCP requests on $BRIDGE_NAME
		iptables -I INPUT -i $CMDIAG_IF -p udp --dport 67 -j DROP
                iptables -t raw -A PREROUTING -i a-mux -j NOTRACK
                iptables -t nat -A POSTROUTING -o $WAN_IF -j MASQUERADE
        else
		iptables -D INPUT -i $CMDIAG_IF -p udp --dport 67 -j DROP
                iptables -t raw -D PREROUTING -i a-mux -j NOTRACK
                iptables -t nat -D POSTROUTING -o $WAN_IF -j MASQUERADE
        fi
}

#Add or remove rules to block local traffic from reaching DOCSIS bridge
filter_local_traffic(){
        if [ "$1" = "enable" ] ; then
                #Create a new chain to local traffic filtering
                ebtables -N BRIDGE_OUTPUT_FILTER
                ebtables -F BRIDGE_OUTPUT_FILTER 2> /dev/null
                ebtables -I OUTPUT -j BRIDGE_OUTPUT_FILTER

                #Don't allow a-mux or LAN bridge to send traffic to DOCSIS bridge
                ebtables -A BRIDGE_OUTPUT_FILTER --logical-out a-mux -j DROP
                ebtables -A BRIDGE_OUTPUT_FILTER --logical-out $BRIDGE_NAME -j DROP
                ebtables -A BRIDGE_OUTPUT_FILTER -o lbr0 -j DROP

                #Return from filter chain
                ebtables -A BRIDGE_OUTPUT_FILTER -j RETURN
        else
		#Delete the local traffic filter chain
                ebtables -D OUTPUT -j BRIDGE_OUTPUT_FILTER
                ebtables -X BRIDGE_OUTPUT_FILTER
        fi
}

#Temporarily block traffic through lbr0 while reconfiguring rules 
block_bridge(){
	ebtables -A FORWARD -i llbr0 -j DROP
}

#Unblock bridged traffic through lbr0
unblock_bridge(){
	ebtables -D FORWARD -i llbr0 -j DROP
}

assure_multinet_stopped(){
	PRI_L2=`sysevent get primary_lan_l2net`
	LAN_STATUS="`sysevent get multinet_${PRI_L2}-status`"
	if [ "$LAN_STATUS" = "" -o "$LAN_STATUS" = "stopped" ] ; then
		echo "Multinet instance $PRI_L2 stopped, proceeding"
	else
		sysevent set multinet-stop $PRI_L2
	fi
	wait_till_stopped multinet_${PRI_L2}
	vlan_util del_group $BRIDGE_NAME 2> /dev/null
}

lan_bridge()
{
        if [ "$1" = "enable" ] ; then
                assure_multinet_stopped
                vlan_util add_group $BRIDGE_NAME 100
                vlan_util add_interface $BRIDGE_NAME eth_0
                isport2enable=`dmcli eRT getv Device.Bridging.Bridge.1.Port.8.Enable | grep value | cut -f3 -d : | cut -f2 -d" "`
                if [ "$isport2enable" = "true" ]; then
                        #Add the port2 to the private network
                        vlan_util add_interface $BRIDGE_NAME eth_1
                fi
                vlan_util add_interface $BRIDGE_NAME nmoca0
        else
                vlan_util del_group $BRIDGE_NAME
        fi
}

cmdiag_ebtables_rules()
{
	if [ "$1" = "enable" ] ; then
		CMDIAG_MAC="`cat /sys/class/net/lan0/address`"
		MUX_MAC="`cat /sys/class/net/adp0/address`"

		#Don't allow lan0 or MUX to send traffic to DOCSIS bridge
		ebtables -N BRIDGE_FORWARD_FILTER
		ebtables -F BRIDGE_FORWARD_FILTER 2> /dev/null
		ebtables -I FORWARD -j BRIDGE_FORWARD_FILTER
		ebtables -A BRIDGE_FORWARD_FILTER -s $CMDIAG_MAC -o lbr0 -j DROP
		ebtables -A BRIDGE_FORWARD_FILTER -s $MUX_MAC -o lbr0 -j DROP
		ebtables -A BRIDGE_FORWARD_FILTER -s $CMDIAG_MAC -o llbr0 -j DROP
		ebtables -A BRIDGE_FORWARD_FILTER -s $MUX_MAC -o llbr0 -j DROP
		ebtables -A BRIDGE_FORWARD_FILTER -j RETURN

		#Redirect traffic destined to lan0 IP to lan0 MAC address
		ebtables -t nat -N BRIDGE_REDIRECT
		ebtables -t nat -F BRIDGE_REDIRECT 2> /dev/null
		ebtables -t nat -I PREROUTING -j BRIDGE_REDIRECT
		ebtables -t nat -A BRIDGE_REDIRECT --logical-in $BRIDGE_NAME -p ipv4 --ip-dst $LAN_IP -j dnat --to-destination $CMDIAG_MAC
		ebtables -t nat -A BRIDGE_REDIRECT --logical-in $BRIDGE_NAME -p ipv4 --ip-dst $LAN_IP -j forward --forward-dev llan0
		ebtables -t nat -A BRIDGE_REDIRECT -j RETURN
	else
		ebtables -D FORWARD -j BRIDGE_FORWARD_FILTER
		ebtables -X BRIDGE_FORWARD_FILTER
		ebtables -t nat -D PREROUTING -j BRIDGE_REDIRECT
		ebtables -t nat -X BRIDGE_REDIRECT
	fi
}

#Create a virtual lan0 management interface and connect it to the bride
#Also prevent this interface from sending any packets to the DOCSIS bridge
cmdiag_if()
{
	if [ "$1" = "enable" ] ; then
		ip link add $CMDIAG_IF type veth peer name l${CMDIAG_IF} 
		echo 1 > /proc/sys/net/ipv6/conf/llan0/disable_ipv6
		echo 1 > /proc/sys/net/ipv6/conf/adp0/disable_ipv6
		echo 1 > /proc/sys/net/ipv6/conf/a-mux/disable_ipv6
		ifconfig $CMDIAG_IF hw ether $CMDIAG_MAC
		cmdiag_ebtables_rules enable
		ifconfig l${CMDIAG_IF} promisc up
		ifconfig $CMDIAG_IF $LAN_IP netmask $LAN_NETMASK up
		vlan_util add_interface $BRIDGE_NAME l${CMDIAG_IF}
	else
		vlan_util del_interface $BRIDGE_NAME l${CMDIAG_IF}
		ifconfig $CMDIAG_IF down
		ifconfig l${CMDIAG_IF} down
		ip link del $CMDIAG_IF
		cmdiag_ebtables_rules disable
	fi
}

routing_rules(){
        if [ "$1" = "enable" ] ; then
		#Send responses from $BRIDGE_NAME IP to a separate bridge mode route table
		ip rule add from $LAN_IP lookup $BRIDGE_MODE_TABLE
		ip route add table $BRIDGE_MODE_TABLE default dev $CMDIAG_IF
        else
		ip rule del from $LAN_IP lookup $BRIDGE_MODE_TABLE
		ip route flush table $BRIDGE_MODE_TABLE
        fi
}

#Enable pseudo bridge mode.  If already enabled, just refresh parameters (in case bridges were torn down and rebuilt)
service_start(){
	wait_till_steady_state ${SERVICE_NAME}
	STATUS=`sysevent get ${SERVICE_NAME}-status`
	if [ "started" != "$STATUS" ] ; then
                lan_bridge enable

		sysevent set ${SERVICE_NAME}-errinfo
		sysevent set ${SERVICE_NAME}-status starting

		block_bridge

		#Connect management interface
		cmdiag_if enable

		routing_rules enable

		#Insert necessary iptables rules
		iptables_rules enable

		#Add lbr0 to $BRIDGE_NAME
		vlan_util add_interface $BRIDGE_NAME lbr0

		#Block traffic coming from the lbr0 connector interfaces at the MUX
		filter_local_traffic enable

		unblock_bridge

		prepare_hostname

		#Disabled until implemented correctly on xb6
		#gw_lan_refresh

		#Flush connection tracking and packet processor sessions to avoid stale information
		flush_connection_info

		sysevent set ${SERVICE_NAME}-errinfo
		sysevent set ${SERVICE_NAME}-status started
		
	fi
}

service_stop(){
	wait_till_steady_state ${SERVICE_NAME}
	STATUS=`sysevent get ${SERVICE_NAME}-status`
	if [ "stopped" != "$STATUS" ] ; then

		sysevent set ${SERVICE_NAME}-errinfo
		sysevent set ${SERVICE_NAME}-status stopping

		block_bridge

		#Remove local bridge connection from lan bridge
		vlan_util del_interface $BRIDGE_NAME lbr0

		#Remove iptables rules no longer needed
		iptables_rules disable

		#Disconnect management interface
		cmdiag_if disable
		filter_local_traffic disable

		lan_bridge disable

		unblock_bridge

		#Flush connection tracking and packet processor sessions to avoid stale information
		flush_connection_info

		#Disabled until implemented correctly on xb6
		#gw_lan_refresh

		sysevent set ${SERVICE_NAME}-errinfo
		sysevent set ${SERVICE_NAME}-status stopped

	fi
}

#--------------------------------------------------------------
# service_init
#--------------------------------------------------------------
service_init ()
{
   # Get all provisioning data
   # Figure out the names and addresses of the lan interface
   #
   # SYSCFG_lan_ethernet_physical_ifnames is the physical ethernet interfaces that
   # will be part of the lan
   #
   # SYSCFG_lan_wl_physical_ifnames is the names of each wireless interface as known
   # to the operating system

   SYSCFG_FAILED='false'
   FOO=`utctx_cmd get bridge_mode lan_ifname lan_ethernet_physical_ifnames lan_wl_physical_ifnames wan_physical_ifname bridge_ipaddr bridge_netmask bridge_default_gateway bridge_nameserver1 bridge_nameserver2 bridge_nameserver3 bridge_domain hostname`
   eval $FOO
  if [ $SYSCFG_FAILED = 'true' ] ; then
     ulog bridge status "$PID utctx failed to get some configuration data"
     ulog bridge status "$PID BRIDGE CANNOT BE CONTROLLED"
     exit
  fi

  if [ -z "$SYSCFG_hostname" ] ; then
     SYSCFG_hostname="Utopia"
  fi

  LAN_IFNAMES="$SYSCFG_lan_ethernet_physical_ifnames"

   # if we are using wireless interfafes then add them
   if [ "" != "$SYSCFG_lan_wl_physical_ifnames" ] ; then
      LAN_IFNAMES="$LAN_IFNAMES $SYSCFG_lan_wl_physical_ifnames"
   fi
}


echo "service_bridge_puma7.sh called with $1 $2" > /dev/console
service_init

BRIDGE_NAME="$SYSCFG_lan_ifname"
CMDIAG_IF=`syscfg get cmdiag_ifname`
CMDIAG_MAC=`ncpu_exec -ep "(cat /sys/class/net/lan0/address)"`

case "$1" in
   ${SERVICE_NAME}-start)
      disable_packet_processor
      service_start
      enable_packet_processor
      ;;
   ${SERVICE_NAME}-stop)
      disable_packet_processor
      service_stop
      enable_packet_processor
      ;;
   ${SERVICE_NAME}-restart)
      PRI_L2=`sysevent get primary_lan_l2net`
      disable_packet_processor
      sysevent set lan-restarting $PRI_L2
      service_stop
      service_start
      sysevent set lan-restarting 0
      enable_packet_processor
      ;;
   *)
      echo "Usage: service-${SERVICE_NAME} [ ${SERVICE_NAME}-start | ${SERVICE_NAME}-stop | ${SERVICE_NAME}-restart]" > /dev/console
      exit 3
      ;;
esac