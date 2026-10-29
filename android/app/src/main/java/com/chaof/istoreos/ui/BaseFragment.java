package com.chaof.istoreos.ui;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.widget.NestedScrollView;
import androidx.dynamicanimation.animation.DynamicAnimation;
import androidx.dynamicanimation.animation.SpringAnimation;
import androidx.dynamicanimation.animation.SpringForce;
import androidx.fragment.app.Fragment;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Skeleton;

/**
 * 所有页面的底板：下拉刷新 + 可滚动容器 + 顶部提示条。
 *
 * 子类只在 build() 里搭静态骨架，在 load() 里取数并回填，
 * 不用管刷新节流、生命周期、下拉动画这些重复逻辑。
 *
 * iOS 的大标题行为也在这里统一处理：大标题是内容的一部分，会随滚动滚走；
 * 滚出视野后导航栏的小标题淡入补位。
 */
public abstract class BaseFragment extends Fragment implements Refreshable {

    protected SwipeRefreshLayout swipe;
    protected LinearLayout content;
    /** 真实内容的容器。build() 的目标 —— 骨架屏占位时它整体隐藏 */
    protected LinearLayout body;
    protected TextView banner;

    private NestedScrollView scroller;
    private boolean navTitleShown = false;
    /** 页面大标题：滚动时要跟着淡出，否则滚到一半会露出被裁掉半截的字 */
    private TextView bigTitle;
    private View skeleton;
    private boolean loaded = false;
    /** 骨架出现的时刻（uptimeMillis），用来算「至少显示多久」 */
    private long skeletonAt = 0L;

    private long lastLoad = 0L;

