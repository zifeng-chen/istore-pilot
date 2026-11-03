local fs    = require "nixio.fs"
local sys   = require "luci.sys"
local jsonc = require "luci.jsonc"

local CONF    = "/etc/istore-agent/config.json"
local INITIAL = "/etc/istore-agent/INITIAL_PASSWORD"

local m, s, o

m = Map("istore-agent", translate("iStore Pilot"),
	translate("iStore Pilot 的后端服务。手机 App 连的就是这里配置的端口，"
		.. "所有数据都在路由器本机处理，不经过任何第三方服务器。"))

-- ---------------------------------------------------------------- 运行状态
s = m:section(SimpleSection)
s.template = "istore_agent/state"

-- ---------------------------------------------------------------- 服务设置
s = m:section(TypedSection, "main", translate("服务设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("开机自启"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "port", translate("监听端口"))
o.datatype = "port"
o.default = "8443"
o.rmempty = false

o = s:option(Value, "bind", translate("监听地址"))
o.datatype = "ip4addr"
o.default = "192.168.100.1"
o.rmempty = false
o.description = translate("只填路由器局域网地址。"
	.. "不要填 0.0.0.0 —— 那会让面板同时监听所有接口，"
	.. "在 WAN 放通的情况下等于挂到公网。")

-- ---------------------------------------------------------------- 网页端访问范围
-- 默认只对内网开放：App 从公网（域名 + 端口）连进来时，网页端入口只会
-- 弹一句提示，LuCI 的登录页不会暴露出去。这里给它一个显式开关，
-- 并且必须手打「确认开启」四个字才生效 —— 这是个降低安全性的动作，
-- 不能点一下就过去。
s = m:section(NamedSection, "main", "main", translate("网页端访问范围"))
s.anonymous = false
s.addremove = false
s.description = translate("手机 App 里的网页端（LuCI 后台）默认只在家里的局域网可用。"
	.. "下面这一项决定要不要把同一个入口也开放给公网。")

o = s:option(Flag, "web_wan", translate("允许从公网打开网页端"))
o.default = "0"
o.rmempty = false
o.write = function() end
o.description = translate("打开后，从域名 + 端口连进来的手机也能直接进 LuCI 后台。"
	.. "<br/><b>打开之前请先看清风险：</b>"
	.. "<br/>1. 任何人扫到这个端口都会看到 LuCI 登录页，口令爆破的面一下变大；"
	.. "<br/>2. 这条链路是明文 HTTP（除非你在前面另外套了 HTTPS 反向代理），"
	.. "口令和会话 cookie 可能在路上被截；"
	.. "<br/>3. LuCI 是 root 权限后台，被攻破等于整台路由器失守 —— "
	.. "家里所有设备的流量都从它过。"
	.. "<br/>建议：确实需要在外面改路由器时再打开，用完立刻关掉。")

o = s:option(Value, "web_wan_confirm", translate("二次确认"))
o.rmempty = true
o.write = function() end
o.description = translate("要开启上面那一项，请在这里输入 <b>确认开启</b> 四个字。"
	.. "留空或输错都按「不开启」处理。")

-- ---------------------------------------------------------------- 登录密码
-- 以前这里只是一段「请到命令行执行 uci / python3 重置密码」的说明。
-- 现在改成表单：LuCI 本来就要求 root 登录，能进这个页面就有权改密码，
-- 所以不需要再问旧密码；改完写回 config.json 并重启服务。
s = m:section(NamedSection, "main", "main", translate("登录密码"))
s.anonymous = false
s.addremove = false
s.description = translate("手机 App 和网页端共用这一个密码。"
	.. "改完已经登录过的设备会掉线，需要用新密码重新登录。")

o = s:option(Value, "new_password", translate("新密码"))
o.password = true
o.rmempty = true
o.description = translate("至少 8 位。留空表示不改密码。")
o.write = function() end
o.validate = function(self, value)
	if value and #value > 0 and #value < 8 then
		return nil, translate("密码至少 8 位")
	end
	return value
end

o = s:option(Value, "confirm_password", translate("确认新密码"))
o.password = true
o.rmempty = true
o.write = function() end
o.validate = function(self, value)
	local a = self.map:formvalue("cbid." .. self.config .. ".main.new_password") or ""
	if value ~= a then
		return nil, translate("两次输入的密码不一致")
	end
	return value
end

o = s:option(Flag, "logout_all", translate("让已登录的设备立即掉线"))
o.default = "1"
o.rmempty = false
o.description = translate("会更换令牌签名密钥，所有已发出的登录令牌立刻失效。"
	.. "如果只是想换个密码、不想重新登录所有设备，把这一项取消。")
o.write = function() end

-- 真正干活的地方：CBI 的 on_after_save 钩子在字段校验之后、uci 提交之前调用
function m.on_after_save(self)
	local function field(name)
		return self:formvalue("cbid." .. self.config .. ".main." .. name) or ""
	end

	local pw   = field("new_password")
	local pw2  = field("confirm_password")
	local drop = field("logout_all") == "1"
	-- 网页端开关：勾了还要手打「确认开启」才算数
	local want = field("web_wan") == "1"
	local okw  = field("web_wan_confirm") == "确认开启"
	local webWan = want and okw

	local conf = {}
	local raw = fs.readfile(CONF)
	if raw then
		local ok, parsed = pcall(jsonc.parse, raw)
		if ok and type(parsed) == "table" then
			conf = parsed
		end
	end

	local changed = false
	local webChanged = false

	-- ① 网页端访问范围
	local oldWan = (conf.luci or {}).proxy_lan_only
	conf.luci = conf.luci or {}
	conf.luci.proxy_lan_only = not webWan
	if oldWan ~= conf.luci.proxy_lan_only then
		webChanged = true
		changed = true
	end

	-- ② 登录密码（没填 = 不动）
	local pwChanged = false
	if #pw > 0 and #pw >= 8 and pw == pw2 then
		conf.auth = conf.auth or {}
		conf.auth.password = pw
		if drop then
			-- 删掉签名密钥，config.py 下次加载会重新生成一个随机值，
			-- 旧令牌的 HMAC 校验随之全部失败 —— 这比维护一张吊销表简单可靠
			conf.auth.signing_key = nil
		end
		pwChanged = true
		changed = true
	end

	if not changed then
		if want and not okw then
			self.message = translate("没输入「确认开启」，网页端仍然只允许局域网访问。")
		end
		return
	end

	local out = jsonc.stringify(conf, true)
	if not out or not fs.writefile(CONF, out) then
		self.message = translate("写入 %s 失败，请检查目录权限。"):format(CONF)
		return
	end
	-- nixio 的 chmod 只认八进制字符串（传十进制 384 会报 "base out of range" 之类的错）
	fs.chmod(CONF, "0600")

	-- 初始密码文件只在安装时生成，用户自己设过密码后就没意义了
	if pwChanged and fs.access(INITIAL) then
		fs.remove(INITIAL)
	end

	-- 配置只在启动时读一次（config.py 有内存缓存），改完必须重启才生效
	sys.call("/etc/init.d/istore-agent restart >/dev/null 2>&1 &")

	if pwChanged and drop then
		self.message = translate("密码已更新，所有已登录的设备需要重新登录。")
	elseif pwChanged then
		self.message = translate("密码已更新。")
	end
	if webChanged then
		local tip = webWan
			and translate("网页端已对公网开放 —— 用完记得回来关掉。")
			or translate("网页端已恢复为仅局域网可用。")
		self.message = self.message and (self.message .. " " .. tip) or tip
	end
end

return m
