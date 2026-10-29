package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.github.mikephil.charting.charts.LineChart;
import com.github.mikephil.charting.components.YAxis;
import com.github.mikephil.charting.data.Entry;
import com.github.mikephil.charting.data.LineData;
import com.github.mikephil.charting.data.LineDataSet;
import com.github.mikephil.charting.formatter.ValueFormatter;
import com.github.mikephil.charting.highlight.Highlight;
import com.github.mikephil.charting.listener.OnChartValueSelectedListener;

import java.util.ArrayList;
import java.util.List;

/**
 * 实时速率趋势图（MPAndroidChart 封装）。
 *
 * 之前是自绘的 {@link GraphView}：56dp 高、没有坐标轴、没有触摸、两条线同色系
 * 混在一起看不清。换成库之后能拿到三样自绘很难做好的东西：
 *  - 曲线平滑（CUBIC_BEZIER）与渐变填充
 *  - 双指缩放/拖拽之外，单指按住能读出某一点的具体数值
 *  - Y 轴自动刻度（自带「整齐的数」算法，不用自己算量程）
 *
 * 封装的原则：所有默认样式都关掉。MPAndroidChart 的默认观感是「工程图表」——
 * 图例、描述文字、右侧 Y 轴、边框、坐标轴直线，全都要么关掉要么重画，
 * 否则放进来立刻和界面其它部分格格不入。
 */
public class TrendChart extends LineChart {

    /**
     * 窗口点数。主界面每 3 秒刷新一次，40 点就是 2 分钟 ——
     * 之前写 60 点却标着「最近 2 分钟」，实际窗口是 3 分钟，是错的。
     * 点数也不宜再多：一屏 148dp 高的图上超过 40 个折点就开始锯齿。
     */
    private static final int N = 40;

    public interface OnPeek {
        /** index < 0 表示手指抬起，恢复显示最新值 */
        void onPeek(int index, float downBps, float upBps);
    }

    private final float[] down = new float[N];
    private final float[] up = new float[N];

    private final LineDataSet downSet;
    private final LineDataSet upSet;

    private OnPeek peek;

    public TrendChart(Context c) {
        super(c);
        setBackgroundColor(Color.TRANSPARENT);

        // ---- 交互：只保留「按住看数值」，其余全关 ----
        setTouchEnabled(true);
        setDragEnabled(false);
        setScaleEnabled(false);
        setPinchZoom(false);
        setDoubleTapToZoomEnabled(false);
        setHighlightPerDragEnabled(false);
        setHighlightPerTapEnabled(true);

        // ---- 整体外观：去掉一切默认装饰 ----
        getDescription().setEnabled(false);
        getLegend().setEnabled(false);
        setDrawGridBackground(false);
        setDrawBorders(false);
        setClipValuesToContent(false);
        setMinOffset(0f);
        setExtraOffsets(0f, 0f, 0f, 0f);

        // ---- X 轴：趋势图不需要刻度，横轴就是「时间从右往左」 ----
        getXAxis().setDrawGridLines(false);
        getXAxis().setDrawAxisLine(false);
        getXAxis().setDrawLabels(false);

        // ---- 左 Y 轴：只要虚线网格 + 极简标签 ----
        YAxis y = getAxisLeft();
        y.setDrawGridLines(true);
        y.setGridLineWidth(0.6f);
        y.setGridColor(Ui.color(c, R.color.divider));
        y.enableGridDashedLine(6f, 7f, 0f);
        y.setDrawAxisLine(false);
        y.setTextColor(Ui.color(c, R.color.text_tertiary));
        y.setTextSize(9f);
        y.setXOffset(3f);
        y.setAxisMinimum(0f);
        y.setSpaceTop(0f);
        y.setLabelCount(4, false);
        y.setValueFormatter(new ValueFormatter() {
            @Override
            public String getFormattedValue(float v) {
                return Fmt.bpsAxis(v);
            }
        });
        getAxisRight().setEnabled(false);

        // 绘图区四周的留白：左边给 Y 轴标签，上下各留一点，
        // 否则最上面和最下面的刻度文字会被画布边缘切掉一半
        setViewPortOffsets(Ui.dp(c, 34), Ui.dp(c, 8), 0f, Ui.dp(c, 14));

        // ---- 两条线 ----
        downSet = series(c, R.color.primary, true);
        upSet = series(c, R.color.warn, false);
        downSet.setLabel("下载");
        upSet.setLabel("上传");

        setData(new LineData(downSet, upSet));
        syncEntries();

        setOnChartValueSelectedListener(new OnChartValueSelectedListener() {
            @Override
            public void onValueSelected(Entry e, Highlight h) {
                if (peek == null) {
                    return;
                }
                int i = (int) e.getX();
                if (i >= 0 && i < N) {
                    peek.onPeek(i, down[i], up[i]);
                }
            }

            @Override
            public void onNothingSelected() {
                if (peek != null) {
                    peek.onPeek(-1, down[N - 1], up[N - 1]);
                }
            }
        });
    }

