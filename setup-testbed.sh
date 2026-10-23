#!/bin/bash
#
#

function wait_for_device {
    echo -n "Waiting for device to be ready..."
    while ! ssh -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' "ubuntu@${1}" hostname 2>/dev/null ; do
        echo -n '.'
        sleep 30
    done
}

if [[ -n "$1" ]]; then
    JOB_ID="$1"
    echo "Using existing job with ID: $JOB_ID"
else
    pushd $HOME

    cat <<EOF > ./testflinger-job.yaml
#job_queue: buzzsaw  # it uses nvlink, not compatible with what we want to achieve
#job_queue: 202208-30518  # https://certification.canonical.com/hardware/202208-30518/
job_queue: rockman
#job_queue: hinyari  # arm64
#job_queue: beldam  # Tesla card - not sriov supported
provision_data:
  distro: noble
reserve_data:
  ssh_keys:
    - "lp:freyes"
  timeout: 21600 # 6h
  #timeout: 86400 # 1d
EOF
    JOB_ID=$(testflinger submit ./testflinger-job.yaml | grep job_id | awk '{print $2}')
    if [[ -z "$JOB_ID" ]]; then
        echo "Failed to submit job"
        exit 1
    fi
    popd
    echo "Submitted job with ID: $JOB_ID"
fi
while true; do
    STATUS=$(testflinger status $JOB_ID)
    if [[ "$STATUS" == "reserve" ]]; then
        echo -e "\nJob status: $STATUS"
        break
    else
        echo -n "."
    fi
    sleep 30
done


DEVICE_IP=$( testflinger results $JOB_ID | jq -r '.device_info.device_ip')
wait_for_device $DEVICE_IP
function run_ssh {
    ssh -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' "ubuntu@${DEVICE_IP}" $@
}


echo "ready"
run_ssh "git clone https://github.com/freyes/nvidia-vgpu-testing-infra/ ~/nvidia-vgpu-testing-infra"
run_ssh "cd ~/nvidia-vgpu-testing-infra; ./scripts/prepare-host.sh --install"
scp ./NVIDIA-GRID-Ubuntu-KVM-*.zip  ubuntu@${DEVICE_IP}:
run_ssh "mkdir -p ./drivers; unzip ./NVIDIA-GRID-Ubuntu-KVM-*.zip -d ./drivers ; cp ./drivers/Host_Drivers/nvidia-vgpu-ubuntu*.deb ./nvidia-vgpu-testing-infra/terraform/; sudo apt install ./nvidia-vgpu-testing-infra/terraform/nvidia-vgpu-ubuntu*.deb"
run_ssh "echo blacklist nouveau | sudo tee /etc/modprobe.d/blacklist-nouveau.conf"
run_ssh "loginctl enable-linger"
run_ssh "sudo reboot" || /bin/true

set +e
wait_for_device $DEVICE_IP
set -e

cat <<EOF > /tmp/terraform.tfvars
hypervisor_ip = "${DEVICE_IP}"
vcpus = 4
memory = 8124
EOF
scp /tmp/terraform.tfvars ubuntu@${DEVICE_IP}:nvidia-vgpu-testing-infra/terraform/
run_ssh "cd ~/nvidia-vgpu-testing-infra; make init"
run_ssh "cd ~/nvidia-vgpu-testing-infra; make apply"
