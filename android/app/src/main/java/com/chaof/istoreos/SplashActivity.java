package com.chaof.istoreos;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.Nullable;

import com.chaof.istoreos.util.Ui;

/**
 * 启动页：3 秒的品牌时间。
 *
 * 之前点开 App 是先闪一下白底再进首页，什么也没说。现在停 3 秒把
 * 「这是什么 App」讲清楚 —— 深绿渐变（和首页 hero 同一套色）、
 * 图标落位 + 名字淡入，底部一行「正在读取路由器…」。
 *
 * 为什么不做跳过：3 秒是刻意的，够看清但不至于烦。真正的加载
 * （登录态、主机名）都发生在 MainActivity 里，这里不占那点时间。
 */
public class SplashActivity extends Activity {

    private static final long STAY_MS = 3000L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable go = new Runnable() {
        @Override
        public void run() {
            startActivity(new Intent(SplashActivity.this, MainActivity.class));
            // 淡入淡出：启动页和首页之间不要出现一眼白底
            overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out);
            finish();
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // 状态栏/导航栏跟着卡片走：默认是白底，会在深绿上面留一条白边
        getWindow().setStatusBarColor(Ui.color(this, R.color.hero_from));
        getWindow().setNavigationBarColor(Ui.color(this, R.color.hero_from));

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[]{Ui.color(this, R.color.hero_from), Ui.color(this, R.color.hero_to)});
        root.setBackground(bg);

        ImageView logo = new ImageView(this);
        logo.setImageResource(R.mipmap.ic_launcher);
        logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                Ui.dp(this, 88), Ui.dp(this, 88));
        root.addView(logo, llp);

        TextView name = new TextView(this);
        name.setText("iStore Pilot");
        name.setTextSize(27f);
        name.setTextColor(Ui.color(this, R.color.hero_fg));
        name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        name.setLetterSpacing(0.01f);
        name.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        nlp.topMargin = Ui.dp(this, 18);
        root.addView(name, nlp);

        TextView tagline = new TextView(this);
        tagline.setText("家庭网络，一屏看完");
        tagline.setTextSize(13f);
        tagline.setTextColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.72f));
        tagline.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.topMargin = Ui.dp(this, 8);
        root.addView(tagline, tlp);

        // 底部：一行提示 + 一条会自己走的细线（纯装饰，不代表真实进度）
        LinearLayout foot = new LinearLayout(this);
        foot.setOrientation(LinearLayout.VERTICAL);
        foot.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.topMargin = Ui.dp(this, 46);
        root.addView(foot, flp);

        View line = new View(this);
        GradientDrawable lbg = new GradientDrawable();
        lbg.setCornerRadius(Ui.dp(this, 2));
        lbg.setColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.22f));
        line.setBackground(lbg);
        foot.addView(line, new LinearLayout.LayoutParams(Ui.dp(this, 96), Ui.dp(this, 3)));

        TextView tip = new TextView(this);
        tip.setText("正在读取路由器…");
        tip.setTextSize(11.5f);
        tip.setTextColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.6f));
        LinearLayout.LayoutParams tiplp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tiplp.topMargin = Ui.dp(this, 10);
        foot.addView(tip, tiplp);

        setContentView(root);

        // 入场：图标从 0.86 放大到 1，名字晚 120ms 淡入 —— 比整块一起出现有节奏
        logo.setAlpha(0f);
        logo.setScaleX(0.86f);
        logo.setScaleY(0.86f);
        logo.animate().alpha(1f).scaleX(1f).scaleY(1f)
                .setDuration(420).setInterpolator(new DecelerateInterpolator()).start();

        name.setAlpha(0f);
        tagline.setAlpha(0f);
        name.animate().alpha(1f).setStartDelay(120).setDuration(380).start();
        tagline.animate().alpha(1f).setStartDelay(220).setDuration(380).start();

        handler.postDelayed(go, STAY_MS);
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(go);
        super.onDestroy();
    }
}
