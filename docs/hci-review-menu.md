# Hijack 菜单 HCI 评审(2026-10-01)

**结论:** 菜单乱，根子在信息架构。现在三个概念(触发键、语音来源、来源的键位与按法)平铺成并列的一级项，"来源的按法"还挂在"来源的键"子菜单里面，而这一项本来只有少数 provider 才用得到。建议拆成三段:**状态**、**我怎么按**、**用什么听写**;把"它的键/它的按法"这一层合并成一个按 provider 显示的"高级"子菜单，并且默认自动处理。

## 1. 问题清单(按严重度)

| # | 级别 | 问题 | 启发式 | 修法 |
|---|---|---|---|---|
| 1 | **Blocker** | 状态行写着 "Hold Right Option…"，实际模式是 hands-free | Nielsen #1 系统状态可见、#4 一致性 | 状态行从同一个 state 派生:hands-free 时写 "Tap Right Option to dictate with 豆包 / 轻点右 Option 用豆包听写"。加一条单测断言两种模式下文案不同 |
| 2 | **Major** | Squirrel(没有语音功能的打字输入法)出现在"语音输入"候选里 | Nielsen #5 防错、#2 匹配真实世界 | 候选只列有语音能力的已知 provider(WeType/豆包/搜狗/Handy);已安装但不认识的输入法放进 config。没安装的 provider 显示成灰色并附 "(not installed / 未安装)" |
| 3 | **Major** | "It wants" 按法列表嵌在"Its voice key"子菜单里，父行还带 ✓。三层深，一个被勾选的项又能展开，勾号和子菜单混在一起，语义冲突 | HIG:子菜单不超过一层;带子菜单的项不应有勾选状态;勾号只表示 on/off 或单选 | 按法提成同级单选组，放在同一个子菜单里用分隔线和不可点的小标题隔开(macOS 14+ 支持 section header)。只在 provider 不支持 hold 时显示(渐进披露) |
| 4 | **Major** | 键位列表重复两遍(触发键、它的键)，各 7 项加 "More…"，Fn 在一个列表里出现两次("Default (Fn)" 和 "Fn") | Nielsen #8 简约设计;HIG 菜单长度 | 每个列表只留"自动/同语音键"加常用 3–4 个键，其余放 config。"Default (Fn)" 和 "Fn" 合成一项 "Fn (default / 默认)" |
| 5 | **Major** | 术语:"It wants"、"Its voice key"、"Trigger key"、"Same as voice key" 都要求用户先理解存在两把键 | Nielsen #2;HIG 菜单项用名词或动宾短语，不用口语代词 | 见第 3 节重命名 |
| 6 | Minor | "Hands-free: any key stops" 用 ✓ 和上面的单选组放在一起，看起来像第三个单选项 | HIG:单选组与独立开关之间用分隔线和标题区分 | 只在 hands-free 被选中时显示，缩进或加标题 "When hands-free / 免提时" |
| 7 | Minor | 灰色警告 "Not read from 豆包输入法 — check it matches its settings" 埋在子菜单里 | Nielsen #9 帮助识别错误 | 未验证时在一级"Voice"行尾加 ⚠︎，警告上移到状态区 |
| 8 | Minor | "Show in menu bar" 放在菜单栏菜单里。一旦取消，用户就打不开这个菜单了 | Nielsen #3 用户控制与自由 | 移到 config(Bartender/Maccy 的做法);取消时提示"重新打开 App 可恢复" |
| 9 | Minor | "Open config file…" 和 "More… (edit config file)" 是同一个动作，叫法不同 | Nielsen #4 | 统一为 "Edit Config File… / 编辑配置文件…"。省略号用得对(会打开另一个窗口) |
| 10 | Minor | 一级项的 "Trigger: hands-free" 是 名词:值 形式，跟 HIG 的"把状态放进标题"相符，但冒号前后的叫法不统一 | HIG 把状态放进标题 | 统一成 "名词 — 值"，比如 "Voice: 豆包输入法" |

## 2. 重构后的菜单树

