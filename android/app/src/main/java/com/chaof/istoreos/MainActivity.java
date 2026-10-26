package com.chaof.istoreos;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.activity.OnBackPressedCallback;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.fragment.app.Fragment;
import androidx.fragment.app.FragmentManager;
import androidx.fragment.app.FragmentTransaction;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.ui.LoginActivity;
import com.chaof.istoreos.ui.NetworkFragment;
import com.chaof.istoreos.ui.OverviewFragment;
import com.chaof.istoreos.ui.SecurityFragment;
import com.chaof.istoreos.ui.ProxyFragment;
import com.chaof.istoreos.ui.Refreshable;
import com.chaof.istoreos.ui.SettingsFragment;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.widget.NavBar;
import com.google.android.material.appbar.MaterialToolbar;

import java.util.LinkedHashMap;
import java.util.Map;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 主界面：底部五个页签 + 统一刷新节拍。
 *
 * 页面用 add/hide 而不是 replace —— 切回来时滚动位置和已加载的数据都还在，
 * 这是「不像原生」体感最直接的差别。
 */
public class MainActivity extends BaseActivity {

    private static final long TICK_MS = 3000L;

    /** 页签顺序就是底部栏从左到右的顺序 */
    private static final int[] TAB_IDS = {
            R.id.nav_overview, R.id.nav_network, R.id.nav_devices,
            R.id.nav_proxy, R.id.nav_settings,
    };
    // 「拦截」不再单独占一个页签：它和「设备」合成了一张一级页（SecurityFragment），
    // 让出位置给一直缺独立入口的「网络」。
    private static final String[] TAB_TITLES = {"概览", "网络", "设备", "代理", "设置"};
    private static final int[] TAB_ICONS = {
            R.drawable.ic_nav_overview, R.drawable.ic_nav_network,
            R.drawable.ic_nav_devices, R.drawable.ic_nav_proxy,
            R.drawable.ic_nav_settings,
    };

    private final Map<Integer, Fragment> pages = new LinkedHashMap<>();
    private final Handler ticker = new Handler(Looper.getMainLooper());

    private MaterialToolbar toolbar;
    private NavBar nav;
    private Fragment current;
    private int currentId = R.id.nav_overview;
    private boolean resumed = false;

    private final Runnable tickTask = new Runnable() {
        @Override
        public void run() {
            if (resumed && current instanceof Refreshable) {
                ((Refreshable) current).refresh(true);
            }
            ticker.postDelayed(this, TICK_MS);
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        if (!Session.ready(this)) {
            goLogin();
            return;
        }

        // 深浅色切换会让 Activity 重建，把当前页签带过来
        if (savedInstanceState != null) {
            currentId = savedInstanceState.getInt("tab", R.id.nav_overview);
        }

        setContentView(R.layout.activity_main);

        toolbar = findViewById(R.id.toolbar);

        // 自绘标签栏：不用 BottomNavigationView，选中态是「胶囊软垫 + 主色图标」，
        // 图标与文字的间距、字重、缩放动画全在自己手里
        nav = new NavBar(this, TAB_TITLES, TAB_ICONS, indexOf(currentId), index -> {
            show(TAB_IDS[index]);
        });
        android.widget.FrameLayout host = findViewById(R.id.navhost);
        host.addView(nav, new android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 62)));

        // 地址不进导航栏：iOS 的导航栏只放标题，地址在设置页里有
        toolbar.setAlpha(0f);

        Api.setAuthFailHandler(this::goLogin);

        // 默认停在概览；重建后由 FragmentManager 自行恢复页面状态
        int start = currentId;
        show(start);

        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (currentId != R.id.nav_overview) {
                    nav.select(indexOf(R.id.nav_overview), true);
                    show(R.id.nav_overview);
                } else {
                    finish();
                }
            }
        });
    }

    private static int indexOf(int id) {
        for (int i = 0; i < TAB_IDS.length; i++) {
            if (TAB_IDS[i] == id) {
                return i;
            }
        }
        return 0;
    }

    private void goLogin() {
        startActivity(new Intent(this, LoginActivity.class));
        finish();
    }

    private Fragment obtain(FragmentManager fm, int id) {
        Fragment f = pages.get(id);
        if (f != null) {
            return f;
        }
        // Activity 重建后 FragmentManager 里已有实例，先按 tag 找回来
        f = fm.findFragmentByTag(String.valueOf(id));
        if (f == null) {
            f = create(id);
        }
        pages.put(id, f);
        return f;
    }

    private Fragment create(int id) {
        if (id == R.id.nav_network) {
            return new NetworkFragment();
        }
        if (id == R.id.nav_devices) {
            return new SecurityFragment();
        }
        if (id == R.id.nav_proxy) {
            return new ProxyFragment();
        }
        if (id == R.id.nav_settings) {
            return new SettingsFragment();
        }
        return new OverviewFragment();
    }

    private void show(int id) {
        currentId = id;
        FragmentManager fm = getSupportFragmentManager();
        Fragment target = obtain(fm, id);
        if (target == current) {
            if (target instanceof Refreshable) {
                ((Refreshable) target).onShown();
            }
            return;
        }

        FragmentTransaction ft = fm.beginTransaction();
        for (Fragment f : fm.getFragments()) {
            if (f != target && !f.isHidden()) {
                ft.hide(f);
            }
        }
        if (!target.isAdded()) {
            ft.add(R.id.container, target, String.valueOf(id));
        } else {
            ft.show(target);
        }
        ft.commitAllowingStateLoss();

        current = target;
        toolbar.setTitle(titleOf(id));
        nav.select(indexOf(id), true);
        // 切页时先把导航栏标题收起来，等页面按自己的滚动位置再决定是否淡入
        toolbar.animate().cancel();
        toolbar.setAlpha(0f);
        if (target instanceof Refreshable) {
            ((Refreshable) target).onShown();
        }
    }

    @NonNull
    private String titleOf(int id) {
        if (id == R.id.nav_network) {
            return "网络";
        }
        if (id == R.id.nav_devices) {
            return "设备";
        }
        if (id == R.id.nav_proxy) {
            return "代理";
        }
        if (id == R.id.nav_settings) {
            return "设置";
        }
        return "概览";
    }

    @Override
    protected void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putInt("tab", currentId);
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        ticker.removeCallbacks(tickTask);
        ticker.postDelayed(tickTask, TICK_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        resumed = false;
        ticker.removeCallbacks(tickTask);
    }

    @Override
    protected void onDestroy() {
        ticker.removeCallbacks(tickTask);
        super.onDestroy();
    }
}
