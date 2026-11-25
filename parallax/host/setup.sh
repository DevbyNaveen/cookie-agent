#!/bin/bash
# Cookie's Parallax host: first boot only. Builds Parallax, installs Firecracker and a
# vault kernel, runs `parallax serve` on this machine only (no port reaches the
# internet), and sleeps the machine after 15 idle minutes.
say(){ echo "COOKIE $*" > /dev/console; logger -t cookie "$*"; }
export DEBIAN_FRONTEND=noninteractive HOME=/root
say "setup start $(date -u +%T)"
mkdir -p /var/lib/cookie /var/lib/parallax/images
touch /var/lib/cookie/active
apt-get update -qq && apt-get install -y -qq build-essential pkg-config curl >/dev/null 2>&1
snap install aws-cli --classic >/dev/null 2>&1
FV=v1.10.1
cd /root && curl -fsSL -o fc.tgz https://github.com/firecracker-microvm/firecracker/releases/download/$FV/firecracker-$FV-x86_64.tgz && tar xzf fc.tgz && install -m755 release-$FV-x86_64/firecracker-$FV-x86_64 /usr/local/bin/firecracker
K=$(curl -fsSL "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/v1.10/x86_64/vmlinux-&list-type=2" | grep -oP '(?<=<Key>)firecracker-ci/v1\.10/x86_64/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3}(?=</Key>)' | sort -V | tail -1)
curl -fsSL -o /var/lib/parallax/images/vmlinux "https://s3.amazonaws.com/spec.ccfc.min/$K"
say "firecracker $(firecracker --version 2>&1 | head -1) kernel $(basename "$K") kvm $(test -c /dev/kvm && echo yes || echo NO)"
curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1; . /root/.cargo/env
/snap/bin/aws s3 cp s3://cookie-parallax-558262519931-eun1/src/parallax.tgz /root/parallax.tgz --only-show-errors && tar xzf /root/parallax.tgz -C /root
cd /root/parallax && T0=$(date +%s) && cargo build --release -q > /root/build.log 2>&1
say "parallax build exit $? in $(( $(date +%s)-T0 )) s"
install -m755 target/release/parallax /usr/local/bin/parallax
cat > /etc/systemd/system/parallax.service <<'U'
[Unit]
Description=Parallax host (worlds and vaults), this machine only
After=network-online.target
[Service]
Environment=PARALLAX_HOME=/var/lib/parallax PARALLAX_BIND=127.0.0.1 HOME=/root
ExecStart=/usr/local/bin/parallax serve --port 4610
Restart=always
[Install]
WantedBy=multi-user.target
U
cat > /usr/local/bin/cookie-idle <<'I'
#!/bin/bash
# Sleep after 15 idle minutes. Busy: a Cookie command lately (it touches the file),
# an awake world, or a remote session.
A=/var/lib/cookie/active
[ -f "$A" ] || touch "$A"
awake=$(PARALLAX_HOME=/var/lib/parallax /usr/local/bin/parallax status 2>/dev/null | grep -o '"awake": *[0-9]*' | grep -o '[0-9]*$')
[ "${awake:-0}" -gt 0 ] && touch "$A"
pgrep -f ssm-session-worker >/dev/null && touch "$A"
age=$(( $(date +%s) - $(stat -c %Y "$A") ))
if [ "$age" -ge 900 ]; then logger -t cookie "idle ${age}s: sleeping"; systemctl poweroff; fi
I
chmod 755 /usr/local/bin/cookie-idle
cat > /etc/systemd/system/cookie-idle.service <<'U'
[Unit]
Description=Sleep this machine when Cookie hasn't needed it for 15 minutes
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cookie-idle
U
cat > /etc/systemd/system/cookie-idle.timer <<'U'
[Unit]
Description=Check every minute whether Cookie still needs this machine
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
U
cat > /etc/systemd/system/cookie-wake.service <<'U'
[Unit]
Description=A fresh wake counts as activity
[Service]
Type=oneshot
ExecStart=/usr/bin/touch /var/lib/cookie/active
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload && systemctl enable --now parallax.service cookie-wake.service cookie-idle.timer
sleep 3
touch /var/lib/cookie/active
say "parallax: $(systemctl is-active parallax) $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4610/ 2>/dev/null) | status $(PARALLAX_HOME=/var/lib/parallax parallax status 2>&1 | tr -d '\n' | cut -c1-200)"
say "setup done $(date -u +%T)"
