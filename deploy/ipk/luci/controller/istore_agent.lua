-- iStore Pilot（istore-agent）在 LuCI 里的入口。
--
-- 只留一个页面：服务状态 + 服务设置 + 登录密码 + 下载 App 弹窗。
-- 以前「下载 App」是独立页面，点一下会整页跳走，手机上看完还得按返回，
-- 现在改成状态页里的弹窗，所有东西都在一屏里。
--
-- 用传统的 lua controller：iStoreOS 24.10 带 luci-compat，兼容性最好，
-- 不用管新版 js 前端的 json 菜单格式。

module("luci.controller.istore_agent", package.seeall)

function index()
	if not nixio.fs.access("/usr/lib/istore-agent/run.py") then
		return
	end

	entry({"admin", "services", "istore_agent"},
		alias("admin", "services", "istore_agent", "status"),
		_("iStore Pilot"), 60).dependent = true

	entry({"admin", "services", "istore_agent", "status"},
		cbi("istore_agent/status"), _("服务设置"), 10).leaf = true

	-- 老书签兼容：App 下载页已经并进状态页的弹窗，这里直接跳回去
	entry({"admin", "services", "istore_agent", "app"},
		call("action_app")).leaf = true

	-- 不放在菜单里，只给状态卡上的按钮用
	entry({"admin", "services", "istore_agent", "restart"},
		call("action_restart")).leaf = true
end

function action_restart()
	luci.sys.call("/etc/init.d/istore-agent restart >/dev/null 2>&1")
	luci.http.redirect(luci.dispatcher.build_url("admin/services/istore_agent/status"))
end

function action_app()
	luci.http.redirect(luci.dispatcher.build_url("admin/services/istore_agent/status"))
end
