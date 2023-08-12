#!/usr/bin/env bash

set -e

. /opt/arpl/include/functions.sh

# Wait kernel enumerate the disks
CNT=3
while true; do
  [ "${CNT}" -eq "0" ] && break
  LOADER_DISK="$(blkid | grep 'LABEL="ARPL3"' | cut -d3 -f1)"
  [ -n "${LOADER_DISK}" ] && break
  CNT=$((${CNT}-1))
  sleep 1
done

[ -z "${LOADER_DISK}" ] && die "Loader disk not found!"
NUM_PARTITIONS=$(blkid | grep "${LOADER_DISK}[0-9]\+" | cut -d: -f1 | wc -l)
[ "${NUM_PARTITIONS}" -lt "3" ] && die "Loader disk seems to be damaged!"
[ "${NUM_PARTITIONS}" -gt "3" ] && die "There are multiple loader disks, please insert only one loader disk!"

# Check partitions and ignore errors
fsck.vfat -aw "${LOADER_DISK}1" >/dev/null 2>&1 || true
fsck.ext2 -p "${LOADER_DISK}2" >/dev/null 2>&1 || true
fsck.ext4 -p "${LOADER_DISK}3" >/dev/null 2>&1 || true

# Make folders to mount partitions
mkdir -p "${BOOTLOADER_PATH}"
mkdir -p "${SLPART_PATH}"
mkdir -p "${CACHE_PATH}"
mkdir -p "${DSMROOT_PATH}"

# Mount the partitions
mount "${LOADER_DISK}1" "${BOOTLOADER_PATH}" || die "Can't mount ${BOOTLOADER_PATH}"
mount "${LOADER_DISK}2" "${SLPART_PATH}"     || die "Can't mount ${SLPART_PATH}"
mount "${LOADER_DISK}3" "${CACHE_PATH}"      || die "Can't mount ${CACHE_PATH}"

