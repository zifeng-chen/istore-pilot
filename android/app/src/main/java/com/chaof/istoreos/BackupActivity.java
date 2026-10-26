package com.chaof.istoreos;

import android.content.Context;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Sheet;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * 配置备份。
 *
 * 备份的是整个 /etc/config，不含 Agent 自己的口令文件 —— 把口令打进备份，
 * 「恢复旧配置」就会变成「把口令泄露到旧备份里」。
 *
 * 恢复是危险的：它会把 network 一起铺回去，如果那份备份里的 LAN 地址
 * 和现在不同，手机拿的还是旧地址，连不回来就是个死局。所以恢复走的是
 * 与服务端同一条事务链路：铺完 60 秒内不确认就自动退回。
 */
public class BackupActivity extends BaseActivity {

    private LinearLayout listBox;
    private TextView tvCount;
    private TextView tvSize;
    private TextView tvEmpty;
    private TextView tvNote;
    private final SimpleDateFormat stamp =
            new SimpleDateFormat("MM-dd HH:mm", Locale.CHINA);

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_sub);

        MaterialToolbar bar = findViewById(R.id.toolbar);
        bar.setTitle("配置备份");
        bar.setAlpha(1f);
        bar.setNavigationOnClickListener(v -> finish());

        android.widget.FrameLayout holder = findViewById(R.id.container);
        holder.addView(buildUi(this));
        load();
    }

    private View buildUi(Context c) {
        ScrollView sc = new ScrollView(c);
        sc.setFillViewport(true);
        sc.setOverScrollMode(View.OVER_SCROLL_NEVER);

        LinearLayout root = Ui.column(c);
        int pad = Ui.dp(c, 16);
        root.setPadding(pad, Ui.dp(c, 10), pad, Ui.dp(c, 30));

        // ---- hero：现在有几份、占多少
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        hero.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 18));
        TextView kicker = Ui.heroNote(c, "本机备份", 0.8f);
        kicker.setTextSize(12f);
        hero.addView(kicker);

        tvCount = Ui.heroNumber(c, "—");
        tvCount.setPadding(0, Ui.dp(c, 8), 0, 0);
        hero.addView(tvCount);

        tvSize = Ui.heroNote(c, "正在读取…", 0.8f);
        tvSize.setTextSize(12f);
        tvSize.setPadding(0, Ui.dp(c, 4), 0, 0);
        hero.addView(tvSize);
        root.addView(hero);

        // ---- 说明
        tvNote = Ui.text(c, "备份只含 /etc/config，存在路由器本地，恢复后立刻生效，不用重启。",
                11.5f, R.color.text_secondary);
        tvNote.setLineSpacing(Ui.dp(c, 2), 1f);
        tvNote.setPadding(Ui.dp(c, 4), Ui.dp(c, 10), Ui.dp(c, 4), Ui.dp(c, 12));
        root.addView(tvNote);

        // ---- 列表
        Ui.Card card = Ui.card(c);
        card.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 10));
        Ui.cardTitle(c, card, Glyph.BOX, "备份列表", "点一项可以恢复或删除");

        listBox = Ui.column(c);
        card.addView(listBox);

        tvEmpty = Ui.text(c, "还没有备份。建议在动网络配置之前先建一份。",
                12.5f, R.color.text_secondary);
        tvEmpty.setLineSpacing(Ui.dp(c, 2), 1f);
        tvEmpty.setPadding(Ui.dp(c, 16), Ui.dp(c, 8), Ui.dp(c, 16), Ui.dp(c, 4));
        tvEmpty.setVisibility(View.GONE);
        card.addView(tvEmpty);
        root.addView(card);

        // ---- 新建
        TextView add = Ui.filled(c, "新建备份", R.color.primary, R.color.on_primary);
        add.setOnClickListener(v -> askCreate());
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        alp.topMargin = Ui.dp(c, 14);
        root.addView(add, alp);

        TextView tip = Ui.text(c, "恢复前会先自动存一份「恢复前自动备份」，所以恢复错了也还能退回来。",
                11.5f, R.color.text_secondary);
        tip.setLineSpacing(Ui.dp(c, 2), 1f);
        tip.setPadding(Ui.dp(c, 6), Ui.dp(c, 8), Ui.dp(c, 6), 0);
        root.addView(tip);

        sc.addView(root);
        return sc;
    }

    // ---------------------------------------------------------------- 取数

    private void load() {
        Api.get(this, "/api/v1/config/backups", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                render(body);
            }

            @Override
            public void onError(String message) {
                if (tvSize != null) {
                    tvSize.setText(message);
                }
            }
        });
    }

    private void render(JSONObject b) {
        JSONArray items = b.optJSONArray("items");
        int count = b.optInt("count", 0);
        tvCount.setText(count + " 份");
        tvSize.setText(count == 0 ? "还没有备份"
                : ("共占用 " + Fmt.bytes(b.optLong("bytes", 0))));

        listBox.removeAllViews();
        tvEmpty.setVisibility(count == 0 ? View.VISIBLE : View.GONE);

        if (items == null || items.length() == 0) {
            return;
        }
        Context c = this;
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null) {
                continue;
            }
            if (i > 0) {
                listBox.addView(Ui.hairline(c, 16));
            }
            listBox.addView(row(c, it));
        }
    }

    private View row(Context c, JSONObject it) {
        // Ui.listRow 返回的是竖向容器（带整行涟漪），横向排布要自己在里面再套一层，
        // 直接往竖向容器里塞 weight=1 的子项会被压成 0 宽
        LinearLayout wrap = Ui.listRow(c);

        LinearLayout line = Ui.row(c);
        wrap.addView(line, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout col = Ui.column(c);
        String name = it.optString("name", it.optString("id", ""));
        TextView t = Ui.text(c, name, 14.5f, R.color.text_primary);
        t.setSingleLine(true);
        t.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(t);

        StringBuilder sub = new StringBuilder();
        long ts = it.optLong("ts", 0);
        if (ts > 0) {
            sub.append(stamp.format(new Date(ts * 1000)));
        }
        int files = it.optInt("files", 0);
        if (files > 0) {
            if (sub.length() > 0) {
                sub.append("　·　");
            }
            sub.append(files).append(" 个文件");
        }
        if (it.optBoolean("auto", false)) {
            if (sub.length() > 0) {
                sub.append("　·　");
            }
            sub.append("自动");
        }
        if (sub.length() > 0) {
            TextView s = Ui.text(c, sub.toString(), 11.5f, R.color.text_secondary);
            s.setPadding(0, Ui.dp(c, 3), 0, 0);
            col.addView(s);
        }

        line.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView size = Ui.text(c, Fmt.bytes(it.optLong("size", 0)), 12.5f,
                R.color.text_secondary);
        size.setPadding(Ui.dp(c, 10), 0, 0, 0);
        line.addView(size);

        wrap.setOnClickListener(v -> openItem(it));
        return wrap;
    }

    // ---------------------------------------------------------------- 动作

    private void openItem(JSONObject it) {
        final String id = it.optString("id", "");
        final String name = it.optString("name", id);
        if (id.isEmpty()) {
            return;
        }
        Sheet.actions(this, name, "选一个操作", new String[]{"恢复这份配置", "删除"},
                idx -> {
                    if (idx == 0) {
                        askRestore(id, name);
                    } else {
                        askDelete(id, name);
                    }
                });
    }

    private void askRestore(String id, String name) {
        Sheet.confirm(this, "恢复「" + name + "」？",
                "会把 58 个配置文件整份覆盖回去，包括宽带、局域网、防火墙、代理设置。\n\n"
                        + "恢复完成后请在 60 秒内回到网络页点确认，否则路由器会自动退回恢复前的状态。",
                "恢复", true, () -> {
                    JSONObject body = new JSONObject();
                    try {
                        body.put("id", id);
                    } catch (Exception ignored) {
                        return;
                    }
                    Api.post(this, "/api/v1/config/backups/restore", body, new Cb() {
                        @Override
                        public void onData(JSONObject b, boolean fromCache) {
                            if (!b.optBoolean("ok", false)) {
                                Sheet.message(BackupActivity.this, "没有恢复",
                                        b.optString("error", "未知原因"));
                                return;
                            }
                            Sheet.message(BackupActivity.this, "已恢复",
                                    b.optString("message", "配置已铺回")
                                            + "\n\n" + b.optString("detail", "")
                                            + "\n\n请到网络页确认这次改动。");
                            load();
                        }

                        @Override
                        public void onError(String message) {
                            Sheet.message(BackupActivity.this, "没有恢复", message);
                        }
                    });
                });
    }

    private void askDelete(String id, String name) {
        Sheet.confirm(this, "删除「" + name + "」？", "删掉之后没法找回。", "删除", true, () -> {
            JSONObject body = new JSONObject();
            try {
                body.put("id", id);
            } catch (Exception ignored) {
                return;
            }
            Api.post(this, "/api/v1/config/backups/delete", body, new Cb() {
                @Override
                public void onData(JSONObject b, boolean fromCache) {
                    if (!b.optBoolean("ok", false)) {
                        Sheet.message(BackupActivity.this, "没有删除",
                                b.optString("error", "未知原因"));
                        return;
                    }
                    load();
                }

                @Override
                public void onError(String message) {
                    Sheet.message(BackupActivity.this, "没有删除", message);
                }
            });
        });
    }

    private void askCreate() {
        Sheet.input(this, "新建备份", "给这份备份起个名字，方便以后认出来",
                new String[]{"名称:例如 改防火墙前"}, "备份", values -> {
                    String text = values.length > 0 ? values[0] : "";
                    JSONObject body = new JSONObject();
                    try {
                        body.put("name", text == null ? "" : text.trim());
                    } catch (Exception ignored) {
                        return false;
                    }
                    Api.post(this, "/api/v1/config/backups", body, new Cb() {
                        @Override
                        public void onData(JSONObject b, boolean fromCache) {
                            if (!b.optBoolean("ok", false)) {
                                Sheet.message(BackupActivity.this, "没有备份成功",
                                        b.optString("error", "未知原因"));
                                return;
                            }
                            android.widget.Toast.makeText(BackupActivity.this,
                                    b.optString("message", "已备份"),
                                    android.widget.Toast.LENGTH_SHORT).show();
                            load();
                        }

                        @Override
                        public void onError(String message) {
                            Sheet.message(BackupActivity.this, "没有备份成功", message);
                        }
                    });
                    return true;
                });
    }
}
