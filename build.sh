#!/bin/bash

# Exit on errors
ORIG_DIR=$(pwd)
set -e
function print_info()
{
    green='\e[0;32m'
    endColor='\e[0m'
    echo -e "${green}=> $1${endColor}"
    if [[ -n "$LOG" && -f "$LOG" ]]; then
        echo "=> $1" >> "$LOG"
    fi
}

function print_error()
{
    red='\e[0;31m'
    endColor='\e[0m'
    echo -e "${red}!!> $1${endColor}"
    if [[ -n "$LOG" && -f "$LOG" ]]; then
        echo "!!> $1" >> "$LOG"
    fi
}

function cleanup()
{
    set +e

    EXIT_AFTER=false
    if [ ! -z "$1" ] && [ "$1" == "-clean" ]; then
        print_info "Cleaning up"
    else
        print_error "Error occurred! Read $LOG for details."
        if $DEBUG && $CHROOT_READY; then
            LANG=C chroot ${rootfs} /bin/bash
        fi
        EXIT_AFTER=true
        print_info "Cleaning up"
    fi
    # Make sure we're not in the mounted filesystem anymore, or unmount -l would silently keep waiting!
    print_info "Change working directory to $ORIG_DIR..."
    cd $ORIG_DIR

    # Unmount
    umount -l ${rootfs}/usr/src/delivery &>> $LOG
    umount -l ${rootfs}/dev/pts &>> $LOG
    umount -l ${rootfs}/dev &>> $LOG
    umount -l ${rootfs}/sys &>> $LOG
    umount -l ${rootfs}/proc &>> $LOG
    umount -l ${rootfs} &>> $LOG
    if [ ! -z ${rootp} ]; then
        umount -l ${rootp} &>> $LOG
    fi

    # Remove build directory
    if [ ! -z "$BUILD_ENV" ]; then
        print_info "Remove directory $BUILD_ENV ..."
        rm -rf "$BUILD_ENV"
    fi

    # Remove partition mappings
    if [ ! -z ${lodevice} ]; then
        print_info "remove $lodevice ..."
        kpartx -vd ${lodevice} &>> $LOG
        losetup -d ${lodevice} &>> $LOG
    fi

    if [ $EXIT_AFTER = true ]; then
        exit 1
    fi
}


if [ ${EUID} -ne 0 ]; then
  print_error "this tool must be run as root"
  exit 1
fi

# When true, script will drop into a chroot shell at the end to inspect the
# bootstrapped system
if [ -z "$DEBUG" ]; then
    DEBUG=true
fi


# =================== #
#    CONFIGURATION    #
# =================== #

# Size of target SD card in MB
if [ -z "$IMAGESIZE" ]; then
    IMAGESIZE="4000"
fi

# Debian version
if [ -z "$DEB_RELEASE" ]; then
    DEB_RELEASE="jessie"
fi
if [ -z "$DEFAULT_DEB_MIRROR" ]; then
    DEFAULT_DEB_MIRROR="http://ftp.de.debian.org/debian/"
fi
# Whether to use a local debian mirror (e.g. via 'apt-cacher-ng')
if [ -z "$USE_LOCAL_MIRROR" ]; then
    USE_LOCAL_MIRROR=true
fi
if [ -z "$LOCAL_DEB_MIRROR" ]; then
    LOCAL_DEB_MIRROR="http://localhost:3142/ftp.de.debian.org/debian"
fi

# Path to authorized SSH key, exported for scripts/04-users
if [ -z "$SSH_KEY" ]; then
    SSH_KEY="~/.ssh/id_rsa.pub"
fi
export SSH_KEY

if [ -z "$RASBIAN_KEY_URL" ]; then
    DEBIAN_KEY_URL="https://ftp-master.debian.org/keys/archive-key-8.asc"
fi

# -------------------------------------------------------------------------- #

# Path to build directory, by default a temporary directory

# Register cleanup function to run before we exit
trap cleanup EXIT

print_info "Creating temporary directory..."
BUILD_ENV=$(mktemp -d)
print_info "Temporary directory created at $BUILD_ENV"

BASE_DIR="$(dirname $0)"
SCRIPT_DIR="$(readlink -m $BASE_DIR)"
LOG="${SCRIPT_DIR}/buildlog.txt"
IMG="${SCRIPT_DIR}/spreadchroot.img"
DELIVERY_DIR="$SCRIPT_DIR/delivery"
rootfs="${BUILD_ENV}/rootfs"
QEMU_ARM_STATIC="/usr/bin/qemu-arm-static"
CHROOT_READY=true

if [ -e $IMG ]; then
    print_error "spreadchroot.img already exists, please remove it before running the script."
    exit 1
fi

if [ -n "$FROM_TARBALL" ]; then
    cp $FROM_TARBALL $DELIVERY_DIR/spreads-sdist.tar.gz
    print_info "Installing from tarball $FROM_TARBALL"
fi

# Exported to subshells
export DELIVERY_DIR

print_info "Creating log file $LOG"
rm -f $LOG
touch "$LOG"
chmod a+r "$LOG"

if $USE_LOCAL_MIRROR; then
    DEB_MIRROR=$LOCAL_DEB_MIRROR
else
    DEB_MIRROR=$DEFAULT_DEB_MIRROR
fi
print_info "Using mirror $DEB_MIRROR"

# Create build dir
print_info "Create directory $BUILD_ENV"
mkdir -p "${BUILD_ENV}"

# Create image mount dir
print_info "Create image mount point $rootfs"
mkdir -p "${rootfs}"