# Shows title
clear
TITLE="${ARPL_TITLE}"
printf "\033[1;30m%*s\n" $COLUMNS ""
printf "\033[1;30m%*s\033[A\n" $COLUMNS ""
printf "\033[1;34m%*s\033[0m\n" $(((${#TITLE}+$COLUMNS)/2)) "${TITLE}"
printf "\033[1;30m%*s\033[0m\n" $COLUMNS ""

# Move/link SSH machine keys to/from cache volume
[ ! -d "${CACHE_PATH}/ssh" ] && cp -R /etc/ssh "${CACHE_PATH}/ssh"
rm -rf /etc/ssh
ln -s "${CACHE_PATH}/ssh" /etc/ssh

# Link bash history to cache volume
rm -rf ~/.bash_history
ln -s "${CACHE_PATH}/.bash_history" ~/.bash_history
touch ~/.bash_history
if ! grep -q "arc.sh" ~/.bash_history; then
  echo "arc.sh " >>~/.bash_history
fi

# Check if exists directories into P3 partition, if yes remove and link it
if [ -d "${CACHE_PATH}/model-configs" ]; then
  rm -rf "${MODEL_CONFIG_PATH}"
  ln -s "${CACHE_PATH}/model-configs" "${MODEL_CONFIG_PATH}"
fi
if [ -d "${CACHE_PATH}/patch" ]; then
  rm -rf "${PATCH_PATH}"
  ln -s "${CACHE_PATH}/patch" "${PATCH_PATH}"
fi

# If user config file not exists, initialize it
if [ ! -f "${USER_CONFIG_FILE}" ]; then
  touch "${USER_CONFIG_FILE}"
  writeConfigKey "lkm" "prod" "${USER_CONFIG_FILE}"
  writeConfigKey "model" "" "${USER_CONFIG_FILE}"
  writeConfigKey "productver" "" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.paturl" "" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.pathash" "" "${USER_CONFIG_FILE}"
  writeConfigKey "sn" "" "${USER_CONFIG_FILE}"
  # writeConfigKey "maxdisks" "" "${USER_CONFIG_FILE}"
  writeConfigKey "layout" "qwertz" "${USER_CONFIG_FILE}"
  writeConfigKey "keymap" "de" "${USER_CONFIG_FILE}"
  writeConfigKey "zimage-hash" "" "${USER_CONFIG_FILE}"
  writeConfigKey "ramdisk-hash" "" "${USER_CONFIG_FILE}"
  writeConfigKey "cmdline" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "synoinfo" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "addons" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "addons.acpid" "" "${USER_CONFIG_FILE}"
  writeConfigKey "extensions" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "modules" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "arc" "{}" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.directboot" "false" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.directdsm" "false" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.usbmount" "false" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.patch" "false" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.bootipwait" "20" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.notsetmac" "false" "${USER_CONFIG_FILE}"
  writeConfigKey "arc.kernelload" "power" "${USER_CONFIG_FILE}"
  writeConfigKey "device" "{}" "${USER_CONFIG_FILE}"
fi

NOTSETMAC="$(readConfigKey "arc.notsetmac" "${USER_CONFIG_FILE}")"
if [ "${NOTSETMAC}" = "false" ]; then
  # Get MAC address
  ETHX=($(ls /sys/class/net/ | grep eth))  # real network cards list
  for N in $(seq 1 ${#ETHX[@]}); do
    MACR="$(cat /sys/class/net/${ETHX[$((${N}-1))]}/address | sed 's/://g')"
    MACF="$(readConfigKey "cmdline.mac${N}" "${USER_CONFIG_FILE}")"
    # Initialize with real MAC
    writeConfigKey "device.mac${N}" "${MACR}" "${USER_CONFIG_FILE}"
    if [ -n "${MACF}" ] && [ "${MACF}" != "${MACR}" ]; then
      MAC="${MACF:0:2}:${MACF:2:2}:${MACF:4:2}:${MACF:6:2}:${MACF:8:2}:${MACF:10:2}"
      echo "NET: Setting ${ETHX[$((${N}-1))]} MAC to ${MAC}"
      ip link set dev ${ETHX[$((${N}-1))]} address ${MAC} >/dev/null 2>&1
    elif [ -z "${MACF}" ]; then
      # Write real Mac to cmdline config
      writeConfigKey "cmdline.mac${N}" "${MACR}" "${USER_CONFIG_FILE}"
    fi
    # Enable Wake on Lan, ignore errors
    ethtool -s ${ETHX[$((${N}-1))]} wol g 2>/dev/null
    echo -e "NET: WOL enabled: ${ETHX[$((${N}-1))]}"
  done
  # Restart DHCP
  /etc/init.d/S41dhcpcd restart >/dev/null 2>&1 || true
elif [ "${NOTSETMAC}" = "true" ]; then
  # Get MAC address
  ETHX=($(ls /sys/class/net/ | grep eth))  # real network cards list
  for N in $(seq 1 ${#ETHX[@]}); do
    MACR="$(cat /sys/class/net/${ETHX[$((${N}-1))]}/address | sed 's/://g')"
    # Initialize with real MAC
    writeConfigKey "device.mac${N}" "${MACR}" "${USER_CONFIG_FILE}"
    # Write real Mac to cmdline config
    writeConfigKey "cmdline.mac${N}" "${MACR}" "${USER_CONFIG_FILE}"
  done
  echo -e "NET: Not set Boot MAC enabled"
fi
echo

# Get the VID/PID if we are in USB
VID="0x0000"
PID="0x0000"
BUS=$(udevadm info --query property --name ${LOADER_DISK} | grep ID_BUS | cut -d= -f2)
if [ "${BUS}" = "usb" ]; then
  VID="0x$(udevadm info --query property --name ${LOADER_DISK} | grep ID_VENDOR_ID | cut -d= -f2)"
  PID="0x$(udevadm info --query property --name ${LOADER_DISK} | grep ID_MODEL_ID | cut -d= -f2)"
  writeConfigKey "vid" ${VID} "${USER_CONFIG_FILE}"
  writeConfigKey "pid" ${PID} "${USER_CONFIG_FILE}"
elif [ "${BUS}" = "ata" ]; then
  writeConfigKey "vid" ${VID} "${USER_CONFIG_FILE}"
  writeConfigKey "pid" ${PID} "${USER_CONFIG_FILE}"
else
  die "Loader disk neither USB or DoM"
fi

# Inform user
echo -en "Loader disk: \033[1;34m${LOADER_DISK}\033[0m ("
if [ "${BUS}" = "usb" ]; then
  echo -en "\033[1;34mUSB flashdisk\033[0m"
elif [ "${BUS}" = "ata" ]; then
  echo -en "\033[1;34mSATA DoM\033[0m"
fi
echo ")"

# Check if partition 3 occupies all free space, resize if needed
LOADER_DEVICE_NAME=$(echo ${LOADER_DISK} | sed 's|/dev/||')
SIZEOFDISK=$(cat /sys/block/${LOADER_DEVICE_NAME}/size)
ENDSECTOR=$(($(fdisk -l ${LOADER_DISK} | awk '/'${LOADER_DEVICE_NAME}3'/{print$3}')+1))
if [ "${SIZEOFDISK}" -ne "${ENDSECTOR}" ]; then
  echo -e "\033[1;36mResizing ${LOADER_DISK}3\033[0m"
  echo -e "d\n\nn\n\n\n\n\nn\nw" | fdisk "${LOADER_DISK}" >"${LOG_FILE}" 2>&1 || dieLog
  resize2fs "${LOADER_DISK}3" >"${LOG_FILE}" 2>&1 || dieLog
fi

# Load keymap name
LAYOUT="$(readConfigKey "layout" "${USER_CONFIG_FILE}")"
KEYMAP="$(readConfigKey "keymap" "${USER_CONFIG_FILE}")"

# Loads a keymap if is valid
if [ -f /usr/share/keymaps/i386/${LAYOUT}/${KEYMAP}.map.gz ]; then
  echo -e "Loading keymap \033[1;34m${LAYOUT}/${KEYMAP}\033[0m"
  zcat /usr/share/keymaps/i386/${LAYOUT}/${KEYMAP}.map.gz | loadkeys
fi
echo

# Decide if boot automatically
BUILDDONE="$(readConfigKey "arc.builddone" "${USER_CONFIG_FILE}")"
if grep -q "IWANTTOCHANGETHECONFIG" /proc/cmdline; then
  echo -e "\033[1;31mUser requested edit settings.\033[0m"
elif [ "${BUILDDONE}" = "1" ]; then
  echo -e "\033[1;34mLoader is configured!\033[0m"
  boot.sh && exit 0
elif [ -n "${BUILDDONE}" ]; then
  echo -e "\033[1;31mLoader is not configured!\033[0m"
fi
echo

# Wait for an IP
BOOTIPWAIT="$(readConfigKey "arc.bootipwait" "${USER_CONFIG_FILE}")"
[ -z "${BOOTIPWAIT}" ] && BOOTIPWAIT=20
ETHX=($(ls /sys/class/net/ | grep eth)) # real network cards list
echo "Detected ${#ETHX[@]} NIC. Waiting for Connection:"
for N in $(seq 0 $((${#ETHX[@]}-1))); do
  DRIVER=$(ls -ld /sys/class/net/${ETHX[${N}]}/device/driver 2>/dev/null | awk -F '/' '{print $NF}')
  if [ "${N}" -eq "8" ]; then
    echo -e "\r${ETHX[${N}]}(${DRIVER}): More than 8 NIC are not supported."
    break
  fi
  COUNT=0
  sleep 3
  while true; do
    if ethtool ${ETHX[${N}]} | grep 'Link detected' | grep -q 'no'; then
      echo -e "\r${ETHX[${N}]}(${DRIVER}): NOT CONNECTED"
      break
    fi
    IP=$(ip route show dev ${ETHX[${N}]} 2>/dev/null | sed -n 's/.* via .* src \(.*\)  metric .*/\1/p')
    if [ -n "${IP}" ]; then
      echo -e "\r${ETHX[${N}]}(${DRIVER}): Access \033[1;34mhttp://${IP}:7681\033[0m to connect Arc via web."
      break
    fi
    COUNT=$((${COUNT}+1))
    if [ "${COUNT}" -eq "${BOOTIPWAIT}" ]; then
      echo -e "\r${ETHX[${N}]}(${DRIVER}): TIMEOUT."
      break
    fi
    sleep 1
  done
done

# Inform user
echo
echo -e "Call \033[1;34marc.sh\033[0m to configure loader"
echo
echo -e "User config is on \033[1;34m${USER_CONFIG_FILE}\033[0m"
echo -e "Default SSH Root password is \033[1;34marc\033[0m"
echo

# Check memory
RAM=$(free -m | grep -i mem | awk '{print$2}')
if [ ${RAM} -le 3500 ]; then
  echo -e "\033[1;341You have less than 4GB of RAM, if errors occur in loader creation, please increase the amount of memory.\033[0m\n"
fi

mkdir -p "${ADDONS_PATH}"
mkdir -p "${LKM_PATH}"
mkdir -p "${MODULES_PATH}"

# Load arc
install-addons.sh
install-extensions.sh
sleep 3
arc.sh
