package com.chaof.istoreos;

import android.os.Bundle;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.ui.DevicesFragment;
import com.chaof.istoreos.util.Theme;
import com.google.android.material.appbar.MaterialToolbar;

/**
 * 设备清单（二级页）。
 *
 * 外壳和 MainActivity 长得很像，但没有底部页签 —— 用户是从一级页
 * 某个数字点进来的，回去的路径只有「返回」，多给一个页签反而会让人
 * 以为这是另一个主页面。
 *
 * 复用 DevicesFragment 而不是重写：搜索、应用流量、禁网、改名、唤醒
 * 这些动作已经调好了，二级页只是给它换了入口和初始筛选。
 */
public class SecurityDevicesActivity extends BaseActivity {

    public static final int MODE_ALL = 0;
    public static final int MODE_ONLINE = 1;
    public static final int MODE_OFFLINE = 2;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_sub);

        MaterialToolbar bar = findViewById(R.id.toolbar);
        bar.setNavigationOnClickListener(v -> finish());

        int mode = getIntent().getIntExtra("mode", MODE_ALL);

        if (savedInstanceState == null) {
            DevicesFragment f = new DevicesFragment();
            Bundle args = new Bundle();
            args.putInt("mode", mode);
            f.setArguments(args);
            getSupportFragmentManager().beginTransaction()
                    .replace(R.id.container, f, "devices")
                    .commit();
        }
    }
}
