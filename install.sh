#!/usr/bin/env bash

# Setup script environment
set -o errexit  #Exit immediately if a pipeline returns a non-zero status
set -o errtrace #Trap ERR from shell functions, command substitutions, and commands from subshell
set -o nounset  #Treat unset variables as an error
set -o pipefail #Pipe will exit with last non-zero status if applicable
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  [ ! -z ${VMID-} ] && cleanup_vmid
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup_vmid() {
  if $(qm status $VMID &>/dev/null); then
    if [ "$(qm status $VMID | awk '{print $2}')" == "running" ]; then
      qm stop $VMID
    fi
    qm destroy $VMID
  fi
}
function cleanup() {
  popd >/dev/null
  rm -rf $TEMP_DIR
}
TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# Get the next guest VM/LXC ID
VMID=100
info "Container ID is $VMID."

for i in {0,1}; do
  disk="DISK$i"
  eval DISK${i}=vm-${VMID}-disk-${i}${DISK_EXT:-}
  eval DISK${i}_REF=${STORAGE}:${DISK_REF:-}${!disk}
done

# Add serial port and enable console output
set +o errtrace
(
  msg "Adding serial port and configuring console..."
  trap '
    warn "Unable to configure serial port. VM is still functional."
    if [ "$(qm config $VMID | sed -n ''/serial0/p'')" != "" ]; then
      qm set $VMID --delete serial0 >/dev/null
    fi
    exit
  ' ERR
  if [ "$(command -v kpartx)" = "" ]; then
    msg "Installing 'kpartx'..."
    apt-get update >/dev/null
    apt-get -qqy install kpartx &>/dev/null
  fi
  DISK1_PATH="$(pvesm path $DISK1_REF)"
  DISK1_PART1="$(kpartx -al $DISK1_PATH | awk 'NR==1 {print $1}')"
  DISK1_PART1_PATH="/dev/mapper/$DISK1_PART1"
  TEMP_MOUNT="${TEMP_DIR}/mnt"
  trap '
    findmnt $TEMP_MOUNT >/dev/null && umount $TEMP_MOUNT
    command -v kpartx >/dev/null && kpartx -d $DISK1_PATH
  ' EXIT
  kpartx -a $DISK1_PATH
  mkdir $TEMP_MOUNT
  mount $DISK1_PART1_PATH $TEMP_MOUNT
  sed -i 's/$/ console=ttyS0/' ${TEMP_MOUNT}/cmdline.txt
  qm set $VMID -serial0 socket >/dev/null
)

info "Completed Successfully!"
