#!/usr/bin/env bash
# Crea 3 VMs Ubuntu 24.04 en KVM/libvirt usando cloud-init.
# La creación de la infraestructura también es "como código": reproducible y sin clics.
set -euo pipefail

# ===== Configuración =====
BASE_DIR="$HOME/vms-datacenter"
IMG_DIR="$BASE_DIR/images"
BASE_IMG="$IMG_DIR/noble-base.img"
CLOUD_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
RAM=2048          # MB por nodo (3 x 2 GB = 6 GB; sobra en un host de 16 GB)
VCPUS=2
DISK=15           # GB por nodo
NET="default"     # red NAT de libvirt -> 10.0.0.0/24
SSH_KEY="$(cat "$HOME/.ssh/id_ed25519.pub")"

# Mapa nodo -> último octeto de la IP
declare -A NODES=( [node1]=11 [node2]=12 [node3]=13 )

mkdir -p "$IMG_DIR"

# 1) Descargar la imagen base una sola vez
if [ ! -f "$BASE_IMG" ]; then
  echo ">> Descargando imagen cloud de Ubuntu 24.04..."
  wget -O "$BASE_IMG" "$CLOUD_URL"
fi

for NODE in "${!NODES[@]}"; do
  IP="10.0.0.${NODES[$NODE]}"
  NODE_DIR="$BASE_DIR/$NODE"
  mkdir -p "$NODE_DIR"

  # 2) Disco del nodo respaldado por la base (copy-on-write, ocupa poco)
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$NODE_DIR/disk.qcow2" "${DISK}G"

  # 3) user-data: usuario, llave SSH, hostname, SIN password
  cat > "$NODE_DIR/user-data" <<EOF
#cloud-config
hostname: $NODE
fqdn: $NODE.local
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: devops
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $SSH_KEY
EOF

  # 4) network-config: IP estática (netplan v2)
  cat > "$NODE_DIR/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    addresses: [$IP/24]
    routes:
      - to: default
        via: 10.0.0.1
    nameservers:
      addresses: [8.8.8.8, 1.1.1.1]
EOF

  # 5) meta-data
  cat > "$NODE_DIR/meta-data" <<EOF
instance-id: $NODE
local-hostname: $NODE
EOF

  # 6) ISO seed con cloud-init
  cloud-localds --network-config="$NODE_DIR/network-config" \
    "$NODE_DIR/seed.iso" "$NODE_DIR/user-data" "$NODE_DIR/meta-data"

  # 7) Crear e iniciar la VM
  #    Si "--os-variant ubuntu24.04" da error, usa: --osinfo detect=on,require=off
  virt-install \
    --name "$NODE" \
    --ram "$RAM" --vcpus "$VCPUS" \
    --disk "$NODE_DIR/disk.qcow2",device=disk,bus=virtio \
    --disk "$NODE_DIR/seed.iso",device=cdrom \
    --os-variant ubuntu24.04 \
    --network network="$NET",model=virtio \
    --graphics none --import --noautoconsole

  echo ">> $NODE creado con IP $IP"
done

echo ">> Listo. Espera ~1-2 min a que cloud-init termine y prueba: ssh devops@10.0.0.11"
