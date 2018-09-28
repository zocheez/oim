#!/bin/bash -e

set -o pipefail

NUM_NODES=$1
LAST_NODE=$(($NUM_NODES - 1))
PROXY_ENV="env 'HTTP_PROXY=$HTTP_PROXY' 'HTTPS_PROXY=$HTTPS_PROXY' 'NO_PROXY=$NO_PROXY'"

# We run with tracing enabled, but suppress the trace output for some
# parts with 2>/dev/null (in particular, echo commands) to keep the
# output a bit more readable.
set -x

# Kills a process and all its children.
kill_process_tree () {
    name=$1
    pid=$2

    pids=$(ps -o pid --ppid $pid | tail +2)
    if [ "$pids" ]; then
        kill $pids
    fi
}

# Creates a virtual machine and enables SSH for it. Must be started
# in a sub-shell. The virtual machine is kept running until this
# sub-shell is killed.
setup_clear_img () (
    image=$1
    imagenum=$2
    set -e

    # We use copy-on-write for per-host image files. We don't share as much as we could (for example,
    # each host adds its own bundles), but at least the base image is the same.
    qemu-img create -f qcow2 -o backing_file=clear-kvm-original.img $image

    # Same start script for all virtual machines. It gets called with
    # the image name.
    ln -sf start-clear-kvm _work/start-clear-kvm.$imagenum

    # Determine which machine we build and the parameters for it.
    seriallog=_work/serial.$imagenum.log
    hostname=host-$imagenum
    ipaddr=192.168.7.$(($imagenum * 2 + 2))

    # coproc runs the shell commands in a separate process, with
    # stdin/stdout available to the caller.
    coproc sh -c "_work/start-clear-kvm $image | tee $seriallog"

    kill_qemu () {
        (
            touch _work/clear-kvm.$imagenum.terminated
            if [ "$COPROC_PID" ]; then
                kill_process_tree QEMU $COPROC_PID
            fi
        )
    }
    trap kill_qemu EXIT SIGINT SIGTERM

    # bash will detect when the coprocess dies and then unset the COPROC variables.
    # We can use that to check that QEMU is still healthy and avoid "ambiguous redirect"
    # errors when reading or writing to empty variables.
    qemu_running () {
        ( if ! [ "$COPROC_PID" ]; then echo "ERRROR: QEMU died unexpectedly, see error messages above."; exit 1; fi ) 2>/dev/null
    }

    # Wait for certain output from the co-process.
    waitfor () {
        ( term="$1"
          while IFS= read -d : -r x && ! [[ "$x" =~ "$term" ]]; do
              :
          done ) 2>/dev/null
    }

    qemu_running
    ( echo "Waiting for initial root login, see $(pwd)/$seriallog" ) 2>/dev/null
    waitfor "login" <&${COPROC[0]}

    # We get some extra messages on the console that should be printed
    # before we start interacting with the console prompt.
    ( echo "Give Clear Linux some time to finish booting." ) 2>/dev/null
    sleep 5

    qemu_running
    ( echo "Changing root password..." ) 2>/dev/null
    echo "root" >&${COPROC[1]}
    waitfor "New password" <&${COPROC[0]}
    qemu_running
    echo "$(cat _work/passwd)" >&${COPROC[1]}
    waitfor "Retype new password" <&${COPROC[0]}
    qemu_running
    echo "$(cat _work/passwd)" >&${COPROC[1]}

    # SSH needs to be enabled explicitly on Clear Linux.
    echo "mkdir -p /etc/ssh && echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config && mkdir -p .ssh && echo '$(cat _work/id.pub)' >>.ssh/authorized_keys" >&${COPROC[1]}

    # SSH invocations must use that secret key, shouldn't worry about known hosts (because those are going
    # to change), and log into the right machine.
    echo "#!/bin/sh" >_work/ssh-clear-kvm.$imagenum
    echo "exec ssh -oIdentitiesOnly=yes -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=error -i $(pwd)/_work/id root@$ipaddr \"\$@\"" >>_work/ssh-clear-kvm.$imagenum
    chmod u+x _work/ssh-clear-kvm.$imagenum

    # Set up the static network configuration, both for booting with and without network interface renaming.
    echo "mkdir -p /etc/systemd/network" >&${COPROC[1]}
    for i in "[Match]" "Name=ens4" "[Network]" "Address=$ipaddr/24" "Gateway=192.168.7.$(($imagenum * 2 + 1))" "DNS=8.8.8.8"; do echo "echo '$i' >>/etc/systemd/network/20-wired.network" >&${COPROC[1]}; done
    for i in "[Match]" "Name=eth0" "[Network]" "Address=$ipaddr/24" "Gateway=192.168.7.$(($imagenum * 2 + 1))" "DNS=8.8.8.8"; do echo "echo '$i' >>/etc/systemd/network/20-wired.network" >&${COPROC[1]}; done
    echo "systemctl restart systemd-networkd" >&${COPROC[1]}



    # Install kubelet, kubeadm and Docker.
    ( echo "Configuring Kubernetes..." ) 2>/dev/null
    _work/ssh-clear-kvm.$imagenum "$PROXY_ENV swupd bundle-add cloud-native-basic"

    # Enable IP Forwarding.
    _work/ssh-clear-kvm.$imagenum 'mkdir /etc/sysctl.d && echo net.ipv4.ip_forward = 1 >/etc/sysctl.d/60-k8s.conf && systemctl restart systemd-sysctl'

    # Due to stateless /etc is empty but /etc/hosts is needed by k8s pods.
    # It also expects that the local host name can be resolved. Let's use a nicer one
    # instead of the normal default (clear-<long hex string>).
    _work/ssh-clear-kvm.$imagenum "hostnamectl set-hostname $hostname" && _work/ssh-clear-kvm.$imagenum "echo 127.0.0.1 localhost $hostname >>/etc/hosts"

    # br_netfilter must be loaded explicitly on the Clear Linux KVM kernel (and only there),
    # otherwise the required /proc/sys/net/bridge/bridge-nf-call-iptables isn't there.
    _work/ssh-clear-kvm.$imagenum modprobe br_netfilter && _work/ssh-clear-kvm.$imagenum 'echo br_netfilter >>/etc/modules'

    # Disable swap (permanently).
    _work/ssh-clear-kvm.$imagenum systemctl mask $(_work/ssh-clear-kvm.$imagenum cat /proc/swaps | sed -n -e 's;^/dev/\([0-9a-z]*\).*;dev-\1.swap;p')
    _work/ssh-clear-kvm.$imagenum swapoff -a

    # Choose Docker by disabling the use of CRI-O in KUBELET_EXTRA_ARGS.
    _work/ssh-clear-kvm.$imagenum 'mkdir -p /etc/systemd/system/kubelet.service.d/'
    _work/ssh-clear-kvm.$imagenum "( echo '[Service]'; echo 'Environment=\"KUBELET_EXTRA_ARGS=\"'; ) >/etc/systemd/system/kubelet.service.d/extra.conf"

    # Disable CNI by overriding the default "KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/usr/libexec/cni".
    _work/ssh-clear-kvm.$imagenum 'mkdir -p /etc/systemd/system/kubelet.service.d/'
    _work/ssh-clear-kvm.$imagenum "( echo '[Service]'; echo 'Environment=\"KUBELET_NETWORK_ARGS=\"'; ) >/etc/systemd/system/kubelet.service.d/network.conf"

    # Proxy settings for Docker.
    _work/ssh-clear-kvm.$imagenum 'mkdir -p /etc/systemd/system/docker.service.d/'
    _work/ssh-clear-kvm.$imagenum "( echo '[Service]'; echo 'Environment=\"HTTP_PROXY=$HTTP_PROXY\" \"HTTPS_PROXY=$HTTPS_PROXY\" \"NO_PROXY=$NO_PROXY\"'; echo 'ExecStart='; echo 'ExecStart=/usr/bin/dockerd --storage-driver=overlay2 --default-runtime=runc' ) >/etc/systemd/system/docker.service.d/oim.conf"

    # Testing may involve a Docker registry running on the build host (see
    # REGISTRY_NAME). We need to trust that registry, otherwise Docker
    # will refuse to pull images from it.
    _work/ssh-clear-kvm.$imagenum "mkdir -p /etc/docker && echo '{ \"insecure-registries\":[\"192.168.7.1:5000\"] }' >/etc/docker/daemon.json"

    # Reconfiguration done, start daemons.
    _work/ssh-clear-kvm.$imagenum 'systemctl daemon-reload && systemctl restart docker kubelet && systemctl enable docker kubelet'

    set +x
    echo "up and running"
    touch _work/clear-kvm.$imagenum.running
    qemu_running
    wait $COPROC_PID
)

