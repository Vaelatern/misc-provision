#!/bin/bash
#
# Provision a NAS.
# By default, encrypt all the drives.
# Only use the drives that are not in use.
# Choose the fastest cipher.
# Choose acceptable vdevs for a ZFS based NAS.
# Create the ZFS pool
# Also do badblocks checking

[ ! $(which zpool) ] && exit 1
[ ! $(which badblocks) ] && exit 1
[ ! $(which cryptsetup) ] && exit 1
[ ! $(which smartctl) ] && exit 1
[ ! $(which lsblk) ] && exit 1
[ ! $(which readlink) ] && exit 1
[ ! $(which openssl) ] && exit 1
[ ! $(which dd) ] && exit 1
[ ! $(which awk) ] && exit 1
[ ! $(which sed) ] && exit 1


set -u
set -e

hash=sha512
cipher_str="-plain64"
keyfile="/root/storage.key"
size=512
zpool_name="tank"
zpool_vdev_size=6
zpool_opts="-o ashift=12 -O 'compression=lz4' -O 'dedup=on'"

trsh_plain=1
trsh_mirror=2
trsh_raidz=3
trsh_raidz2=5
trsh_raidz3=7

drives="$(lsblk -ipn --output name | sed '{:a { N; /-/ d };s/\n/ /;ba}')"
cipher="$(cryptsetup benchmark | awk '/xts/ && substr($2, 0, 3) >= "512" { speed=(($3+0)+($5+0))/2; if (speed > max) { algo=$1; max=speed; }; }; END {print algo;}')${cipher_str}"

vdev_type() {
	type=""
	[ $trsh_plain -gt 0 ] && [ $trsh_plain -le $zpool_vdev_size ] && type=""
	[ $trsh_mirror -gt 0 ] && [ $trsh_mirror -le $zpool_vdev_size ] && type="mirror"
	[ $trsh_raidz -gt 0 ] && [ $trsh_raidz -le $zpool_vdev_size ] && type="raidz"
	[ $trsh_raidz2 -gt 0 ] && [ $trsh_raidz2 -le $zpool_vdev_size ] && type="raidz2"
	[ $trsh_raidz3 -gt 0 ] && [ $trsh_raidz3 -le $zpool_vdev_size ] && type="raidz3"
	echo $type
}

get_disk_id() {
	[ -b $1 ] || exit 1;
	for disk_id in /dev/disk/by-id/*; do
		export disk_id
		[ "$(readlink -f $disk_id)" = "${1}" ] && echo "${disk_id}" && exit 0
	done
}

for disk in $drives; do
	smartctl -t long "${disk}" 2>&1 >/dev/null && echo "Started smart on ${disk}"
	badblocks -sv "${disk}" 2>&1 1>/tmp/badblocks.${disk#/dev/} &
done

wait

openssl rand -out $keyfile -base64 $(( 2**21 * 3/4 ))

for disk in $drives; do
	echo "YES" | cryptsetup -s $size -c $cipher -h $hash --key-file $keyfile luksFormat $disk
	cryptsetup --key-file $keyfile open --type luks $disk "${zpool_name}-${disk#/dev/}"
	disk_id="$(get_disk_id $disk)"
	line="${zpool_name}-${disk#/dev/}	${disk_id}	${keyfile}"
	echo "${line}" >> /etc/crypttab
done
chmod a-rwx $keyfile

vdev_spec=""
vdev=""

for elem in $drives; do
	[ -z "$vdev" ] && vdev="$(vdev_type) " && count=0
	[ $count -lt $zpool_vdev_size ] && count=$(( $count+1 )) && vdev+="/dev/mapper/${zpool_name}-${elem#/dev/} "
	[ $count -eq $zpool_vdev_size ] && vdev_spec+="$vdev" && vdev=""
done

echo "By now I assume the smart data is back."
echo

for disk in $drives; do
	smartctl -H "${disk}"
done

# Test run
zpool create -n $zpool_opts $zpool_name $vdev_spec

echo -n "Continue by pressing y, cancel with ^c [Y] "
read var

for disk in $drives; do
	dd if=/dev/zero of="/dev/mapper/${zpool_name}-${disk#/dev/}" bs=1M
done

zpool create $zpool_opts $zpool_name $vdev_spec

