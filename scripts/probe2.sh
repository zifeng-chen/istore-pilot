echo "=== firewall rules (name/target/port) ==="
uci show firewall | grep -E "rule\[[0-9]+\]\.(name|target|dest_port|src_dport|proto|family)="
echo
echo "=== firewall defaults ==="
uci show firewall | grep "defaults"
echo
echo "=== redirects ==="
uci show firewall | grep -E "redirect\[[0-9]+\]"
echo
echo "=== openclash enabled services ==="
uci get openclash.config.enable
/etc/init.d/openclash enabled && echo "boot-enabled"
echo
echo "=== lan dhcp lease count ==="
ubus call dhcp ipv4leases 2>/dev/null | grep -c '"mac"'
echo
echo "=== dnsmasq conf dir ==="
ls /etc/dnsmasq.d 2>/dev/null