# Create an alias for logging into the master node.
ln -sf ssh-clear-kvm.0 _work/ssh-clear-kvm

# Create all virtual machines in parallel.
declare -a machines
kill_machines () {
    ps xwww --forest
    for i in $(seq 0 $LAST_NODE); do
        if [ "${machines[$i]}" ]; then
            kill_process_tree "QEMU setup #$i" ${machines[$i]}
            wait ${machines[$i]} || true
            machines[$i]=
        fi
    done
}
trap kill_machines EXIT SIGINT SIGTERM
rm -f _work/clear-kvm.*.running _work/clear-kvm.*.terminated _work/clear-kvm.[0-9].img
for i in $(seq 0 $LAST_NODE); do
    setup_clear_img _work/clear-kvm.$i.img $i &> >(sed -e "s/^/$i:/") &
    machines[$i]=$!
done

# setup_clear_img notifies us when VMs are ready by creating a
# clear-kvm.*.running file.
all_running () {
    [ $(ls -1 _work/clear-kvm.*.running 2>/dev/null | wc -l) -eq $((LAST_NODE + 1)) ]
}

# Same for termination.
some_failed () {
    [ $(ls -1 _work/clear-kvm.*.terminated 2>/dev/null | wc -l) -gt 0 ]
}

# Wait until all are up and running.
while ! all_running; do
    sleep 1
    if some_failed; then
        echo
        echo "The following virtual machines failed unexpectedly, see errors above:"
        ls -1 _work/clear-kvm.*.terminated | sed -e 's;_work/clear-kvm.\(.*\).terminated;    #\1;'
        echo
        exit 1
    fi
