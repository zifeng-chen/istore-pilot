# R8 保留规则（release）
#
# 这个 App 没有反射、没有自定义 View 的 XML 引用、没有序列化框架，
# 所以规则只有三类：让崩溃栈可读、保住自绘控件的入口、给图表库留后路。
# 清单里声明的 Activity 由 AGP 自动生成 keep 规则，不用手写。

# 崩溃栈保留行号：混淆后类名变了没关系，行号丢了就完全没法查
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 自绘控件（Ui / MeterBar / TrendChart / AppIcon 里都是 new 出来的，
# 但 Fragment 里偶尔会用全限定名反射式创建，保守留着）
-keep public class com.chaof.istoreos.widget.** { *; }

# MPAndroidChart：内部有些回调走弱引用/泛型，混淆后偶发 ClassCastException，
# 官方 issue 里也建议整包保留（体积不大）
-keep class com.github.mikephil.charting.** { *; }
-dontwarn com.github.mikephil.charting.**

# AndroidX / Material 自带 consumer rules，这里不重复；
# 关掉对这些包的警告，避免构建被无关的缺失引用打断
-dontwarn androidx.**
-dontwarn com.google.android.material.**
