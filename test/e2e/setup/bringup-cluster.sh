#! /usr/bin/env bash

# Script to bringup a 3 node k8s cluster, ready for mayastor install.
# To cleanup after this script:
# cd $KUBESPRAY_REPO
# vagrant destroy -f

set -euxo pipefail
cd "$(dirname ${BASH_SOURCE[0]})"

# Config variables
KUBESPRAY_REPO="$HOME/work/kubespray"
KUBECONFIG_TO_USE="$HOME/.kube/config"

# Globals
MASTER_NODE_NAME="k8s-1" # Set in the Vagrantfile
MASTER_NODE_IP="172.18.8.101" # Set in the Vagrantfile
REGISTRY_PORT="30291"
REGISTRY_ENDPOINT="${MASTER_NODE_IP}:${REGISTRY_PORT}"

prepare_kubespray_repo() {
  pushd $KUBESPRAY_REPO
    mkdir -p vagrant
    cat << EOF > vagrant/config.rb
# DO NOT EDIT. This file is autogenerated.
\$vm_memory = 6144
\$vm_cpus = 4
\$kube_node_instances_with_disks = true
\$kube_node_instances_with_disks_size = "2G"
\$kube_node_instances_with_disks_number = 1
\$os = "ubuntu2004"
\$etcd_instances = 1
\$kube_master_instances = 1
EOF
  popd
}

bringup_cluster() {
  #vagrant plugin install vagrant-libvirt # TODO Put this in the nix environment
  pushd $KUBESPRAY_REPO
    vagrant up --provider=libvirt
    vagrant ssh $MASTER_NODE_NAME -c "sudo cat /etc/kubernetes/admin.conf" > $KUBECONFIG_TO_USE
    kubectl get nodes # Debug
  popd
  kubectl apply -f test-registry.yaml
}

# Runs in a timeout, so we need to pass in $MASTER_NODE_IP and $REGISTRY_PORT
wait_for_ready() {
  while ! kubectl get nodes; do
    sleep 1
  done

  # Wait for the registry to be accessible
  while ! nc -z $1 $2; do
    sleep 1
  done
}

# TODO We should consider if we can do this in ansible.
setup_one_node() {
  local node_name=$1
  pushd $KUBESPRAY_REPO
    vagrant ssh $node_name -c "echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    vagrant ssh $node_name -c "echo \"vm.nr_hugepages = 1024\" | sudo tee -a /etc/sysctl.d/10-kubeadm.conf"
    vagrant ssh $node_name -c "sudo systemctl restart kubelet"

    vagrant ssh $node_name -c "echo \"{\\\"insecure-registries\\\" : [\\\"${REGISTRY_ENDPOINT}\\\"]}\" | sudo tee /etc/docker/daemon.json"
    vagrant ssh $node_name -c "sudo service docker restart"
    vagrant ssh $node_name -c "sudo systemctl enable iscsid"
    vagrant ssh $node_name -c "sudo systemctl start iscsid"
    vagrant ssh $node_name -c "sudo modprobe nvme-tcp nvmet"

    # Make sure everything's back after those restarts...
    export -f wait_for_ready
    timeout 180s bash -c "wait_for_ready $MASTER_NODE_IP $REGISTRY_PORT"

    kubectl label node $node_name openebs.io/engine=mayastor
  popd
}

# Parallel setup of each node.
setup_all_nodes() {
  NODES="$MASTER_NODE_NAME k8s-2 k8s-3"
  for node in $NODES; do
    setup_one_node $node &
  done
  for job in $(jobs -p); do
    wait $job
  done
}

prepare_kubespray_repo # Don't really need to run this everytime...
bringup_cluster
setup_all_nodes