done 2>/dev/null

# TODO: it is possible to set up each node in parallel, see
# https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/#automating-kubeadm

# We use Docker (the default),
# but have to suppress a version check:
# [ERROR SystemVerification]: unsupported docker version: 18.06.1
_work/ssh-clear-kvm.0 '$PROXY_ENV kubeadm init --ignore-preflight-errors=SystemVerification' | tee _work/clear-kvm-kubeadm.0.log
_work/ssh-clear-kvm.0 'mkdir -p .kube'
_work/ssh-clear-kvm.0 'cp -i /etc/kubernetes/admin.conf .kube/config'

# Allow normal pods on master node. This is particularly important because
# we only attach SPDK to that node, so pods using storage acceleration *have*
# to run on that node. To ensure that, we set the "intel.com/oim" label to 1 and
# use that as a node selector.
_work/ssh-clear-kvm.0 kubectl taint nodes --all node-role.kubernetes.io/master-
_work/ssh-clear-kvm.0 kubectl label nodes host-0 intel.com/oim=1

# Done.
( echo "Use $(pwd)/clear-kvm-kube.config as KUBECONFIG to access the running cluster." ) 2>/dev/null
_work/ssh-clear-kvm.0 'cat /etc/kubernetes/admin.conf' | sed -e 's;https://.*:6443;https://192.168.7.2:6443;' >_work/clear-kvm-kube.config

# Verify that Kubernetes works by starting it and then listing pods.
# We also wait for the node to become ready, which can take a while because
# images might still need to be pulled. This can take minutes, therefore we sleep
# for one minute between output.
( echo "Waiting for Kubernetes cluster to become ready..." ) 2>/dev/null
_work/kube-clear-kvm
while ! _work/ssh-clear-kvm.0 kubectl get nodes | grep -q 'Ready'; do
    _work/ssh-clear-kvm.0 kubectl get nodes
    _work/ssh-clear-kvm.0 kubectl get pods --all-namespaces
    sleep 60
done
_work/ssh-clear-kvm.0 kubectl get nodes
_work/ssh-clear-kvm.0 kubectl get pods --all-namespaces

# Doing the same locally only works if we have kubectl.
if command -v kubectl >/dev/null; then
    kubectl --kubeconfig _work/clear-kvm-kube.config get pods --all-namespaces
fi

# Let the other machines join the cluster.
for i in $(seq 1 $LAST_NODE); do
    _work/ssh-clear-kvm.$i $(grep "kubeadm join.*token" _work/clear-kvm-kubeadm.0.log) --ignore-preflight-errors=SystemVerification
done

# Clean shutdown.
for i in $(seq 0 $LAST_NODE); do
    _work/ssh-clear-kvm.$i shutdown now || true
done
for i in $(seq 0 $LAST_NODE); do
    wait ${machines[$i]}
    machines[$i]=
done

echo "done"
