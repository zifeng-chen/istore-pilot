# ArkTS 编译期坑清单（AI 最容易写错的地方）

> 提炼自 JohnnnyTang/harmonyos-dev-skills 的 `arkts-language.md`（其对华为官方文档
> 快照 2026-10-13 的蒸馏，每条带规则 id 与错误码），结合本项目实际情况改写。
> 本项目 compatibleSdkVersion = 6.0.0(20)，**标准模式**下所有 `.ets` 里的规则违反
> 都是**编译错误**（E），不是警告。
>
> 用法：写 `.ets` 前自查 §1；编译报错时按括号里的 rule-id 到 §2 查改写；§3 是并发、
> §4 是导入规则。**不要用 `@ts-ignore`/`@ts-nocheck`** —— ArkTS 不认，关不掉。

## 一、本项目最高频的 10 条（先查这个）

| # | 规则 | 错误写法 | 正确写法 |
|---|---|---|---|
| 1 | `arkts-no-any-unknown` | `any` / `unknown` | 具体类型；"万能"用 `Object`，JSON 用 `Record<string, Object>` |
| 2 | `arkts-no-untyped-obj-literals` | `let cfg = {url:'', retries:3}` | 先声明 class/interface，`let c: Cfg = {…}` |
| 3 | `arkts-no-destruct-decls` | `const {x,y} = p` / `[a,b]=arr` | `const x = p.x` / `arr[0]` |
| 4 | `arkts-no-for-in` / `no-in` / `no-delete` | `for(k in o)` / `'k' in o` / `delete o.k` | `for(e of Object.entries(o))` / `instanceof` / 字段设 `null` |
| 5 | `arkts-no-spread` | `{...a, z}`（对象展开） | 逐字段赋值或构造器拷贝；数组展开 OK |
| 6 | `arkts-no-func-expressions` | `function(s){}` 当表达式 | 箭头函数 |
| 7 | `arkts-no-standalone-this` | 普通函数/静态方法里用 `this` | 实例方法；静态里写 `类名.x` |
| 8 | `arkts-no-types-in-catch` | `catch (e: BusinessError)` | `catch(e){ const err = e as BusinessError }` |
| 9 | `arkts-limited-throw` | `throw 'msg'` | `throw new Error('msg')` |
| 10 | `arkts-no-obj-literals-as-types` | `let o: {x:number}` | 命名 `interface`/`class` |

> 我们项目里已经规避了其中几条（`J` 类内部用 `Object`/`Record` 包装、Fmt 全静态），
> 但**新增页面/工具类时仍会踩**，尤其是对象字面量、解构和 `catch` 类型注解。

## 二、完整规则表（id · 严重级 · 禁止 → 改写）

严重级：**E**=编译错误；**W**=警告（现在能过，将来可能报）。错误码是 `10605xxx`，表里只列后三位。

### 类型系统

| 规则 | 码 | 禁止 → 改写 |
|---|---|---|
| arkts-no-any-unknown | 008 | `any`/`unknown` → 具体类型；`Object` 表"任意"，`Record<string,Object>` 表 JSON |
| arkts-no-untyped-obj-literals | 038 | 无上下文可推类型的 `{…}` 字面量 → 声明 class/interface 再标注 |
| arkts-no-obj-literals-as-types | 040 | 内联对象类型 `{x:number}` → 命名 `interface`/`class` |
| arkts-no-noninferrable-arr-literals | 043 | 无元素类型的 `[{n:1},{n:2}]` → `let a: C[] = [...]` |
| arkts-no-structural-typing | 030 | 无关但同形状的类互相赋值 → `extends`/共享 interface/type 别名 |
| arkts-no-indexed-signatures | 017 | interface/class 里 `{[k:string]:T}` → `Record<string,T>`/`Map`/数组字段 |
| arkts-no-props-by-index | 029 | `obj['field']` → 点号访问；动态键改 `Record` |
| arkts-identifiers-as-prop-names | 001 | 数字/任意字符串作属性名 → 标识符；`Record` 的键可用字符串字面量 |
| arkts-no-intersection-types | 019 | `A & B` → `interface C extends A, B {}` |
| arkts-no-conditional-types | 022 | 条件类型/`infer` → 受限泛型或 `Object` |
| arkts-no-mapped-types | 083 | 映射类型 → 显式写 class / `Record<K,T>` |
| arkts-no-aliases-by-index | 028 | 索引访问类型 `T['k']` → 写出类型 |
| arkts-no-typing-with-this | 021 | `this` 当类型 → 具体类名 |
| arkts-no-type-query | 060 | 类型位置的 `typeof` → 显式类型 |
| arkts-no-utility-types | 138 | 除 `Partial/Required/Readonly/Record` 外的工具类型 → 显式类型 |
| arkts-no-as-const | 142 | `as const`/字面量类型 → 普通类型 |
| arkts-as-casts | 053 | `<T>x` 尖括号转换 → `x as T`（错转可能运行时 `ClassCastException`） |
| arkts-no-is | 096 | 自定义类型守卫 `arg is Foo` → `instanceof` + `as` |
| arkts-instanceof-ref-types | 065 | 原始类型当 `instanceof` 左值 → 左值必须是对象 |
| arkts-no-inferred-generic-params | 034 | 只能从返回类型推的泛型 → 显式 `<T>` |
| arkts-no-definite-assignment | 134 **W** | `let x!: T` → 声明处或构造器初始化 |
| 严格检查 | 999 | 未初始化字段、`let n: number = null`、缺 return → 给默认值/`T\|null`/每条路径 return |

