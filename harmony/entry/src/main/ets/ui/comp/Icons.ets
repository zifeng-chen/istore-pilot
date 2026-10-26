/**
 * 页签图标。
 *
 * 用 Path 的 SVG 指令画，不用系统 SymbolGlyph ——
 * 一是系统符号里没有「代理」「拦截」这种语义的图标，
 * 二是 Path 的 stroke 颜色能跟着选中态走，不用准备两套图片资源。
 *
 * 坐标系就是组件尺寸（22x22），没有 viewBox 缩放，
 * 所以下面的坐标都是按 22 格手算的，改尺寸时要一起改。
 */
export class Ico {
  /** 概览：仪表盘弧 + 指针 */
  static readonly OVERVIEW: string =
    'M3 16.2 A8.4 8.4 0 1 1 19 16.2 M11 12.4 L14.6 8.8';

  /** 网络：梯形机箱 + 两根天线 + 网口横线 */
  static readonly NETWORK: string =
    'M4.6 11.2 H17.4 A1.4 1.4 0 0 1 18.8 12.6 V16.2 A1.4 1.4 0 0 1 17.4 17.6 ' +
    'H4.6 A1.4 1.4 0 0 1 3.2 16.2 V12.6 A1.4 1.4 0 0 1 4.6 11.2 Z ' +
    'M6.8 11.2 L8.4 5.4 M15.2 11.2 L13.6 5.4 ' +
    'M6.6 14.4 H10 ' ;

  /** 设备：手机轮廓 + 底部指示点 */
  static readonly DEVICES: string =
    'M6.4 2.6 H15.6 A2.2 2.2 0 0 1 17.8 4.8 V17.2 A2.2 2.2 0 0 1 15.6 19.4 ' +
    'H6.4 A2.2 2.2 0 0 1 4.2 17.2 V4.8 A2.2 2.2 0 0 1 6.4 2.6 Z ' +
    'M9.4 16.4 H12.6';

  /** 代理：地球 + 经线纬线 */
  static readonly PROXY: string =
    'M11 2.6 A8.4 8.4 0 1 0 11 19.4 A8.4 8.4 0 1 0 11 2.6 Z ' +
    'M2.8 11 H19.2 ' +
    'M11 2.6 C7.6 5 7.6 17 11 19.4 C14.4 17 14.4 5 11 2.6 Z';

  /** 拦截：盾牌 + 斜杠 */
  static readonly SHIELD: string =
    'M11 2.6 L17.8 5.4 V10.8 C17.8 15 14.6 18.2 11 19.4 ' +
    'C7.4 18.2 4.2 15 4.2 10.8 V5.4 Z ' +
    'M8.2 7.8 L13.8 15.6';

  /** 设置：三横线滑杆 */
  static readonly SETTINGS: string =
    'M3.2 6.4 H18.8 M3.2 11 H18.8 M3.2 15.6 H18.8 ' +
    'M7.2 4.6 A1.8 1.8 0 1 0 7.2 8.2 A1.8 1.8 0 1 0 7.2 4.6 Z ' +
    'M14.8 9.2 A1.8 1.8 0 1 0 14.8 12.8 A1.8 1.8 0 1 0 14.8 9.2 Z ' +
    'M7.2 13.8 A1.8 1.8 0 1 0 7.2 17.4 A1.8 1.8 0 1 0 7.2 13.8 Z';

  /** 右箭头，列表行尾用 */
  static readonly CHEVRON: string = 'M8.5 5.5 L14.5 11 L8.5 16.5';

  /** 对勾 */
  static readonly CHECK: string = 'M4.5 11.5 L9 16 L17.5 6.5';

  /** 关闭，弹层右上角用 */
  static readonly CLOSE: string = 'M6.6 6.6 L17.4 17.4 M17.4 6.6 L6.6 17.4';
}

/**
 * 设置页 / 卡片标题用的小图标。
 *
 * 和页签图标一样走 Path 指令，但这里是 24×24 的设计稿坐标，
 * 由 GlyphIcon 组件用 viewPort 缩放到实际尺寸 —— 页签那套坐标是按 22 格
 * 手算的，直接混用会因为缩放比例不同而粗细不一。
 *
 * 描边和填充分成两条 Path：Path 的 fill 作用于整条路径，
 * 混在一起会让「地球」这类空心图形被填满。
 */
export class Glyph {
  static readonly LINK: string = 'link';
  static readonly GLOBE: string = 'globe';
  static readonly PALETTE: string = 'palette';
  static readonly BOX: string = 'box';
  static readonly SHIELD: string = 'shield';
  static readonly INFO: string = 'info';
  static readonly KEY: string = 'key';
  static readonly REFRESH: string = 'refresh';
  static readonly UPLOAD: string = 'upload';
  static readonly CLOCK: string = 'clock';
  static readonly CHIP: string = 'chip';
  static readonly POWER: string = 'power';
  static readonly LIST: string = 'list';
  static readonly BOLT: string = 'bolt';
  static readonly CHEVRON: string = 'chevron';
  static readonly CHECK: string = 'check';
  static readonly CLOSE: string = 'close';

