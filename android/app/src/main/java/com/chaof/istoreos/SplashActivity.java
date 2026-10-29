package com.chaof.istoreos;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.Nullable;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.util.Ui;

import org.json.JSONObject;

/**
 * 启动页：品牌展示 + 一次真实的连通性检查。
 *
 * 上一版的进度条其实是一条静态的线 —— 没有任何动画，停留时间是写死的 3 秒。
 * 这一版把进度分成三段，每段都有明确的触发条件：
 *
 *   0 → 30%   启动（固定 380ms）
 *   30 → 82%  正在连接路由器（拉一次 /api/v1/overview，慢速逼近表示在等）
 *   82 → 100% 请求回来（成功或失败）后收尾
 *
 * 三条约束：
 *   - 最短停 MIN_STAY_MS：不到 1.4s 就跳走，品牌页会来不及看清
 *   - 最长等 NET_TIMEOUT_MS：超时先把人放进界面，错误由首页自己显示
 *   - 请求的是首页首屏要用的那个接口，等于顺手预热缓存，进主页不用再转圈
 */
public class SplashActivity extends Activity {

    /** 品牌最短停留：低于这个时长会成为"闪一下"的观感 */
    private static final long MIN_STAY_MS = 1400L;
    /** 等路由器响应的上限：超了先放人进界面，不把人卡在启动页 */
    private static final long NET_TIMEOUT_MS = 2600L;
    /** 收尾动画时长 */
    private static final long OUTRO_MS = 420L;
    /** 拿到结果后走完剩下距离的时长：短一点，"满格 + 准备就绪"才看得清楚 */
    private static final long FINISH_MS = 240L;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final long createdAt = SystemClock.uptimeMillis();

    private View fill;
    private TextView tip;
    private ValueAnimator anim;

    /** 已经收尾（成功/失败/超时，只认第一次） */
    private boolean settled;
    /** 已经开始跳转，防止重复 startActivity */
    private boolean leaving;
    /** 请求失败过：收尾时不要用"准备就绪"盖掉错误提示 */
    private boolean errorShown;

    private final Runnable timeout = new Runnable() {
        @Override
        public void run() {
            settle();
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
        root.addView(logo, new LinearLayout.LayoutParams(
                Ui.dp(this, 88), Ui.dp(this, 88)));

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

        // 底部：一条会真正走的进度条 + 一行状态
        LinearLayout foot = new LinearLayout(this);
        foot.setOrientation(LinearLayout.VERTICAL);
        foot.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.topMargin = Ui.dp(this, 46);
        root.addView(foot, flp);

        LinearLayout track = new LinearLayout(this);
        GradientDrawable tbg = new GradientDrawable();
        tbg.setCornerRadius(Ui.dp(this, 2));
        tbg.setColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.22f));
        track.setBackground(tbg);
        foot.addView(track, new LinearLayout.LayoutParams(Ui.dp(this, 96), Ui.dp(this, 3)));

        // 填充块宽度撑满轨道，用 scaleX 表示进度：不触发 layout，60fps 很稳
        fill = new View(this);
        GradientDrawable fbg = new GradientDrawable();
        fbg.setCornerRadius(Ui.dp(this, 2));
        fbg.setColor(Ui.color(this, R.color.hero_fg));
        fill.setBackground(fbg);
        fill.setPivotX(0f);
        fill.setScaleX(0f);
        track.addView(fill, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        tip = new TextView(this);
        tip.setText("正在启动…");
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

        startFlow();
    }

    // ---------------------------------------------------------------- 进度

    private void startFlow() {
        // 第一段：固定推进到 30%，只表示"已经起来了"
        step("正在启动…", 0.30f, 380, new Runnable() {
            @Override
            public void run() {
                if (!Session.ready(SplashActivity.this)) {
                    // 没地址 / 令牌过期：MainActivity 自己会跳登录页，这里不用等网络
                    step("准备就绪", 1f, 520, SplashActivity.this::enter);
                    return;
                }
                probe();
            }
        });
    }

    private void probe() {
        tip.setText("正在连接路由器…");
        // 慢速逼近 82%：真实耗时不可知，停在"快好了"比乱跳诚实
        step(null, 0.82f, 900, null);
        handler.postDelayed(timeout, NET_TIMEOUT_MS);

        Api.get(this, "/api/v1/overview", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                settle();
            }

            @Override
            public void onError(String message) {
                if (!settled) {
                    // 连不上也让人进界面，首页会显示具体错误，比卡在这里好
                    errorShown = true;
                    tip.setText("路由器暂时没响应，先进入界面");
                }
                settle();
            }
        });
    }

    /** 收尾：只认第一次（请求成功、请求失败、超时三者抢跑） */
    private void settle() {
        if (settled) {
            return;
        }
        settled = true;
        handler.removeCallbacks(timeout);

        // 先快速走满，再让"满格 + 准备就绪"停到最短停留时间——
        // 比"到 100% 还写着正在连接"清楚，也不会出现 70% 就说准备好了
        if (!errorShown) {
            tip.setText("准备就绪");
        }
        step(null, 1f, FINISH_MS, this::enter);
    }

    /**
     * 推进到某个比例。text 为 null 表示保留当前文案。
     * 先摘监听再 cancel，否则 cancel 也会触发 onAnimationEnd，把收尾逻辑提前叫起来。
     */
    private void step(String text, float target, long duration, @Nullable final Runnable then) {
        if (text != null) {
            tip.setText(text);
        }
        if (anim != null) {
            anim.removeAllListeners();
            anim.cancel();
        }
        anim = ValueAnimator.ofFloat(fill.getScaleX(), target);
        anim.setDuration(duration);
        anim.setInterpolator(new DecelerateInterpolator());
        anim.addUpdateListener(new ValueAnimator.AnimatorUpdateListener() {
            @Override
            public void onAnimationUpdate(ValueAnimator a) {
                fill.setScaleX((float) a.getAnimatedValue());
            }
        });
        if (then != null) {
            anim.addListener(new AnimatorListenerAdapter() {
                @Override
                public void onAnimationEnd(Animator a) {
                    then.run();
                }
            });
        }
        anim.start();
    }

    // ---------------------------------------------------------------- 跳转

    /** 满足最短停留后才跳，避免"闪一下" */
    private void enter() {
        if (leaving) {
            return;
        }
        leaving = true;
        long wait = createdAt + MIN_STAY_MS - SystemClock.uptimeMillis();
        if (wait > 0) {
            handler.postDelayed(this::doEnter, wait);
        } else {
            doEnter();
        }
    }

    private void doEnter() {
        if (isFinishing()) {
            return;
        }
        startActivity(new Intent(this, MainActivity.class));
        overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out);
        finish();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (anim != null) {
            anim.removeAllListeners();
            anim.cancel();
        }
        super.onDestroy();
    }
}
