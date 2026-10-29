package com.chaof.istoreos.util;

import com.chaof.istoreos.R;

import java.util.HashMap;
import java.util.Map;

/** 自动生成：scripts/fetch_app_icons.py。应用名 → 官方图标资源。 */
public final class AppIcons {

    private static final Map<String, Integer> MAP = new HashMap<>();

    static {
        MAP.put("腾讯", R.drawable.ic_app_tencent);
        MAP.put("X", R.drawable.ic_app_x);
        MAP.put("支付宝", R.drawable.ic_app_alipay);
        MAP.put("番茄小说", R.drawable.ic_app_fanqie);
        MAP.put("腾讯视频", R.drawable.ic_app_tencent_video);
        MAP.put("爱奇艺", R.drawable.ic_app_iqiyi);
        MAP.put("哔哩哔哩", R.drawable.ic_app_bilibili);
        MAP.put("抖音", R.drawable.ic_app_douyin);
        MAP.put("快手", R.drawable.ic_app_kuaishou);
        MAP.put("优酷", R.drawable.ic_app_youku);
        MAP.put("芒果 TV", R.drawable.ic_app_mgtv);
        MAP.put("西瓜视频", R.drawable.ic_app_xigua);
        MAP.put("搜狐视频", R.drawable.ic_app_sohu);
        MAP.put("电视 / 直播", R.drawable.ic_app_cctv);
        MAP.put("YouTube", R.drawable.ic_app_youtube);
        MAP.put("Netflix", R.drawable.ic_app_netflix);
        MAP.put("Disney+", R.drawable.ic_app_disney);
        MAP.put("Prime Video", R.drawable.ic_app_prime_video);
        MAP.put("微信", R.drawable.ic_app_wechat);
        MAP.put("QQ / 邮箱", R.drawable.ic_app_qq);
        MAP.put("微博", R.drawable.ic_app_weibo);
        MAP.put("知乎", R.drawable.ic_app_zhihu);
        MAP.put("小红书", R.drawable.ic_app_xiaohongshu);
        MAP.put("豆瓣", R.drawable.ic_app_douban);
        MAP.put("Telegram", R.drawable.ic_app_telegram);
        MAP.put("WhatsApp", R.drawable.ic_app_whatsapp);
        MAP.put("Discord", R.drawable.ic_app_discord);
        MAP.put("喜马拉雅", R.drawable.ic_app_ximalaya);
        MAP.put("网易云音乐", R.drawable.ic_app_netease_music);
        MAP.put("QQ 音乐", R.drawable.ic_app_qqmusic);
        MAP.put("酷狗 / 酷我", R.drawable.ic_app_kugou);
        MAP.put("咪咕", R.drawable.ic_app_migu);
        MAP.put("Spotify", R.drawable.ic_app_spotify);
        MAP.put("起点 / 七猫", R.drawable.ic_app_qimao);
        MAP.put("Steam", R.drawable.ic_app_steam);
        MAP.put("Epic", R.drawable.ic_app_epic);
        MAP.put("米哈游", R.drawable.ic_app_mihoyo);
        MAP.put("ChatGPT", R.drawable.ic_app_chatgpt);
        MAP.put("Claude", R.drawable.ic_app_claude);
        MAP.put("DeepSeek", R.drawable.ic_app_deepseek);
        MAP.put("GitHub", R.drawable.ic_app_github);
        MAP.put("淘宝 / 支付宝", R.drawable.ic_app_taobao);
        MAP.put("京东", R.drawable.ic_app_jd);
        MAP.put("拼多多", R.drawable.ic_app_pinduoduo);
        MAP.put("美团", R.drawable.ic_app_meituan);
        MAP.put("饿了么", R.drawable.ic_app_eleme);
        MAP.put("苏宁 / 唯品会", R.drawable.ic_app_vip);
        MAP.put("携程", R.drawable.ic_app_ctrip);
        MAP.put("高德地图", R.drawable.ic_app_amap);
        MAP.put("百度地图", R.drawable.ic_app_baidumap);
        MAP.put("12306", R.drawable.ic_app_rail12306);
        MAP.put("滴滴", R.drawable.ic_app_didi);
        MAP.put("小米 / 米家", R.drawable.ic_app_mijia);
        MAP.put("华为 / 荣耀", R.drawable.ic_app_hilink);
        MAP.put("OPPO / 欢太", R.drawable.ic_app_oppo);
        MAP.put("vivo 手机服务", R.drawable.ic_app_vivo);
        MAP.put("美的", R.drawable.ic_app_midea);
        MAP.put("海尔", R.drawable.ic_app_haier);
        MAP.put("摄像头 / 涂鸦", R.drawable.ic_app_tuya);
        MAP.put("扫地机", R.drawable.ic_app_roborock);
        MAP.put("Apple 服务", R.drawable.ic_app_apple);
        MAP.put("微软服务", R.drawable.ic_app_microsoft);
        MAP.put("Google 服务", R.drawable.ic_app_google);
        MAP.put("百度", R.drawable.ic_app_baidu);
        MAP.put("夸克 / UC", R.drawable.ic_app_quark);
        MAP.put("网易", R.drawable.ic_app_netease);
        MAP.put("腾讯服务", R.drawable.ic_app_tencent);
        MAP.put("开发仓库", R.drawable.ic_app_docker);
        MAP.put("远程控制", R.drawable.ic_app_oray);
        MAP.put("主机 / 平台", R.drawable.ic_app_xbox);
        MAP.put("阿里云", R.drawable.ic_app_aliyun);
        MAP.put("腾讯云", R.drawable.ic_app_tencent_cloud);
        MAP.put("华为云", R.drawable.ic_app_huaweicloud);
        MAP.put("中国联通", R.drawable.ic_app_unicom);
        MAP.put("中国电信", R.drawable.ic_app_ct);
        MAP.put("中国移动", R.drawable.ic_app_cmcc);
        MAP.put("字节跳动", R.drawable.ic_app_bytedance);
    }

    private AppIcons() {
    }

    public static int res(String name) {
        Integer id = name == null ? null : MAP.get(name);
        return id == null ? 0 : id;
    }
}