    /**
     * 放进深色的 hero 卡里用：网格线和刻度换成半透明浅色。
     * 默认配色是按白底设计的，直接放到墨绿渐变上什么都看不见。
     */
    public void useOnHero() {
        Context c = getContext();
        int fg = Ui.color(c, R.color.hero_fg);
        YAxis y = getAxisLeft();
        y.setGridColor(Ui.alpha(fg, 0.16f));
        y.setTextColor(Ui.alpha(fg, 0.55f));
        setNoDataTextColor(Ui.alpha(fg, 0.55f));
    }

    private LineDataSet series(Context c, int colorRes, boolean fill) {
        int base = Ui.color(c, colorRes);
        LineDataSet s = new LineDataSet(null, null);
        s.setColor(base);
        s.setLineWidth(1.8f);
        s.setMode(LineDataSet.Mode.CUBIC_BEZIER);
        s.setCubicIntensity(0.16f);
        s.setDrawCircles(false);
        s.setDrawCircleHole(false);
        s.setDrawValues(false);
        s.setHighlightEnabled(true);
        // 高亮竖线用主色的 35%，点不变大（否则一按住就是个突兀的圆点）
        s.setHighLightColor(Ui.alpha(base, 0.35f));
        s.setHighlightLineWidth(1f);
        s.enableDashedHighlightLine(4f, 4f, 0f);
        s.setDrawHorizontalHighlightIndicator(false);

        if (fill) {
            s.setDrawFilled(true);
            // 渐变填充是这版图最关键的一笔：纯色填充会把上半张卡压得很闷，
            // 从 28% 淡到 2% 才有「数据在流动」的轻盈感
            s.setFillDrawable(new GradientDrawable(
                    GradientDrawable.Orientation.TOP_BOTTOM,
                    new int[]{Ui.alpha(base, 0.28f), Ui.alpha(base, 0.02f)}));
        }
        return s;
    }

    /** 按下手指时的回调；传 null 取消 */
    public void setOnPeek(OnPeek p) {
        this.peek = p;
    }

    /** 追加一组采样（字节/秒） */
    public void push(double downBps, double upBps) {
        System.arraycopy(down, 1, down, 0, N - 1);
        System.arraycopy(up, 1, up, 0, N - 1);
        down[N - 1] = (float) Math.max(0, downBps);
        up[N - 1] = (float) Math.max(0, upBps);
        syncEntries();
    }

    /** 当前窗口内的峰值（字节/秒），给顶部「峰值」文案用 */
    public float peak() {
        float m = 0f;
        for (int i = 0; i < N; i++) {
            m = Math.max(m, Math.max(down[i], up[i]));
        }
        return m;
    }

    /**
     * 把内部数组同步进图表。每帧全量重建 Entry 看起来浪费，
     * 但 60 个点 × 2 条线的开销远小于「增量更新时忘了对齐 x 索引」的调试成本，
     * 而且 2 秒一次刷新，这点耗时完全可以忽略。
     */
    private void syncEntries() {
        List<Entry> a = new ArrayList<>(N);
        List<Entry> b = new ArrayList<>(N);
        for (int i = 0; i < N; i++) {
            a.add(new Entry(i, down[i]));
            b.add(new Entry(i, up[i]));
        }
        downSet.setValues(a);
        upSet.setValues(b);
        // 量程给峰值的 1.25 倍，让最高的点离顶还有一点空气；
        // 静默时用 128 KB/s 当下限 —— 之前写的是 1 MB，
        // 结果日常几十 KB/s 的流量全被压在底部一条线上，整张图看起来像坏了
        float max = Math.max(peak() * 1.25f, 128f * 1024f);
        getAxisLeft().setAxisMaximum(max);
        downSet.notifyDataSetChanged();
        upSet.notifyDataSetChanged();
        getData().notifyDataChanged();
        notifyDataSetChanged();
        invalidate();
    }
}