  /** 只描边的部分 */
  static stroke(kind: string): string {
    switch (kind) {
      case Glyph.GLOBE:
        return 'M3.6 12 H20.4 ' +
          'M12 3.6 A8.4 8.4 0 1 1 12 20.4 A8.4 8.4 0 1 1 12 3.6 ' +
          'M6.2 12 A5.8 8.4 0 1 1 17.8 12 A5.8 8.4 0 1 1 6.2 12';
      case Glyph.LINK:
        // 两个节点 + 中间连线：比画链条更清楚
        return 'M8.1 12 H15.9 ' +
          'M5.5 9.4 A2.6 2.6 0 1 1 5.5 14.6 A2.6 2.6 0 1 1 5.5 9.4 ' +
          'M18.5 9.4 A2.6 2.6 0 1 1 18.5 14.6 A2.6 2.6 0 1 1 18.5 9.4';
      case Glyph.PALETTE:
        return 'M12 3.6 A8.4 8.4 0 1 1 12 20.4 A8.4 8.4 0 1 1 12 3.6';
      case Glyph.BOX:
        return 'M12 3.4 L20 7.6 L20 16.4 L12 20.6 L4 16.4 L4 7.6 Z ' +
          'M4 7.6 L12 11.8 L20 7.6 M12 11.8 V20.6';
      case Glyph.SHIELD:
        return 'M12 3.2 L19.6 6.4 V12.2 C19.6 16.4 16.4 19.4 12 20.8 ' +
          'C7.6 19.4 4.4 16.4 4.4 12.2 V6.4 Z';
      case Glyph.INFO:
        return 'M12 3.6 A8.4 8.4 0 1 1 12 20.4 A8.4 8.4 0 1 1 12 3.6 ' +
          'M12 11.2 V16.2';
      case Glyph.KEY:
        return 'M8.4 7.8 A4.2 4.2 0 1 1 8.4 16.2 A4.2 4.2 0 1 1 8.4 7.8 ' +
          'M12.6 12 H20.2 M17.4 12 V15.4 M20.2 12 V14.6';
      case Glyph.REFRESH:
        return 'M17 6 A7.8 7.8 0 1 1 7 6 ' +
          'M16.6 3.4 L20.4 5.6 L16.2 7.6';
      case Glyph.UPLOAD:
        return 'M12 17.4 V4.6 M7.6 9 L12 4.4 L16.4 9 M4.6 19.6 H19.4';
      case Glyph.CLOCK:
        return 'M12 3.6 A8.4 8.4 0 1 1 12 20.4 A8.4 8.4 0 1 1 12 3.6 ' +
          'M12 7.4 V12.4 L15.4 14.2';
      case Glyph.CHIP:
        return 'M8.2 6.2 H15.8 A2 2 0 0 1 17.8 8.2 V15.8 A2 2 0 0 1 15.8 17.8 ' +
          'H8.2 A2 2 0 0 1 6.2 15.8 V8.2 A2 2 0 0 1 8.2 6.2 Z ' +
          'M11 10 H13 A1 1 0 0 1 14 11 V13 A1 1 0 0 1 13 14 ' +
          'H11 A1 1 0 0 1 10 13 V11 A1 1 0 0 1 11 10 Z ' +
          'M8.2 2.8 V6.2 M8.2 17.8 V21.2 M2.8 8.2 H6.2 M17.8 8.2 H21.2 ' +
          'M12 2.8 V6.2 M12 17.8 V21.2 M2.8 12 H6.2 M17.8 12 H21.2 ' +
          'M15.8 2.8 V6.2 M15.8 17.8 V21.2 M2.8 15.8 H6.2 M17.8 15.8 H21.2';
      case Glyph.POWER:
        return 'M15.6 6.37 A7.2 7.2 0 1 1 8.4 6.37 M12 2.8 V11.4';
      case Glyph.LIST:
        return 'M4 7 H20 M4 12 H20 M4 17 H20';
      case Glyph.BOLT:
        return 'M13.4 2.6 L5.4 13.6 H11.2 L9.8 21.4 L18.4 10 H12.4 Z';
      case Glyph.CHEVRON:
        return 'M8.5 5.5 L14.5 11 L8.5 16.5';
      case Glyph.CHECK:
        return 'M4.5 11.5 L9 16 L17.5 6.5';
      case Glyph.CLOSE:
        return 'M6.6 6.6 L17.4 17.4 M17.4 6.6 L6.6 17.4';
      default:
        return 'M12 3.6 A8.4 8.4 0 1 1 12 20.4 A8.4 8.4 0 1 1 12 3.6';
    }
  }

  /** 需要实心填充的部分（色盘上的孔、信息图标上的点）。返回空串表示没有 */
  static fill(kind: string): string {
    if (kind === Glyph.PALETTE) {
      return 'M8.6 7.9 A1.5 1.5 0 1 1 8.6 10.9 A1.5 1.5 0 1 1 8.6 7.9 ' +
        'M14.6 7.1 A1.5 1.5 0 1 1 14.6 10.1 A1.5 1.5 0 1 1 14.6 7.1 ' +
        'M16.2 12.9 A1.5 1.5 0 1 1 16.2 15.9 A1.5 1.5 0 1 1 16.2 12.9 ' +
        'M10.2 14.3 A1.5 1.5 0 1 1 10.2 17.3 A1.5 1.5 0 1 1 10.2 14.3';
    }
    if (kind === Glyph.INFO) {
      return 'M12 6.9 A1.3 1.3 0 1 1 12 9.5 A1.3 1.3 0 1 1 12 6.9';
    }
    return '';
  }
}
