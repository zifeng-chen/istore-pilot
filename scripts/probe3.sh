echo "=== node ==="
which node; node -v 2>/dev/null
echo "=== python ==="
which python3 python; python3 -V 2>/dev/null
echo "=== busybox httpd ==="
ls -l /usr/sbin/uhttpd /usr/bin/cgi-bin 2>/dev/null
echo "=== cgi-bin ==="
ls /www/cgi-bin 2>/dev/null
echo "=== node procs ==="
ps w | grep node | grep -v grep
echo "=== free space on / ==="
df -h / | tail -1
echo "=== procd sample ==="
ls /etc/init.d/ | head -3
echo "=== shell ==="
echo $0; ls -l /bin/sh
