package com.chaof.istoreos;

import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 机器详情：这台软路由到底是什么硬件。
 *
 * 为什么要单独一页：软路由的 DMI 几乎全是 `Default string`，
 * 「产品名」这个字段读出来等于没读。真正能证明机器身份的，
 * 是 BIOS 版本、内存条的型号与频率、NVMe 型号、网卡芯片型号这些「扒不掉」的东西。
 * 所以这一页按硬件分类排：整机 → 处理器 → 内存 → 存储 → 网卡 → 系统 → 传感器。
 *
 * 温度与当前频率每 5 秒刷一次，其余是静态信息，后端有 30 秒缓存。
 */
public class HardwareActivity extends BaseActivity {

    private static final long TICK_MS = 5000L;

    private final Handler ticker = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            load(true);
            ticker.postDelayed(this, TICK_MS);
        }
    };

    private LinearLayout root;
    private LinearLayout heroBox;
    private LinearLayout sensorBox;
    private TextView tvCpuMhz;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle("机器信息");
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);
        scroller.setFillViewport(true);

        root = Ui.column(this);
        int pad = Ui.dp(this, 16);
        root.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 28));

        scroller.addView(root);

        LinearLayout page = Ui.column(this);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        page.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(page);

        load(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        ticker.removeCallbacks(tick);
        ticker.postDelayed(tick, TICK_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        ticker.removeCallbacks(tick);
    }

    @Override
    protected void onDestroy() {
        ticker.removeCallbacks(tick);
        super.onDestroy();
    }

    private void load(boolean quiet) {
        Api.get(this, "/api/v1/system/hardware", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isFinishing()) {
                    render(body);
                }
            }

            @Override
            public void onError(String message) {
                if (isFinishing()) {
                    return;
                }
                if (root.getChildCount() == 0) {
                    TextView t = Ui.text(HardwareActivity.this, "读取失败：" + message,
                            13f, R.color.danger);
                    root.addView(t);
                }
            }
        });
    }

    private void render(JSONObject b) {
        root.removeAllViews();

        JSONObject sys = b.optJSONObject("system");
        JSONObject machine = b.optJSONObject("machine");
        JSONObject cpu = b.optJSONObject("cpu");
        JSONObject mem = b.optJSONObject("memory");
        JSONObject sensors = b.optJSONObject("sensors");

        // ------------------------------------------------------------ 顶部
        Ui.Card hero = Ui.gradient(this, R.color.hero_from, R.color.hero_to);
        heroBox = Ui.column(this);
        hero.addView(heroBox);

        TextView name = Ui.heroTitle(this, sys == null ? "路由器"
                : Fmt.orDash(sys.optString("hostname", "")));
        heroBox.addView(name);

        TextView sub = Ui.heroNote(this, sys == null ? "" :
                (sys.optString("distro", "") + " " + sys.optString("version", "")
                        + "　·　内核 " + sys.optString("kernel", "")), 0.8f);
        sub.setPadding(0, Ui.dp(this, 5), 0, 0);
        heroBox.addView(sub);

        String vendorGuess = machine == null ? "" : machine.optString("vendor_guess", "");
        if (!vendorGuess.isEmpty()) {
            TextView g = Ui.heroNote(this, "整机厂商：" + vendorGuess, 0.9f);
            g.setPadding(0, Ui.dp(this, 10), 0, 0);
            heroBox.addView(g);
        }

        View hair = new View(this);
        hair.setBackgroundColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(this, 0.7f)));
        hlp.topMargin = Ui.dp(this, 14);
        hero.addView(hair, hlp);

        LinearLayout nums = Ui.row(this);
        nums.setPadding(0, Ui.dp(this, 12), 0, 0);
        heroStat(nums, "已运行", Fmt.dur(sys == null ? 0 : sys.optLong("uptime", 0)));
        heroStat(nums, "架构", sys == null ? "—" : sys.optString("arch", "—"));
        heroStat(nums, "内存", mem == null ? "—" : Fmt.bytes(mem.optLong("total", 0)));
        hero.addView(nums);
        root.addView(hero);

        // ------------------------------------------------------------ 处理器
        if (cpu != null) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "处理器", cpu.optString("arch", ""));
            Ui.kv(card, "型号", stripIntel(cpu.optString("model", "")));
            int cores = cpu.optInt("cores", 0);
            int threads = cpu.optInt("threads", 0);
            Ui.kv(card, "核心 / 线程", cores + " 核 " + (threads > cores
                    ? threads + " 线程" : ""));
            String freq = "";
            if (cpu.optInt("base_mhz", 0) > 0) {
                freq = cpu.optInt("base_mhz") + " MHz 基础";
            }
            if (cpu.optInt("max_mhz", 0) > 0) {
                freq += (freq.isEmpty() ? "" : "　·　") + cpu.optInt("max_mhz") + " MHz 最高";
            }
            if (!freq.isEmpty()) {
                Ui.kv(card, "频率", freq);
            }
            tvCpuMhz = Ui.kv(card, "当前频率", cpu.optInt("mhz", 0) + " MHz");
            if (!cpu.optString("cache", "").isEmpty()) {
                Ui.kv(card, "末级缓存", cpu.optString("cache", ""));
            }
            StringBuilder feat = new StringBuilder();
            if (cpu.optBoolean("vt", false)) {
                feat.append("硬件虚拟化");
            }
            if (cpu.optBoolean("aes", false)) {
                feat.append(feat.length() > 0 ? "　·　" : "").append("AES 指令集");
            }
            if (feat.length() > 0) {
                Ui.kv(card, "特性", feat.toString());
            }
            root.addView(card);
        }

        // ------------------------------------------------------------ 内存
        if (mem != null) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "内存", Fmt.bytes(mem.optLong("used", 0)) + " / "
                    + Fmt.bytes(mem.optLong("total", 0)) + " 已用");
            JSONArray mods = mem.optJSONArray("modules");
            if (mods == null || mods.length() == 0) {
                Ui.kv(card, "容量", Fmt.bytes(mem.optLong("total", 0)));
                TextView t = Ui.text(this, "BIOS 未提供内存条明细，只能读到总容量。",
                        12f, R.color.text_secondary);
                t.setPadding(0, Ui.dp(this, 8), 0, 0);
                card.addView(t);
            } else {
                for (int i = 0; i < mods.length(); i++) {
                    JSONObject m = mods.optJSONObject(i);
                    if (m == null) {
                        continue;
                    }
                    if (i > 0) {
                        card.addView(Ui.divider(this));
                    }
                    String spec = m.optString("size", "");
                    if (!m.optString("type", "").isEmpty()) {
                        spec += " " + m.optString("type");
                    }
                    if (m.optInt("speed", 0) > 0) {
                        spec += "-" + m.optInt("speed");
                    }
                    LinearLayout line = Ui.row(this);
                    line.setPadding(0, Ui.dp(this, 10), 0, 0);
                    TextView title = Ui.text(this, spec, 16f, R.color.text_primary);
                    title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                    line.addView(title, new LinearLayout.LayoutParams(0,
                            ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
                    TextView badge = Ui.pill(this, m.optString("form", "内存"),
                            R.color.primary);
                    line.addView(badge);
                    card.addView(line);

                    StringBuilder meta = new StringBuilder();
                    if (!m.optString("vendor", "").isEmpty()) {
                        meta.append(m.optString("vendor"));
                    }
                    if (!m.optString("part", "").isEmpty()) {
                        meta.append(meta.length() > 0 ? "　·　" : "")
                                .append(m.optString("part"));
                    }
                    if (!m.optString("slot", "").isEmpty()) {
                        meta.append(meta.length() > 0 ? "\n" : "")
                                .append(m.optString("slot"));
                    }
                    TextView mm = Ui.text(this, meta.toString(), 11.5f, R.color.text_secondary);
                    mm.setLineSpacing(Ui.dp(this, 2), 1f);
                    mm.setPadding(0, Ui.dp(this, 4), 0, 0);
                    card.addView(mm);
                }
            }
            root.addView(card);
        }

        // ------------------------------------------------------------ 存储
        JSONArray disks = b.optJSONArray("disks");
        if (disks != null && disks.length() > 0) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "存储", disks.length() + " 块磁盘");
            for (int i = 0; i < disks.length(); i++) {
                JSONObject d = disks.optJSONObject(i);
                if (d == null) {
                    continue;
                }
                if (i > 0) {
                    card.addView(Ui.divider(this));
                }
                Ui.kv(card, d.optString("transport", "磁盘") + " · " + d.optString("name", ""),
                        d.optString("size_text", "—"));
                Ui.kv(card, "型号", d.optString("model", "—"));
                if (d.optDouble("temp", 0) > 0) {
                    Ui.kv(card, "温度", Fmt.temp(d.optDouble("temp", 0)));
                }
            }
            root.addView(card);
        }

        // ------------------------------------------------------------ 网卡
        JSONArray nics = b.optJSONArray("nics");
        if (nics != null && nics.length() > 0) {
            Ui.Card card = Ui.card(this);
            int upCount = 0;
            for (int i = 0; i < nics.length(); i++) {
                JSONObject n = nics.optJSONObject(i);
                if (n != null && n.optBoolean("up", false)) {
                    upCount++;
                }
            }
            Ui.header(card, "网卡", nics.length() + " 个物理口，" + upCount + " 个已连接");

            for (int i = 0; i < nics.length(); i++) {
                JSONObject n = nics.optJSONObject(i);
                if (n == null) {
                    continue;
                }
                if (i > 0) {
                    card.addView(Ui.divider(this));
                }
                boolean up = n.optBoolean("up", false);

                LinearLayout line = Ui.row(this);
                line.setPadding(0, Ui.dp(this, 2), 0, 0);
                TextView nm = Ui.text(this, n.optString("name", ""), 15f,
                        up ? R.color.text_primary : R.color.text_secondary);
                nm.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                line.addView(nm, new LinearLayout.LayoutParams(Ui.dp(this, 56),
                        ViewGroup.LayoutParams.WRAP_CONTENT));

                TextView chip = Ui.text(this, Fmt.orDash(n.optString("chip", "")),
                        13f, R.color.text_secondary);
                chip.setSingleLine(true);
                chip.setEllipsize(android.text.TextUtils.TruncateAt.END);
                line.addView(chip, new LinearLayout.LayoutParams(0,
                        ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

                int speed = n.optInt("speed_mbps", 0);
                TextView sp = Ui.text(this, up ? Fmt.speed(speed) : "未连接",
                        13f, up ? R.color.primary : R.color.text_tertiary);
                sp.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                sp.setGravity(Gravity.END);
                line.addView(sp);
                card.addView(line);

                JSONArray addrs = n.optJSONArray("addrs");
                StringBuilder extra = new StringBuilder(n.optString("mac", ""));
                if (addrs != null && addrs.length() > 0) {
                    for (int j = 0; j < addrs.length(); j++) {
                        extra.append("\n").append(addrs.optString(j, ""));
                    }
                }
                TextView addr = Ui.text(this, extra.toString(), 11f, R.color.text_secondary);
                addr.setLineSpacing(Ui.dp(this, 2), 1f);
                addr.setPadding(Ui.dp(this, 56), Ui.dp(this, 3), 0, Ui.dp(this, 3));
                card.addView(addr);
            }
            root.addView(card);
        }

        // ------------------------------------------------------------ 温度
        if (sensors != null) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "温度", "实时");
            sensorBox = Ui.column(this);
            card.addView(sensorBox);
            renderSensors(sensors);
            root.addView(card);
        }

        // ------------------------------------------------------------ 系统
        if (sys != null) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "系统", "");
            Ui.kv(card, "发行版", sys.optString("description", "—"));
            Ui.kv(card, "内核", sys.optString("kernel", "—"));
            Ui.kv(card, "架构 / 目标", sys.optString("arch", "") + "　"
                    + sys.optString("target", ""));
            Ui.kv(card, "启动时间", time(sys.optLong("boot", 0)));
            Ui.kv(card, "已运行", Fmt.dur(sys.optLong("uptime", 0)));
            Ui.kv(card, "Agent", "v" + sys.optString("agent", "—"));
            Ui.kv(card, "Python", sys.optString("python", "—"));
            root.addView(card);
        }

        // ------------------------------------------------------------ 整机
        if (machine != null) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "整机与固件", "");
            String note = machine.optString("note", "");
            if (!note.isEmpty()) {
                TextView t = Ui.text(this, note, 12.5f, R.color.warn);
                t.setLineSpacing(Ui.dp(this, 2), 1f);
                t.setPadding(0, 0, 0, Ui.dp(this, 6));
                card.addView(t);
            }
            addIf(card, "厂商", machine.optString("vendor", ""));
            addIf(card, "型号", machine.optString("product", ""));
            addIf(card, "主板", join(machine.optString("board_vendor", ""),
                    machine.optString("board", "")));
            addIf(card, "BIOS 厂商", machine.optString("bios_vendor", ""));
            addIf(card, "BIOS 版本", machine.optString("bios_version", ""));
            String date = machine.optString("bios_date", "");
            if (!date.isEmpty()) {
                try {
                    SimpleDateFormat in = new SimpleDateFormat("MM/dd/yyyy", Locale.US);
                    Date d = in.parse(date);
                    if (d != null) {
                        date = new SimpleDateFormat("yyyy-MM-dd", Locale.US).format(d);
                    }
                } catch (Exception ignored) {
                    // 保持原样
                }
            }
            addIf(card, "BIOS 日期", date);
            addIf(card, "机箱", machine.optString("chassis", ""));
            root.addView(card);
        }

        // ------------------------------------------------------------ PCI
        JSONArray pci = b.optJSONArray("pci");
        if (pci != null && pci.length() > 0) {
            Ui.Card card = Ui.card(this);
            Ui.header(card, "PCI 设备", "共 " + pci.length() + " 个");
            LinearLayout list = Ui.column(this);
            list.setPadding(0, Ui.dp(this, 8), 0, 0);
            card.addView(list);

            // 默认只列前 8 条：一屏塞 25 条总线设备没有意义，想看再展开
            final int first = Math.min(8, pci.length());
            for (int i = 0; i < first; i++) {
                addPci(list, pci.optJSONObject(i));
            }
            if (pci.length() > first) {
                LinearLayout rest = Ui.column(this);
                rest.setVisibility(android.view.View.GONE);
                for (int i = first; i < pci.length(); i++) {
                    addPci(rest, pci.optJSONObject(i));
                }
                card.addView(rest);

                TextView more = Ui.text(this, "展开全部 " + pci.length() + " 项",
                        13.5f, R.color.primary);
                more.setGravity(Gravity.CENTER);
                more.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                more.setPadding(0, Ui.dp(this, 10), 0, 0);
                final boolean[] open = {false};
                more.setOnClickListener(v -> {
                    open[0] = !open[0];
                    rest.setVisibility(open[0] ? android.view.View.VISIBLE
                            : android.view.View.GONE);
                    more.setText(open[0] ? "收起" : "展开全部 " + pci.length() + " 项");
                });
                card.addView(more);
            }
            root.addView(card);
        }
    }

    private void renderSensors(JSONObject sensors) {
        if (sensorBox == null) {
            return;
        }
        sensorBox.removeAllViews();
        double cpuTemp = sensors.optDouble("cpu", 0);
        double nvme = sensors.optDouble("nvme", 0);

        LinearLayout row = Ui.row(this);
        row.setPadding(0, Ui.dp(this, 10), 0, 0);
        tempBlock(row, "CPU 封装", cpuTemp);
        if (nvme > 0) {
            tempBlock(row, "固态硬盘", nvme);
        }
        sensorBox.addView(row);

        JSONArray cores = sensors.optJSONArray("cores");
        if (cores != null && cores.length() > 0) {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < cores.length(); i++) {
                JSONObject o = cores.optJSONObject(i);
                if (o == null) {
                    continue;
                }
                if (sb.length() > 0) {
                    sb.append("　");
                }
                sb.append(o.optString("label", "")).append(" ")
                        .append(Fmt.temp(o.optDouble("celsius", 0)));
            }
            TextView t = Ui.text(this, sb.toString(), 11.5f, R.color.text_secondary);
            t.setLineSpacing(Ui.dp(this, 3), 1f);
            t.setPadding(0, Ui.dp(this, 10), 0, 0);
            sensorBox.addView(t);
        }
    }

    private void tempBlock(LinearLayout parent, String label, double value) {
        LinearLayout box = Ui.column(this);
        TextView v = Ui.text(this, Fmt.temp(value), 24f, tempColor(value));
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setIncludeFontPadding(false);
        box.addView(v);
        TextView l = Ui.text(this, label, 12f, R.color.text_secondary);
        l.setPadding(0, Ui.dp(this, 4), 0, 0);
        box.addView(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        parent.addView(box, lp);
    }

    private int tempColor(double c) {
        if (c >= 80) {
            return R.color.danger;
        }
        if (c >= 65) {
            return R.color.warn;
        }
        return R.color.text_primary;
    }

    private void addPci(LinearLayout parent, JSONObject o) {
        if (o == null) {
            return;
        }
        LinearLayout line = Ui.row(this);
        line.setPadding(0, Ui.dp(this, 5), 0, Ui.dp(this, 5));
        TextView slot = Ui.text(this, o.optString("slot", ""), 11f, R.color.text_tertiary);
        slot.setTypeface(Typeface.create("monospace", Typeface.NORMAL));
        line.addView(slot, new LinearLayout.LayoutParams(Ui.dp(this, 74),
                ViewGroup.LayoutParams.WRAP_CONTENT));
        TextView name = Ui.text(this, o.optString("name", ""), 12f, R.color.text_secondary);
        name.setSingleLine(true);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        line.addView(name, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        parent.addView(line);
    }

    private void addIf(LinearLayout card, String key, String value) {
        if (value != null && !value.isEmpty()) {
            Ui.kv(card, key, value);
        }
    }

    private void heroStat(LinearLayout parent, String label, String value) {
        LinearLayout box = Ui.column(this);
        TextView v = Ui.heroNumber(this, value);
        v.setTextSize(17f);
        v.setLetterSpacing(0f);
        box.addView(v);
        TextView l = Ui.heroNote(this, label, 0.86f);
        l.setPadding(0, Ui.dp(this, 5), 0, 0);
        box.addView(l);
        parent.addView(box, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
    }

    /** "Intel(R) Pentium(R) Gold 8505" → "Intel Pentium Gold 8505"，去掉满屏的 ® */
    private static String stripIntel(String s) {
        return s == null ? "" : s.replace("(R)", "").replace("(TM)", "")
                .replaceAll("\\s+", " ").trim();
    }

    private static String join(String a, String b) {
        if (a == null || a.isEmpty()) {
            return b == null ? "" : b;
        }
        if (b == null || b.isEmpty()) {
            return a;
        }
        return a + " " + b;
    }

    private static String time(long ts) {
        if (ts <= 0) {
            return "—";
        }
        return new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(new Date(ts * 1000));
    }
}
