#! /bin/sh
##
## service-tunnel.sh --
##   Functions for a K8s service tunnel. Service tunnel is a tunnel,
##   setup from an outside machine to a POD via a K8s UDP service.
##
##   Env:
##     TUNNEL_TYPE   - Only "vxlan" supported
##     TUNNEL_DEV    - Tunnel device
##     TUNNEL_MASTER - Tunnel master device
##     TUNNEL_PEER   - Ip address of the remote side
##     TUNNEL_ID     - VNI for vxlan
##     TUNNEL_DPORT  - Port for the remote side
##     TUNNEL_SPORT  - Port for the local side
##     TUNNEL_IPV4   - IPv4 on the tunnel device, e.g. 10.30.30.1/24
##     TUNNEL_IPV6   - IPv6 on the tunnel device, e.g. fd00:1::1/64
##
##   Note that the both source and destination port must be fixed when
##   the UDP "connection" goes via a K8s service.
##
## Commands;
##

prg=$(basename $0)
dir=$(dirname $0); dir=$(readlink -f $dir)
tmp=/tmp/${prg}_$$

die() {
    echo "ERROR: $*" >&2
    rm -rf $tmp
    exit 1
}
help() {
    grep '^##' $0 | cut -c3-
    rm -rf $tmp
    exit 0
}

log() {
	echo "$*" >&2
}

# initvar <variable> [default]
#   Initiate a variable. The __<variable> will be defined if not set,
#   from $TUNNEL_<variable-upper-case> or from the passed default
initvar() {
	local n N v
	n=$1
	v=$(eval "echo \$__$n")
	test -n "$v" && return 0	# Already set
	N=$(echo $n | tr a-z A-Z)
	v=$(eval "echo \$TUNNEL_$N")
	if test -n "$v"; then
		eval "__$n=$v"
		return 0
	fi
	test -n "$2" && eval "__$n=$2"
	return 0
}

##   env
##     Print environment. Values of all settable variables are printed.
cmd_env() {
	test "$envset" = "yes" && return 0
	params="type|dev|master|peer|id|dport|sport|ipv4|ipv6"
	initvar type vxlan
	initvar dev vxlan0
	initvar master
	initvar peer
	initvar id 333
	initvar dport 5533
	initvar sport 5533
	initvar ipv4
	initvar ipv6
	if test "$cmd" = "env"; then
		set | grep -E "^__($params).*=" | sort
		return 0
	fi
	envset=yes
}
##   init
##     Init a container. This is default if PID==1.
cmd_init() {
	log "Container init"
	cmd_env
	test -n "$__master" || __master=eth0
	set | grep -E "^__($params).*=" | sort
	cmd_tunnel
	tail -f /dev/null
}
##   hold
##     Hold execution
cmd_hold() {
	tail -f /dev/null
}
##   tunnel [--type=vxlan]
##     Setup a tunnel. Values are taken from TUNNEL_ environment variables,
##     parameters or default.
cmd_tunnel() {
	cmd_env
	if test -z "$__peer"; then
		log "No peer specified, just hold ..."
		tail -f /dev/null
	elif echo "$__peer" | grep -q TUNNEL; then
		die "The TUNNEL_PEER variable has not been set to an IP address"
	fi
	cmd_wait_for_udp || log "FAILED: wait_for_udp"
	case $__type in
		vxlan)
			cmd_vxlan;;
		*)
			die "Tunnel type not supported [$TUNNEL_TYPE]"
	esac
	ip link set up dev $__dev
	test -n "$__ipv4" && ip addr add $__ipv4 dev $__dev
	test -n "$__ipv6" && ip -6 addr add $__ipv6 dev $__dev
}
##   wait_for_udp --peer=ip-address [--sport=]
##     Wait for an UDP packet. This MUST be done *before* setting up
##     the tunnel if the peer is connected through a K8s service. It
##     indicates that an UDP "connection" has been setup. If the
##     tunnel setup without a UDP connection messages will be sent to
##     the peer with the node IP as source (the normal ipv4 egress
##     setup in K8s). This will fail and worse, it will mess up the
##     conntracker so later connect attempts via the service will
##     fail!
cmd_wait_for_udp() {
	cmd_env
	log "Waiting for UDP packet from $__peer, port $__sport"
	test -n "$__peer" || die "No peer address"
	tcpdump -ni eth0 --immediate-mode -c 1 udp and host $__peer and port $__sport
}
##   vxlan --peer=ip-address [--master] [--dev=] [--id=vni] \
##       [--dport=] [--sport=]
##     Setup a vxlan tunnel. In a POD this should be preceded by a
##     "wait_for_udp".
cmd_vxlan() {
	cmd_env
	log "Setup a VXLAN tunnel to [$__peer]"
	test -n "$__peer" || die "No peer address"
	local sport1=$((__sport + 1))
	if test -n "$__master"; then
		ip link add $__dev type vxlan id $__id dev $__master remote $__peer \
			dstport $__dport srcport $__sport $sport1
	else
		ip link add $__dev type vxlan id $__id remote $__peer \
			dstport $__dport srcport $__sport $sport1
	fi
}

##
# Get the command;
#  1 - From the command line
#  2 - From the $TUNNEL_FUNCTION variable
#  3 - Assume "init" for PID==1
#  4 - Print help
if test -n "$1"; then
	cmd=$1
	shift
elif test -n "$TUNNEL_FUNCTION"; then
	cmd=$TUNNEL_FUNCTION
elif test $$ -eq 1; then
	cmd=init
else
	help
fi
echo "$cmd" | grep -qEi "^(help|-h)" && help
grep -q "^cmd_$cmd()" $0 $hook || die "Invalid command [$cmd]"

while echo "$1" | grep -q '^--'; do
    if echo $1 | grep -q =; then
	o=$(echo "$1" | cut -d= -f1 | sed -e 's,-,_,g')
	v=$(echo "$1" | cut -d= -f2-)
	eval "$o=\"$v\""
    else
	o=$(echo "$1" | sed -e 's,-,_,g')
	eval "$o=yes"
    fi
    shift
done
unset o v
long_opts=`set | grep '^__' | cut -d= -f1`

# Execute command
trap "die Interrupted" INT TERM
cmd_$cmd "$@"
status=$?
rm -rf $tmp
exit $status
