/**
 * LazyForEach 用的极简数据源。
 *
 * List 只渲染视口内的行，120 条拦截日志在低端机上也不会一次性建完所有节点。
 * 数据整批换掉时调 `set()` 触发 onDataReloaded —— 我们这几个列表都是
 * 「刷新即整表替换」，不需要做局部增删的增量通知。
 */
export class SimpleData<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  set(items: T[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