    @Nullable
    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, @Nullable ViewGroup container,
                             @Nullable Bundle savedInstanceState) {
        Context c = requireContext();

        swipe = new SwipeRefreshLayout(c);
        swipe.setColorSchemeColors(c.getColor(R.color.primary));
        swipe.setProgressBackgroundColorSchemeColor(c.getColor(R.color.surface));

        scroller = new NestedScrollView(c);
        scroller.setFillViewport(true);
        scroller.setClipToPadding(false);
        scroller.setOverScrollMode(View.OVER_SCROLL_NEVER);

        content = Ui.column(c);
        int pad = Ui.dp(c, 16);
        content.setPadding(pad, Ui.dp(c, 0), pad, Ui.dp(c, 30));

        banner = Ui.text(c, "", 12.5f, R.color.warn);
        int h = Ui.dp(c, 10);
        banner.setPadding(Ui.dp(c, 12), h, Ui.dp(c, 12), h);
        banner.setVisibility(View.GONE);
        banner.setLineSpacing(Ui.dp(c, 2), 1f);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 14));
        bg.setColor(0x1AFFB454);
        banner.setBackground(bg);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.bottomMargin = Ui.dp(c, 12);
        banner.setLayoutParams(blp);
        content.addView(banner);

        // 大标题放在内容最上面，跟着一起滚
        String title = title();
        if (title != null && !title.isEmpty()) {
            TextView big = Ui.largeTitle(c, title);
            LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            tlp.topMargin = Ui.dp(c, 6);
            tlp.bottomMargin = Ui.dp(c, 16);
            tlp.leftMargin = Ui.dp(c, 2);
            big.setLayoutParams(tlp);
            // 插到最前面：提示条要出现在大标题下面，而不是盖在标题上面
            content.addView(big, 0);
            bigTitle = big;
        }

        // 真实内容统一装进 body，而不是直接挂在 content 上。
        // 这样骨架屏期间可以把整块 body 收起来（GONE，不占位），
        // 数据到了再整块放出来做入场动画 —— 不用逐个卡片去开关可见性。
        body = Ui.column(c);
        content.addView(body);
        build(body);
        installSkeleton(c);

        scroller.addView(content);        scroller.setOnScrollChangeListener((NestedScrollView.OnScrollChangeListener)
                (v, x, y, oldX, oldY) -> syncNavTitle(y));

        // 固定区：不放进滚动容器。设备清单这类页面要把 hero、筛选、搜索框
        // 钉在顶上，只让下面的列表滚 —— 否则翻到第 30 台想换筛选，还得先滚回去
        LinearLayout pinned = Ui.column(c);
        pinned.setPadding(pad, Ui.dp(c, 8), pad, 0);
        buildPinned(pinned);

        LinearLayout shell = new LinearLayout(c);
        shell.setOrientation(LinearLayout.VERTICAL);
        if (pinned.getChildCount() > 0) {
            shell.addView(pinned, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        }
        shell.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        swipe.addView(shell);
        swipe.setOnRefreshListener(() -> refresh(false));
        return swipe;
    }

    /**
     * 固定区（不进滚动容器）。默认没有内容。
     *
     * 放这里的东西会一直贴在顶部，滚动只影响 {@link #build} 里的内容。
     */
    protected void buildPinned(LinearLayout pinned) {
    }

    /** 页面大标题，返回 null 表示不要大标题 */
    protected String title() {
        return null;
    }

    /**
     * 滚动联动：大标题淡出 + 小标题补位。
     *
     * 大标题是内容的一部分，会跟着滚走。但如果什么都不做，
     * 滚到一半时它会被 ScrollView 的视口硬切一刀，露出半截压扁的字 ——
     * 这是肉眼最容易识别成「没做完」的细节。所以按滚动量给它一个
     * 淡出 + 上移，在完全离开视口前就透明掉。
     */
    private void syncNavTitle(int scrollY) {
        if (!isAdded() || getActivity() == null) {
            return;
        }
        if (bigTitle != null) {
            // 还没布局完时 getHeight() 是 0，用 33sp 标题的近似高度兜底
            int hgt = bigTitle.getHeight();
            if (hgt <= 0) {
                hgt = Ui.dp(requireContext(), 46);
            }
            float p = Math.min(1f, Math.max(0f, scrollY / (hgt * 0.78f)));
            bigTitle.setAlpha(1f - p);
            bigTitle.setTranslationY(-scrollY * 0.26f);
        }

        View bar = getActivity().findViewById(R.id.toolbar);
        if (bar == null) {
            return;
        }
        boolean show = scrollY > Ui.dp(requireContext(), 34);
        if (show == navTitleShown) {
            return;
        }
        navTitleShown = show;
        bar.animate().cancel();
        bar.animate().alpha(show ? 1f : 0f).setDuration(show ? 160 : 100).start();
    }

    @Override
    public void onViewCreated(@NonNull View view, @Nullable Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        refresh(true);
    }

    @Override
    public void onShown() {
        refresh(true);
        if (scroller != null) {
            syncNavTitle(scroller.getScrollY());
        }
    }

    @Override
    public void refresh(boolean quiet) {
        if (!isAdded() || getView() == null) {
            return;
        }
        long now = System.currentTimeMillis();
        if (quiet && now - lastLoad < 700L) {
            return;
        }
        lastLoad = now;
        if (!quiet) {
            setRefreshing(true);
        }
        load(quiet);
    }

    /** 搭静态骨架，只会调一次 */
    protected abstract void build(LinearLayout root);

    /** 取数并回填 */
    protected abstract void load(boolean quiet);

    protected void setRefreshing(boolean on) {
        if (swipe != null) {
            swipe.setRefreshing(on);
        }
    }

    // ---------------------------------------------------------------- 骨架屏

    /** 纯本地数据的页面可以返回 false 关掉骨架 */
    protected boolean skeletonEnabled() {
        return true;
    }

    private void installSkeleton(Context c) {
        if (!skeletonEnabled()) {
            if (body != null) {
                body.setVisibility(View.VISIBLE);
            }
            return;
        }
        skeleton = Skeleton.generic(c);
        skeletonAt = android.os.SystemClock.uptimeMillis();
        // body 用 GONE 而不是 INVISIBLE：INVISIBLE 仍然占高度，
        // 骨架会被挤到真实内容的下面，看起来像页面加载了一半
        body.setVisibility(View.GONE);
        int idx = content.indexOfChild(body);
        content.addView(skeleton, Math.max(1, idx));

        // 兜底：Agent 挂掉时请求可能一直不回来，骨架不能永远转下去。
        // 8 秒后直接放出真实内容 —— 卡片里全是「—」也比一直看灰块强
        content.postDelayed(() -> {
            if (!loaded && isAdded()) {
                loaded = true;
                reveal(false);
            }
        }, 8000L);
    }

    /** 首次数据回填完成后调用：骨架淡出、内容入场。重复调用无副作用 */
    protected void markLoaded() {
        if (loaded || !isAdded()) {
            return;
        }
        loaded = true;

        // 最少显示 420ms。局域网里 overview 常常 100ms 就回来了，
        // 骨架一闪而过比直接显示内容更闹——用户会看到页面「闪了一下」，
        // 定位成一个渲染 bug 而不是加载动画。慢网络下这个下限不会生效。
        long elapsed = android.os.SystemClock.uptimeMillis() - skeletonAt;
        long wait = Math.max(0L, 420L - elapsed);
        if (wait > 0L && skeleton != null) {
            content.postDelayed(() -> {
                if (isAdded()) {
                    reveal(true);
                }
            }, wait);
        } else {
            reveal(true);
        }
    }

    private void reveal(boolean animate) {
        final View sk = skeleton;
        skeleton = null;
        if (sk == null && body != null && body.getVisibility() == View.VISIBLE) {
            // 已经揭示过了（比如兜底超时先跑），不要重复放动画
            return;
        }
        Skeleton.stop(sk);
        if (sk == null) {
            revealBody(animate);
            return;
        }
        if (!animate) {
            content.removeView(sk);
            revealBody(false);
            return;
        }
        // 先让骨架淡出，再把内容放出来。
        // 反过来做会有一段「骨架和真实内容同时在场」的时间 ——
        // 因为 skeleton 在 body 之前，用户会看到内容被挤到骨架下方，
        // 像是页面加载了一半又重排了一次。
        sk.animate().alpha(0f).setDuration(130).withEndAction(() -> {
            if (content == null) {
                return;
            }
            content.removeView(sk);
            revealBody(true);
        }).start();
    }

    private void revealBody(boolean animate) {
        if (body == null) {
            return;
        }
        body.setVisibility(View.VISIBLE);
        if (animate) {
            enter();
        }
    }

    /**
     * 卡片依次入场：弹簧位移 + 淡入。
     *
     * 用 SpringAnimation 而不是普通属性动画，是因为位移用贝塞尔曲线收尾
     * 总有一种「停得很生硬」的感觉；弹簧是物理模型，末端的回弹会自然消失。
     *
     * 节奏：每张卡间隔 40ms，单卡 260ms，8 张卡总时长压在 550ms 内。
     * 再长用户就会觉得这个 App 慢，而不是「有动效」。
     */
    private void enter() {
        if (body == null || !isAdded()) {
            return;
        }
        final int step = Ui.dp(requireContext(), 16);
        int n = body.getChildCount();
        for (int i = 0; i < n; i++) {
            final View v = body.getChildAt(i);
            v.setAlpha(0f);
            v.animate().alpha(1f).setDuration(240).setStartDelay(i * 40L).start();

            SpringAnimation spring = new SpringAnimation(
                    v, DynamicAnimation.TRANSLATION_Y, 0f);
            SpringForce force = spring.getSpring();
            // 0.78 是「看得见的轻微回弹」，再低就成果冻了
            force.setDampingRatio(0.78f);
            force.setStiffness(SpringForce.STIFFNESS_LOW);
            spring.setStartValue(step);
            v.postDelayed(spring::start, i * 40L);
        }
    }

    /** 把视野拉回顶部。切换列表口径后要调，否则重建完看到的是一堆无关条目 */
    protected void scrollTop() {
        if (scroller != null) {
            scroller.scrollTo(0, 0);
        }
    }

    protected void notice(String text) {
        notice(text, false);
    }

    /** 提示条：ok=true 用绿色（操作成功），否则用琥珀色（进行中 / 需要注意） */
    protected void notice(String text, boolean ok) {
        if (banner == null) {
            return;
        }
        if (text == null || text.isEmpty()) {
            banner.setVisibility(View.GONE);
            return;
        }
        Context c = banner.getContext();
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 14));
        bg.setColor(ok ? 0x1A34C759 : 0x1AFFB454);
        banner.setBackground(bg);
        banner.setTextColor(c.getColor(ok ? R.color.ok : R.color.warn));
        banner.setText(text);
        banner.setVisibility(View.VISIBLE);
    }

    /** 请求失败时统一提示：已经用快照渲染过的情况下，只挂个提示条，不动界面 */
    protected void fail(String message) {
        setRefreshing(false);
        notice("⚠ " + message + "　（下拉可重试）");
    }

    protected Context ctx() {
        return requireContext();
    }
}
