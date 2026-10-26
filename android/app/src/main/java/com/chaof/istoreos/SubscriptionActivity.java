package com.chaof.istoreos;

import android.os.Bundle;
import android.view.MenuItem;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 订阅管理（OpenClash 的「订阅」段）。
 *
 * 从代理页的「配置与节点」进来。代理页本身只留一行入口，这里才是增删改的地方：
 * 右上角「添加」，列表点一行改成编辑/更新/删除。
 *
 * 订阅改的是 uci 里的 subscription 段，改完必须「更新节点」才会真正拉一次；
 * 这条链路慢（要访问订阅服务器），所以每个动作都先给提示再发请求。
 */
public class SubscriptionActivity extends BaseActivity {

    private LinearLayout listBox;
    private TextView tvCount;
    private TextView tvEmpty;
    private String backendId = "";

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        backendId = getIntent().getStringExtra("backend");
        if (backendId == null) {
            backendId = "";
        }

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle("订阅管理");
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        // 右上角「添加」：用菜单项而不是自绘按钮，位置和系统习惯一致
        MenuItem add = toolbar.getMenu().add(0, 1, 0, "添加");
        add.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS);
        toolbar.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 1) {
                addSub();
                return true;
            }
            return false;
        });

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);
        scroller.setFillViewport(true);

        LinearLayout root = Ui.column(this);
        int pad = Ui.dp(this, 16);
        root.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 28));

        Ui.Card head = Ui.card(this);
        LinearLayout headRow = Ui.header(head, "订阅地址", "改完点「更新节点」才会重新拉取");
        tvCount = Ui.value(this, "—");
        headRow.addView(tvCount);

        tvEmpty = Ui.text(this, "", 12.5f, R.color.text_secondary);
        tvEmpty.setLineSpacing(Ui.dp(this, 2), 1f);
        LinearLayout.LayoutParams elp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        elp.topMargin = Ui.dp(this, 8);
        tvEmpty.setVisibility(android.view.View.GONE);
        head.addView(tvEmpty, elp);
        root.addView(head);

        Ui.Card list = Ui.card(this);
        Ui.header(list, "全部订阅", "");
        listBox = Ui.column(this);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        llp.topMargin = Ui.dp(this, 4);
        list.addView(listBox, llp);
        root.addView(list);

        scroller.addView(root);

        LinearLayout wrap = Ui.column(this);
        wrap.addView(toolbar);
        wrap.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(wrap);

        load();
    }

    // ---------------------------------------------------------------- 数据

    private void load() {
        if (backendId.isEmpty()) {
            tvEmpty.setVisibility(android.view.View.VISIBLE);
            tvEmpty.setText("两个代理后端都没在运行，订阅列表不可用。");
            tvCount.setText("");
            return;
        }
        Api.getFresh(this, "/api/v1/proxy/subscriptions?backend=" + backendId, new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                render(body.optJSONArray("items"));
            }

            @Override
            public void onError(String message) {
                if (isFinishing()) {
                    return;
                }
                listBox.removeAllViews();
                tvCount.setText("");
                tvEmpty.setVisibility(android.view.View.VISIBLE);
                tvEmpty.setText("读取失败：" + message);
            }
        });
    }

    private void render(JSONArray items) {
        listBox.removeAllViews();
        int n = items == null ? 0 : items.length();
        tvCount.setText(n == 0 ? "" : n + " 条");

        if (n == 0) {
            tvEmpty.setVisibility(android.view.View.VISIBLE);
            tvEmpty.setText("还没有订阅。点右上角「添加」把订阅链接粘进来。");
            return;
        }
        tvEmpty.setVisibility(android.view.View.GONE);

        for (int i = 0; i < n; i++) {
            final JSONObject item = items.optJSONObject(i);
            if (item == null) {
                continue;
            }
            if (i > 0) {
                listBox.addView(Ui.divider(this));
            }
            listBox.addView(subRow(item));
        }
    }

    private LinearLayout subRow(JSONObject item) {
        boolean enabled = item.optBoolean("enabled", true);
        String traffic = item.optString("traffic", "");
        String expired = item.optString("expired", "");

        LinearLayout line = Ui.row(this);
        line.setPadding(0, Ui.dp(this, 12), 0, Ui.dp(this, 12));
        line.setClickable(true);

        LinearLayout col = Ui.column(this);
        TextView name = Ui.text(this, item.optString("name", "未命名"), 15f, R.color.text_primary);
        name.setTypeface(android.graphics.Typeface.create(
                "sans-serif-medium", android.graphics.Typeface.NORMAL));
        name.setMaxLines(1);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(name);

        // 地址里带 token，只显示首尾，避免截图把订阅送人
        TextView url = Ui.text(this, item.optString("url_masked", ""), 11.5f, R.color.text_secondary);
        url.setMaxLines(1);
        url.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        url.setPadding(0, Ui.dp(this, 3), 0, 0);
        col.addView(url);

        String extra = "";
        if (!traffic.isEmpty()) {
            extra = "剩余 " + traffic;
        }
        if (!expired.isEmpty()) {
            extra = extra.isEmpty() ? "到期 " + expired : extra + " · 到期 " + expired;
        }
        if (!extra.isEmpty()) {
            TextView meta = Ui.text(this, extra, 11f, R.color.text_tertiary);
            meta.setPadding(0, Ui.dp(this, 3), 0, 0);
            col.addView(meta);
        }

        line.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        line.addView(Ui.pill(this, enabled ? "已启用" : "已停用",
                enabled ? R.color.primary : R.color.text_on_track));
        line.setOnClickListener(v -> openSub(item));
        return line;
    }

    // ---------------------------------------------------------------- 动作

    private void openSub(JSONObject item) {
        final String id = item.optString("id", "");
        if (id.isEmpty()) {
            return;
        }
        Sheet.actions(this, item.optString("name", ""),
                "订阅地址：\n" + item.optString("url", ""),
                new String[]{"更新节点", "修改名称 / 地址", "删除订阅"},
                index -> {
                    if (index == 0) {
                        refreshSub(id);
                    } else if (index == 1) {
                        editSub(item);
                    } else {
                        deleteSub(item);
                    }
                });
    }

    private void addSub() {
        Sheet.input(this, "添加订阅",
                "保存后点一次「更新节点」才会把节点拉进来。",
                new String[]{"名称::新订阅", "订阅地址:粘贴订阅链接:"},
                "添加", values -> {
                    String name = values[0].trim();
                    String url = values[1].trim();
                    if (url.isEmpty()) {
                        toast("订阅地址不能为空");
                        return false;
                    }
                    if (!url.startsWith("http://") && !url.startsWith("https://")) {
                        toast("地址要以 http:// 或 https:// 开头");
                        return false;
                    }
                    subAction("add", "", name, url, "添加中…");
                    return true;
                });
    }

    private void editSub(JSONObject item) {
        final String id = item.optString("id", "");
        String name = item.optString("name", "");
        String url = item.optString("url", "");
        Sheet.input(this, "修改订阅",
                "只改想改的那一项，另一项原样保留即可。",
                new String[]{"名称::" + name, "订阅地址::" + url},
                "保存", values -> {
                    String newName = values[0].trim();
                    String newUrl = values[1].trim();
                    if (newName.equals(name) && newUrl.equals(url)) {
                        toast("没有改动");
                        return false;
                    }
                    subAction("update", id, newName, newUrl, "保存中…");
                    return true;
                });
    }

    private void deleteSub(JSONObject item) {
        final String id = item.optString("id", "");
        Sheet.confirm(this, "删除订阅",
                "「" + item.optString("name", "") + "」会从路由器配置里移除。\n\n"
                        + "已经导入的节点不会跟着消失，需要的话在节点列表里单独处理。",
                "删除", true, () -> subAction("delete", id, "", "", "删除中…"));
    }

    private void refreshSub(String id) {
        subAction("refresh", id, "", "", "正在拉取订阅，节点会重新生成…");
    }

    /** 订阅的增删改走同一个接口，用 action 区分 */
    private void subAction(String action, String id, String name, String url, String hint) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", action);
            body.put("backend", backendId);
            if (!id.isEmpty()) {
                body.put("id", id);
            }
            if (!name.isEmpty()) {
                body.put("name", name);
            }
            if (!url.isEmpty()) {
                body.put("url", url);
            }
        } catch (Exception e) {
            return;
        }
        toast(hint);
        Api.postSlow(this, "/api/v1/proxy/subscriptions", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                if (!data.optBoolean("ok", true)) {
                    Sheet.message(SubscriptionActivity.this, "操作失败",
                            data.optString("error", "未知原因"));
                }
                load();
            }

            @Override
            public void onError(String message) {
                if (!isFinishing()) {
                    Sheet.message(SubscriptionActivity.this, "操作失败", message);
                }
            }
        });
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
