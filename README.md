# k8s-service-tunnel

A tunnel from an external machine to a POD or node in K8s.

<img src="tunnel-public.svg" width="100%">

The intended usage is testing of multiple networks in K8s. For
instance in telco multiple networks are common, but a test cluster
with additional networks may be hard to come by. To use tunnels allows
additional networks at no cost. However, to setup a tunnel requires
privileges.

The tunnel is setup via a UDP service. VXLAN tunnels are used that can
carry both IPv4 and IPv6 packets, so even if the connectivity to the
cluster is IPv4-only (your UDP service is IPv4 single-stack) you can
still test with IPv6.


## The catch

When a tunnel is setup via a K8s service the external machine *must
initiate the communication* to setup the load-balancing session. If
the POD uses the tunnel before the connection via the service is setup
it will send packets masqueraded to the node IP (at least for the most
common IPv4 setup). This will also create conntrack entries that make
a later setup via the service impossible (until conntrack is cleared).
This complicates the setup.

The ports must also be the same in both directions which limits the
number of usable tunnels types. On Linux both source and destination
ports can be specified for `vxlan`. I don't know how it works on other
OSes.


## How it works

A UDP sevice is defined.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vxlan-tunnel
spec:
  selector:
    app: service-tunnel
  externalTrafficPolicy: Local
  ports:
  - port: 5533
    name: vxlan
    protocol: UDP
  type: LoadBalancer
```

The service has `externalTrafficPolicy: Local` so the tunnel in the
POD can be setup with the correct (un-NAT'ed) remote address. A POD is
started and waits for incoming UDP packets on port 5533.

Now we go to the external machine, e.g. your home computer.  The
load-balancer IP assigned to the service should be used as remote
address.

```
kubectl get svc vxlan-tunnel    # Get the external IP
remote=...
ip link add vxlan0 type vxlan id 333 dev wlp2s0 remote $remote dstport 5533 srcport 5533 5534
ip link set up dev vxlan0       # Now UDP packets are sent to the service
ip addr add 10.30.30.2/30 dev vxlan0
ip -6 addr add fd00:3030::2/126 dev vxlan0
```

When a UDP packet is received in the POD we assume that the
load-balancing via the service is setup and a vxlan tunnel device can
be created.  Your home computer is probably NAT'ed if you use IPv4, so
you must find you "real" address to set the remote address in the POD.

```
# On your home computer
myip=$(curl -sq https://api.myip.com | jq -r .ip)  # Get your real IP
# In the POD
remote=<take from $myip above>
ip link add vxlan0 type vxlan id 333 dev eth0 remote $remote dstport 5533 srcport 5533 5534
ip addr add 10.30.30.1/30 dev vxlan0
ip -6 addr add fd00:3030::1/126 dev vxlan0
```

