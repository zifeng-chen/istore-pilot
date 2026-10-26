echo "=== system info ==="
ubus call system info
echo
echo "=== ip -j addr (是否支持 json) ==="
ip -j addr 2>&1 | head -c 300
echo
echo
echo "=== interface dump (wan) ==="
ubus call network.interface.wan status | head -30
echo
echo "=== dhcp leases ==="
ubus call dhcp ipv4leases 2>&1 | head -c 600
echo
echo
echo "=== service list sample ==="
ubus call service list '{"name":"openclash"}' 2>&1 | head -c 400