参照对象:Rectangle 和 Maccy 都是"状态/主动作在上，几个分组，Settings…/Quit 在底"，二级以下不再嵌套。Input Source Pro 把每个 app 的规则放进窗口，不放菜单。Hijack 没有窗口，config 文件就承担 Settings 窗口的角色。

```
● 轻点 右 Option 用 豆包 听写 / Tap Right Option to dictate with 豆包   [灰，状态]
  ⚠︎ 豆包的语音键未验证，请确认为 Fn / 豆包's voice key not verified — make sure it's Fn  [仅异常时]
────
  听写方式 / How you dictate                       [section header]
  ✓ 按住说话 / Hold to Talk
    轻点开始，再点停止 / Tap to Start, Tap to Stop
      ↳ ✓ 按任意键也可停止 / Any Key Also Stops     [仅免提时出现，缩进]
  快捷键 / Shortcut: 右 Option ▸
      ✓ 右 Option / Right Option
        左 Option / Left Option
        右 Command / Right Command
        Fn
      ────
        其他按键… / Other Key…  (→ 配置文件)
────
  语音来源 / Dictation Source: 豆包输入法 ▸
      ✓ 豆包输入法 / Doubao
        微信输入法 / WeType
        搜狗拼音 / Sogou            (未安装则灰)
        Handy
      ────
      豆包里的语音键 / Doubao's Voice Key            [header]
      ✓ Fn(默认 / default)
        右 Option / Right Option
        其他… / Other…
      ────
      豆包里的按法 / Doubao Starts Listening On      [header，仅不支持 hold 时]
      ✓ 按住 / Hold
        单击 / Single Tap
        双击 / Double Tap
────
  登录时启动 / Open at Login
  语言 / Language ▸   跟随系统 · English · 中文
  编辑配置文件… / Edit Config File…      ⌘,
────
  退出 Hijack / Quit Hijack              ⌘Q
```

**只放 config:** 显示菜单栏图标、扩展键位(左 Shift、右 Control 等)、非白名单输入法、超时和延迟等调优参数。Fn 作为触发键依赖默认值(provider 用 Fn 时，触发键默认"同语音键")，菜单里就不再单列 "Same as voice key" 这一项。

[Decision] 模式改成一级单选，不再藏进子菜单。依据是它和状态行直接相关，而且是用户最常切换的设置，Rectangle 也把高频项放在一级。

[Decision] provider 的键位和按法放进"语音来源"子菜单，作为同级分组，不再往下嵌套。依据是这两项是语音来源的属性，不属于用户的按键习惯，这样也保证子菜单只有一层。

## 3. 心智模型检查

普通用户会把"触发键"和"语音键"当成同一样东西，"press style" 他们也看不懂。用户脑子里的模型是"**我按哪个键 → 用谁听写**"。另外两样(对方 app 里设置的键、对方要求的按法)属于**适配细节**，应该默认由 Hijack 自动处理，只在出问题时露出来。

| 现名 | 建议(EN / 中) | 理由 |
|---|---|---|
| Trigger key | **Shortcut / 快捷键** | macOS 的标准叫法 |
| Trigger mode: hold / hands-free | **Hold to Talk / 按住说话** · **Tap to Start, Tap to Stop / 轻点开始，再点停止** | 直接描述动作。"Hands-free" 在中文里容易理解成完全不用手 |
| Voice input | **Dictation Source / 语音来源** | 和系统的 "Dictation" 对齐 |
| Its voice key | **Doubao's Voice Key / 豆包里的语音键** | 用 provider 的名字代替代词，说清楚这把键是在对方 app 里设置的 |
| It wants (press style) | **Doubao Starts Listening On / 豆包的启动方式** | 用"它怎么开始听"代替"它想要" |
| Same as voice key | 去掉，改成默认行为 | 少一个概念 |

**一句话:** 一级菜单只讲"我怎么按、用谁听写"，"对方 app 的键位和按法"收进语音来源子菜单，按 provider 渐进披露。状态行必须和当前模式一致，这是 blocker，先修。
