#!/bin/bash
# Update the Parallax host: new parallax and hands, the px helper, vault-aware sleep, and the vault image.
set -u
say(){ echo "COOKIE $*"; }
export HOME=/root DEBIAN_FRONTEND=noninteractive
. /root/.cargo/env
B=s3://cookie-parallax-558262519931-eun1/src
cd /root && /snap/bin/aws s3 cp $B/parallax.tgz parallax.tgz --only-show-errors && /snap/bin/aws s3 cp $B/hands.tgz hands.tgz --only-show-errors
rm -rf /root/parallax /root/hands && tar xzf parallax.tgz && tar xzf hands.tgz
cd /root/parallax && T0=$(date +%s) && cargo build --release -q > /root/build-px.log 2>&1; say "parallax build exit $? $(( $(date +%s)-T0 ))s"
cd /root/hands && T0=$(date +%s) && cargo build --release -q --bin hands > /root/build-hands.log 2>&1; say "hands build exit $? $(( $(date +%s)-T0 ))s $(grep -m2 '^error' /root/build-hands.log | tr '\n' ' ')"
install -m755 /root/parallax/target/release/parallax /usr/local/bin/parallax
install -m755 /root/hands/target/release/hands /usr/local/bin/hands
systemctl restart parallax

cat > /usr/local/bin/px <<'P'
#!/bin/sh
# px TOOL [JSON]: call this host's Parallax (MCP on 127.0.0.1) as the host itself.
T=$(PARALLAX_HOME=/var/lib/parallax /usr/local/bin/parallax token 2>/dev/null | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
ARGS=${2:-'{}'}
touch /var/lib/cookie/active
curl -s --max-time 900 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' http://127.0.0.1:4610/mcp \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$ARGS}}"
P
chmod 755 /usr/local/bin/px

cat > /usr/local/bin/cookie-idle <<'I'
#!/bin/bash
# Sleep after 15 idle minutes. Busy: a Cookie command lately (px touches the file),
# an awake world or vault, or a remote session. Vaults go to sleep (to disk) first.
A=/var/lib/cookie/active
[ -f "$A" ] || touch "$A"
awake=$(PARALLAX_HOME=/var/lib/parallax /usr/local/bin/parallax status 2>/dev/null | grep -o '"awake": *[0-9]*' | grep -o '[0-9]*$')
[ "${awake:-0}" -gt 0 ] && touch "$A"
pgrep -f ssm-session-worker >/dev/null && touch "$A"
age=$(( $(date +%s) - $(stat -c %Y "$A") ))
if [ "$age" -ge 900 ]; then
  T=$(PARALLAX_HOME=/var/lib/parallax /usr/local/bin/parallax token 2>/dev/null | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
  curl -s --max-time 120 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' http://127.0.0.1:4610/mcp \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"parallax_vaults_sleep_all","arguments":{}}}' >/dev/null
  logger -t cookie "idle ${age}s: vaults to disk, sleeping"
  systemctl poweroff
fi
I
chmod 755 /usr/local/bin/cookie-idle

# The vault image: minimal Ubuntu, a hidden desktop, two apps, parallax (its guest agent) and hands.
IMG=/var/lib/parallax/images/rootfs.ext4
if [ ! -f "$IMG" ] || [ "${REBUILD_IMAGE:-0}" = 1 ]; then
  T0=$(date +%s)
  apt-get install -y -qq debootstrap e2fsprogs >/dev/null 2>&1
  rm -f "$IMG.new"; truncate -s 4G "$IMG.new" && mkfs.ext4 -q -F "$IMG.new"
  mkdir -p /mnt/vroot && mount -o loop "$IMG.new" /mnt/vroot
  debootstrap --variant=minbase --components=main,universe noble /mnt/vroot http://eu-north-1.ec2.archive.ubuntu.com/ubuntu > /root/debootstrap.log 2>&1; say "debootstrap exit $?"
  chroot /mnt/vroot /bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends xvfb at-spi2-core libatk-adaptor dbus dbus-x11 zenity mousepad fonts-dejavu-core procps ca-certificates >/dev/null 2>&1; echo apt $?' | sed 's/^/COOKIE chroot /'
  install -m755 /usr/local/bin/parallax /mnt/vroot/usr/local/bin/parallax
  install -m755 /usr/local/bin/hands /mnt/vroot/usr/local/bin/hands
  cat > /mnt/vroot/sbin/init <<'INIT'
#!/bin/sh
# A vault's first program: a hidden desktop, the accessibility bus, then the guest agent.
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm; mount -t devpts devpts /dev/pts; mount -t tmpfs tmpfs /run; mount -t tmpfs tmpfs /dev/shm; mount -t tmpfs tmpfs /tmp
hostname vault
export HOME=/root DISPLAY=:0 XDG_RUNTIME_DIR=/run/user0 GTK_MODULES=gail:atk-bridge PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
mkdir -p /run/dbus && dbus-daemon --system --fork --nopidfile 2>/dev/null
dbus-daemon --session --address=unix:path=/run/session-bus --fork --nopidfile
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/session-bus
Xvfb :0 -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 &
sleep 1
/usr/libexec/at-spi-bus-launcher --launch-immediately >/dev/null 2>&1 &
sleep 1
exec /usr/local/bin/parallax guest
INIT
  chmod 755 /mnt/vroot/sbin/init
  sync; umount /mnt/vroot && mv "$IMG.new" "$IMG"
  say "image built $(( $(date +%s)-T0 ))s $(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk"
fi
sleep 2
say "host: parallax $(systemctl is-active parallax) | vaults tool: $(px parallax_vaults '{"as":"test"}' | head -c 200)"
say "update done"
