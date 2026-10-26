echo "=== nft chains for wan ==="
nft list chain inet fw4 input_wan 2>/dev/null | head -30
echo
echo "=== fw4 default ==="
nft list chain inet fw4 input 2>/dev/null | head -20
echo
echo "=== wan zone policy in uci ==="
uci show firewall | grep -E "zone\[1\]"
echo
echo "=== test from router to own wan ip ==="
wget -qO- -T 3 "http://[240e:3a0:5656:3039:78af:4be8:704a:c3f6]:9090/version" 2>&1 | head -c 200
echo
echo "=== ip rule / route back ==="
ip -6 route | head -10