### 函数、`this`、类

| 规则 | 码 | 禁止 → 改写 |
|---|---|---|
| arkts-no-var | 005 | `var` → `let`/`const` |
| arkts-no-func-expressions | 046 | 函数表达式 → 箭头函数 |
| arkts-no-nested-funcs | 092 | 函数内嵌 `function` → `let f: (m:string)=>void = (m:string):void=>{…}` |
| arkts-no-standalone-this | 093 | 普通函数/静态方法里 `this` → 实例方法；静态用 `类名.x` |
| arkts-no-func-apply-call | 152 | `fn.apply/.call` → 直接调 |
| arkts-no-func-bind | 140 **W** | `fn.bind(this)` → 箭头 `():void=>this.foo()` 或箭头字段 |
| arkts-no-func-props | 139 | 函数上挂属性 → class + 静态方法 |
| arkts-no-generators | 094 | `function*`/`yield` → `async`/`await` 或循环 |
| arkts-no-destruct-params | 091 | `function f({a,b}:T)` → 平铺参数/单个带类型对象参数 |
| arkts-no-implicit-return-types | 090 | 调用无标注返回类型的函数时不写返回类型 → 标注 |
| arkts-no-ctor-prop-decls | 025 | `constructor(private x:T)` → 类体声明字段 + 构造器赋值 |
| arkts-no-private-identifiers | 003 | `#field` → `private` |
| arkts-no-class-literals | 050 | `const C = class{…}` → 命名 class |
| arkts-implements-only-iface | 051 | `implements SomeClass` → 只 implements 接口 |
| arkts-extends-only-class | 104 | `interface I extends SomeClass` → 接口只 extends 接口 |
| arkts-no-method-reassignment | 052 | `obj.method = otherFn` → 子类重写/函数字段 |
| arkts-no-classes-as-obj | 149 **W** | 把类当值用 → 工厂 `()=>new C()` |
| call/ctor signatures | 014/015/027/106 | 调用/构造签名类型 → 带 `invoke()`/`create()` 的类或工厂 lambda |
| arkts-no-multiple-static-blocks | 016 | 多个 `static{}` → 合并 |
| arkts-no-prototype-assignment | 136 | `C.prototype.x=` → 类成员 |
| decl/enum merging | 103/113 | 重开 interface/class/enum → 单声明 |
| arkts-no-enum-mixed-types | 111 | 数字+字符串混用枚举 → 单类型、编译期常量 |
| arkts-no-extend-same-prop | 102 | 两接口同名方法冲突 → 重构 |

### 语句、运算符、标准库

| 规则 | 码 | 禁止 → 改写 |
|---|---|---|
| destruct assignment/decls | 069/074 | 解构赋值/声明 → 逐字段/下标 |
| arkts-no-for-in | 080 | `for(k in o)` → `for(e of Object.entries(o))` |
| arkts-no-in | 066 | `'name' in p` → `instanceof`；Record 用 `Object.keys` |
| arkts-no-delete | 059 | `delete p.y` → 字段 `T\|null` 置 `null` |
| arkts-no-spread | 099 | 对象展开/元组展开 → 逐字段；数组展开 OK |
| arkts-no-polymorphic-unops | 055 | `+'42'`/`-'5'`/`~'5'` → `Number(...)` |
| arkts-no-comma-outside-loops | 071 | 逗号运算符（for 头除外）→ 拆语句 |
| arkts-limited-throw | 087 | `throw 4`/`throw 'msg'` → `throw new Error(...)` |
| arkts-no-types-in-catch | 079 | `catch(e: T)` → `catch(e)` 后 `e as T` |
| arkts-no-with | 084 | `with(Math){}` → 全限定访问 |
| arkts-no-symbol | 002 | `Symbol()` → 不支持，只有 `Symbol.iterator` |
| arkts-no-globalthis | 137 **W** | `globalThis.x` → 模块导出/单例类 |
| arkts-no-new-target | 132 | `new.target` → 不支持 |
| arkts-no-jsx | 054 | JSX → ArkUI 声明式 |
| arkts-limited-stdlib | 144 | `eval`、`Object.assign/create/freeze/fromEntries/…`、大部分 `Reflect.*` → 手写循环进 `Record` |
| arkts-limited-esobj | 151 **W** | 滥用 `ESObject` → 具体类型（API 18 起不能接对象字面量） |
| arkts-no-regexp-literals | — | `/\s*/g` → `new RegExp('\\s*','g')` |