# Install dependencies
for dep in binfmt-support qemu qemu-user-static debootstrap kpartx dmsetup dosfstools; do
  problem=$(dpkg -s $dep|grep installed)
  if [ "" == "$problem" ]; then
    print_info "No $dep. Setting up $dep"
    apt-get --force-yes --yes install "$dep" &>> "$LOG"
  fi
done


# Install debian key
print_info "Fetching and installing debian public key from $RASBIAN_KEY_URL"
wget --quiet "$DEBIAN_KEY_URL" -O - | apt-key add - &>> "$LOG"

# Create image file
print_info "Initializing image file $IMG"
dd if=/dev/zero of=${IMG} bs=1MB count=$IMAGESIZE &>> "$LOG"

print_info "Creating a loopback device for $IMG..."
lodevice=$(losetup -f --show ${IMG})
print_info "Loopback $lodevice created."

# Setup up /root partition
# TODO: fdisk always returns 1, so we have to temporary set +e
set +e
# TODO: find other way to verify partitions made (maybe fdisk | wc -l)
print_info "Creating partitions on $IMG..."
echo "
n
p
1


w
" | fdisk ${lodevice} &>> "$LOG"
set -e

# Set up loopback devices
print_info "Removing $lodevice ..."
dmsetup remove_all &>> "$LOG"
losetup -d ${lodevice} &>> "$LOG"
print_info "Creating device map for $IMG ... "
device=$(kpartx -va ${IMG} | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1)
device="/dev/mapper/${device}"
print_info "Device map created at $device"

rootp="${device}p1"

# Does rootp exist?
sleep 5
print_info "Checking $rootp exists..."
[ ! -e "$rootp" ] && exit 1

# Create file systems
print_info "Creating filesystems on $IMG ..."
mkfs.ext4 ${rootp} &>> "$LOG"

print_info "Mounting $rootp to $rootfs ..."
mount ${rootp} ${rootfs} &>> "$LOG"

print_info "Creating directories in $rootfs ..."
mkdir -p ${rootfs}/proc
mkdir -p ${rootfs}/sys
mkdir -p ${rootfs}/dev/pts
mkdir -p ${rootfs}/usr/src/delivery

# Mount pseudo file systems
print_info "Mounting pseudo filesystems in $rootfs ..."
mount -t proc proc ${rootfs}/proc
mount -t sysfs sys ${rootfs}/sys
mount --bind /dev ${rootfs}/dev
mount --bind /dev/pts ${rootfs}/dev/pts

# Mount our delivery path
print_info "Mounting $DELIVERY_DIR in $rootfs ..."
mount -o bind ${DELIVERY_DIR} ${rootfs}/usr/src/delivery

print_info "Change working directory to ${rootfs} ..."
cd "${rootfs}"

# First stage of bootstrapping, from the outside
print_info "Running debootstrap first stage"
debootstrap --verbose --foreign --arch armhf --keyring \
/etc/apt/trusted.gpg ${DEB_RELEASE} ${rootfs} ${DEB_MIRROR} &>> $LOG

# Second stage, using chroot and qemu-arm from the inside
print_info "Copying $QEMU_ARM_STATIC into $rootfs"
cp "$QEMU_ARM_STATIC" "${rootfs}/usr/bin/" &>> $LOG

print_info "Running debootstrap second stage"
LANG=C chroot "${rootfs}" /debootstrap/debootstrap --second-stage &>> $LOG

# Configure Debian release and mirror
print_info "Configure apt in $rootfs..."
echo "deb ${DEB_MIRROR} ${DEB_RELEASE} main contrib non-free
" > "${rootfs}/etc/apt/sources.list"

# Configure Hostname
print_info "Writing $rootfs/etc/hostname ..."
echo "spreadchroot" > "$rootfs/etc/hostname"

print_info "Setting up keyboard layout..."
echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	us
" > "$rootfs/debconf.set"

# Run user-defined scripts from DELIVERY_DIR/scripts
print_info "Running custom bootstrapping scripts"
for path in $rootfs/usr/src/delivery/scripts/*; do
    script=$(basename "$path")
    print_info "- $script"
    DELIVERY_DIR=/usr/src/delivery LANG=C chroot ${rootfs} "/usr/src/delivery/scripts/$script" &>> $LOG
done

# Configure default mirror
print_info "Writing $rootfs/apt/sources.list again, using non-local mirror..."
echo "deb ${DEFAULT_DEB_MIRROR} ${DEB_RELEASE} main contrib non-free
" > "$rootfs/etc/apt/sources.list"

# Clean up
print_info "Cleaning up bootstrapped system"
echo "#!/bin/bash
aptitude update
aptitude clean
apt-get clean
rm -f cleanup
" > "$rootfs/cleanup"
chmod +x "$rootfs/cleanup"
LANG=C chroot ${rootfs} /cleanup &>> $LOG

print_info "Change working directory to ${rootfs} ..."
cd "${rootfs}"

if $DEBUG; then
    print_info "Dropping into shell"
    LANG=C chroot ${rootfs} /bin/bash
fi

# Kill remaining qemu-arm-static processes
if [ -n "$(pgrep qemu-arm-static)" ]; then
    print_info "Killing remaining qemu-arm-static processes..."
    kill -9 $(pgrep "qemu-arm-static")
fi

# Synchronize file systems
print_info "sync filesystems, sleep 15 seconds"
sync
sleep 15

cleanup -clean

print_info "Successfully created image ${IMG}"
fbname=$(basename "${IMG}" .img)
print_info "Compressing ${IMG} to $(date +%s)_$fbname.tgz"
tar -zcvf $(date +%s)_$fbname.tgz ${IMG}
rm ${IMG}
trap - EXIT
exit 0
