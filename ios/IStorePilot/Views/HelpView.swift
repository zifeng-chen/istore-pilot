import SwiftUI

/// 使用帮助：从「路由器上还没有 Agent」讲到「四个页签怎么用」。
///
/// 为什么放在登录页：第一次用的人拿到的只有 App，地址填什么、口令是哪个、
/// 路由器上要不要先装点东西 —— 这些没人说就只能靠猜。放在设置里没用，
/// 因为卡住的正是还没登录进来的人。
///
/// 三端同一份文案与顺序：Android `ui/HelpActivity`、鸿蒙 `pages/HelpPage`。
/// 改这里记得同步那两处。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    installCard
                    loginCard
                    tabsCard
                    pitfallsCard
                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .contentColumn(560)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("使用帮助")
            .navigationBarTitleDisplayMode(.inline)
            .navBarChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
    }

    // MARK: - 一、装 Agent

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "一、先在路由器上装 Agent", trailing: "只需一次")

                step(1, "下载安装包",
                     "打开 github.com/zifeng-chen/istore-pilot/releases/latest ，"
                     + "按架构挑一个 .run：Intel / AMD 选 x86_64，ARM 选 arm64。")
                step(2, "传到路由器",
                     "scp，或者 LuCI 的「系统 → 文件传输」，放到 /tmp/ 下。")
                step(3, "先检查再安装",
                     "SSH 登录路由器，执行下面两行：")
                code("""
                sh /tmp/istore-pilot_<版本>_x86_64.run --check
                sh /tmp/istore-pilot_<版本>_x86_64.run
                """)
                step(4, "确认装好了",
                     "浏览器打开 http://路由器IP:8443 ，能看到登录框就成了 —— "
                     + "这个 8443 就是下面要填的端口。")

                note("24.10 及更早也可以用 .ipk（系统 → 软件包 → 上传软件包）；"
                     + "25.12 起包管理器换成了 apk，只能用 .run。两种不要同时装。")
            }
        }
    }

    // MARK: - 二、登录

    private var loginCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "二、回到这里登录")

                bullet("地址", "局域网填「路由器IP:8443」，例如 192.168.100.1:8443；"
                       + "外网填 DDNS 域名加端口。")
                bullet("密码", "与路由器后台、SSH 是同一个，也就是安装时设的 AGENT_PASSWORD。")

                Text("连不上，按这个顺序查：")
                    .font(F.body)
                    .foregroundStyle(C.textPrimary)
                    .padding(.top, 2)
                bullet("①", "点上面的「先测一下地址通不通」，看它报什么错")
                bullet("②", "Agent 在不在跑：/etc/init.d/istore-agent status")
                bullet("③", "8443 有没有被防火墙拦住")
                bullet("④", "外网访问要先在路由器上做端口映射")
            }
        }
    }

    // MARK: - 三、四个页签

    private var tabsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "三、App 里有什么")
                bullet("概览", "外网状态、实时上下行、网口速率、CPU / 内存 / 运行时长。")
                bullet("设备", "谁在线、各自跑了多少流量，点进去看连接明细；"
                       + "拦截（AdGuard Home）也在这里。")
                bullet("代理", "装 OpenClash / PassWall、切运行模式、选节点、管订阅。"
                       + "两个插件的配置各一套，不通用。")
                bullet("设置", "改服务器地址、配置备份、固件与软件包更新、重启。")
            }
        }
    }

    // MARK: - 四、坑

    private var pitfallsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "四、容易踩的几个点")
                bullet("·", "安装包一定放 /tmp —— 它是内存盘，重启自动清空，不占闪存。")
                bullet("·", "恢复配置备份后会问「保留 / 撤销」，90 秒内不点会自动退回原样。")
                bullet("·", "装代理插件时如果所有下载通道都不通，会问要不要改 hosts 加速。")
                bullet("·", "数据 3 秒自动刷新一次；等不及就下拉一下。")
            }
        }
    }

    // MARK: - 小零件

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(F.num(11.5, .semibold))
                .foregroundStyle(C.primary)
                .frame(width: 20, height: 20)
                .background(C.accentSoft)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(C.textPrimary)
                Text(detail)
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func bullet(_ mark: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark)
                .font(F.tiny)
                .foregroundStyle(C.primary)
                .frame(minWidth: 34, alignment: .leading)
            Text(text)
                .font(F.tiny)
                .foregroundStyle(C.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 命令行块：等宽 + 可选中的，用户能长按复制
    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(C.textPrimary)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(C.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }
}