> 注意：`arkts-no-spread` 的官方示例一度建议 `Object.assign`，但 `assign` 在
> `arkts-limited-stdlib` 的禁止名单里——**别用**。

## 三、并发（TaskPool / Worker / @Sendable）

我们目前是纯 UI + 轮询，没上多线程，但以后做耗时任务时先看这里：

- **模型**：TaskPool 和 Worker 都是 Actor 模型、内存隔离，参数走结构化克隆；序列化上限 **16 MB**。
- **首选 TaskPool**：自带优先级/取消/任务组/周期任务、线程自动伸缩。Worker 用于单任务 CPU >3 分钟、有状态/句柄序列、内存紧张时（最多 64 个 Worker）。
- **`@Concurrent`**（TaskPool 任务函数）：只用于 `.ets` + Stage 模型；必须是顶层普通/`async` 函数（箭头/方法/匿名/生成器都不行）；**不能闭包**（只能用局部、参数、import 的名字）；同类辅助函数放单独文件 import。
- **Worker 文件**：放 `{module}/src/main/ets/`；**worker 文件里绝不能 `export`**（会 jscrash）；自己管 `terminate()`/`close()`。
- **`@Sendable`**：字段类型受限（原始类型、`const enum`、其它 Sendable、`@arkts.collections` 容器——不是 JS 的 Array/Map/Set）；字段必须显式初始化；对象/数组字面量不可 Sendable，用 `new` 创建。

## 四、导入与文件规则

- 优先 **Kit 导入**：`import { UIAbility, common } from '@kit.AbilityKit'`、`import { BusinessError } from '@kit.BasicServicesKit'`。旧写法 `import UIAbility from '@ohos.app.ability.UIAbility'` 仍可用；`import * as m from '@kit.X'` 会撑大 HAP，少用。
- `arkts-no-ts-deps`(147)：`.ets` 可 import `.ets/.ts/.js`；`.ts/.js` **不能** import `.ets`。
- `arkts-no-misplaced-imports`(150)：静态 `import` 必须在所有语句之前；动态 `import()` 任意位置。
- 禁止：`import x = require()`(121)、`export =`(126)、`declare module`(128)、`'*!text'`(129)、UMD(130)、`assert {type:'json'}`(143)。
- **模块循环 import 会直接起不来**；`eval`/`with`/`new Function(string)` 运行期一律禁止。
- 动态 import 返回 `ESObject`：`import('./Calc').then((m: ESObject) => m.add(1,2))`。
- 重载：多个签名 + **一个**实现体 OK，多个实现体不行。

## 五、来源与工具

- 规则表/并发/导入：JohnnnyTang/harmonyos-dev-skills → `references/arkts-language.md`（官方文档快照 2026-10-13 蒸馏）。
- 离线 API 检索：linhay/harmony-next.skills（API 12–23 离线快照，含 API 26 声明）。
  安装：`npx skills add linhay/harmony-next.skills --skill harmony-next -a codex -g -y --copy`，
  用 `rg -n "<关键词>" INDEX.md` 渐进式定位到具体 `.md`。Kit 快速入口见
  `docs/HARMONY_SKILLS_SETUP.md`。
- 官方在线源：`typescript-to-arkts-migration-guide`（规则体带错误码）、`arkts-more-cases`、
  `faqs-arkts-*`（as/JSON.parse 坑、instanceof 失效等）。

### JSON.parse 的经典坑

`JSON.parse(s) as MyClass` **不会**真正构造实例：不跑构造器、字段默认值丢失（缺的字段
变 `undefined`）、没方法、`instanceof` 为 false。要真对象就 `new MyClass(record)` 逐字段装填。
（本项目 `J` 类刻意只做 `Record<string,Object>` 包装 + `str/num/bool/arr/obj` 访问器，就是为了绕开这个坑。）
