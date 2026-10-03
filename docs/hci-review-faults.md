# HCI review: fault signals (2026-10-03)

Question: when a fault happens, can the user tell, and can the user tell what to do?

## 1. Scope and method

This review grades the "Signal" column of `docs/fmea.md` (code: main at a329863). It covers every FM row with S >= 3, and FM-11 as a control.
I read `docs/fmea.md`, `docs/usage.md`, `docs/hci-review-2.md`, `docs/hci-review-menu.md`, `Sources/Menu.swift`, `Sources/Settings.swift`, `Sources/AppState.swift`, `Sources/Engine.swift` and `Sources/CLI.swift`.
To check claims, I also read `Sources/InputSource.swift`, `Sources/Config.swift`, `Sources/Shared.swift`, `Sources/Core/SessionMachine.swift`, `Sources/Core/Stats.swift` and `assets/com.zl190.hijack.relauncher.plist`.
I did not run the app. All statements about behavior come from the code.

Terms in this document:

- **Signal surface**: the menu bar icon, the menu, the "Try it" area, a user notification, `hijack status`, `hijack doctor`.
- **Record surface**: `hijack log` and `hijack stats`. The FMEA "Detection" column grades these. This review does not count them as a signal.
- **Key listener**: the event tap. The CLI uses this word (`Sources/CLI.swift:121`).
- **VISIBLE**: a signal surface names the fault and the next step, at the latest when the user first looks after the harm.
- **LATE**: a signal surface names the fault, but only after the dictation ends. Or only a window or command that the user must open first names it.
- **SILENT**: no signal surface names the fault, or a signal surface shows a wrong state.

Facts that apply to many rows:

- The menu bar icon never changes. The app sets one template image once (`Sources/Menu.swift:92-101`).
- The menu shows only three fault lines: no Accessibility (`Sources/Menu.swift:125-126`), config error (`Sources/Menu.swift:132-133`), and talk key not read (`Sources/Menu.swift:136-138`). Otherwise its first line always says the shortcut works (`Sources/Menu.swift:127-130`).
- The menu rebuilds each time it opens (`Sources/Menu.swift:107-110`). A new menu line costs no polling.
- "Try it" is visible only while the Settings window is open (`Sources/Settings.swift:299-317`). The 1 Hz refresh of that window is a named cause of FM-26 (`docs/fmea.md:106`, `Sources/Settings.swift:43`). Thus "Try it" cannot be the main fault surface.
- `state.json` gets its values only in `Engine.start` (`Sources/Engine.swift:352`, `:379`, `:383`). Nothing writes it after a later fault.
- The app posts no user notification today. No source file uses `UNUserNotificationCenter`.
- `docs/usage.md` has one troubleshooting paragraph (`docs/usage.md:41`). It covers only "the trigger does nothing".

## 2. Signal today, per row

| FM | What the user sees at the moment of the fault | Time until the user notices (estimate) | What the user can do today | Verdict |
|---|---|---|---|---|
| FM-01 | Nothing. The menu still says "按住\(key)用\(name)听写" / "Hold \(key) to dictate with \(name)" (`Menu.swift:130`). If Settings is open, "Try it" stays "正在听…" / "Listening…" after the release (`Settings.swift:54`). | Next keystroke in any app. The user cannot link the wrong keys to Hijack. | Press and release the shortcut once. The press counts as a repeat (`Engine.swift:339`); the release ends the session (`Engine.swift:340-341`, `SessionMachine.swift:69-70`). No surface says this. `usage.md` says nothing. | SILENT |
| FM-02 | Nothing. `hijack status` prints "key listener    active" (`CLI.swift:121`). `hijack doctor` prints "✓ key listener installed" (`CLI.swift:144`). Both are wrong, because `handle` re-enables without a check and writes no state (`Engine.swift:302-306`). | Next shortcut press. Nothing happens. | `usage.md:41`: "If the trigger does nothing, confirm that Hijack has Accessibility permission … Run `hijack doctor`". Doctor reports all good. Quit and reopen works, but no surface says so. | SILENT |
| FM-03 | Nothing. The summary adds "secure input on" (`Engine.swift:286`), but no dictation starts, so no summary is written. | Next shortcut press. Nothing happens. | `usage.md:41` points to Accessibility and `hijack doctor`. Both look correct. The user has no path to the cause. | SILENT |
| FM-04 | Nothing. In toggle mode `reconcile` does not stop the session (`Engine.swift:298`). | Next press: the press is lost, or a bare modifier key-up reaches the app. | Press the shortcut again. | SILENT |
| FM-05 | "Try it": "切到\(detail)…" / "Switching to \(detail)…" (`Settings.swift:53`), then "正在听…" / "Listening…" (`Engine.swift:154`, `Settings.swift:54`). The second text is wrong. The macOS dictation panel or the emoji picker opens. | At once, but the visible effect points to macOS, not to Hijack. | Nothing documented. | SILENT |
| FM-07 | Only in "Try it": "等上屏 X 秒，已切回 \(prev)" / "waited Xs for the text, back to \(prev)" (`Engine.swift:248`). It names the wrong source as if correct. The macOS input menu changes. | First keystroke after the dictation. | Switch the input source by hand. | LATE |
| FM-08 | "Try it" shows "正在听…" / "Listening…" with moving bars (`Settings.swift:54`, `:307`). Nobody listens. After release it shows the normal "已切回" / "back to" text (`Engine.swift:248`). | After release, when no text arrives (2.5 s to 5 s). | Nothing documented. | SILENT |
| FM-09 | Same as FM-08. | Same as FM-08. | `usage.md:41`: "confirm … that your selected voice tool works on its own". | SILENT |
| FM-10 | The Hijack menu bar icon goes away with the process. Nothing names the held modifier. `hijack status` prints "not running" (`CLI.swift:118`). Nothing restarts Hijack after a crash: the relauncher acts only when the binary changes (`assets/com.zl190.hijack.relauncher.plist:3-5`, `:18`). | Next keystroke in any app. | Nothing documented. Reopening Hijack does not release the modifier (`fmea.md:90`). | SILENT |
| FM-14 | The input source changes back. The text does not appear. "Try it" shows "等上屏 5.0 秒，已切回 \(prev)" / "waited 5.0s for the text, back to \(prev)" (`Engine.swift:248`). This reads as a success. | At once: the text does not appear. | The Advanced tab has "最多等文字上屏" / "Longest wait for the text" with the hint "说长段话时可以调大" / "Raise it for long dictations" (`Settings.swift:443`). No fault surface points there. | SILENT |
| FM-15 | Same "Try it" text as FM-14, after the fixed wait. | At once, or when the user types into the voice tool. | `hijack doctor` prints "⚠︎ can watch \(p.name)'s window to know when the text is in" with "\(p.name) isn't running now; Hijack falls back to waiting \(c.fallbackDelay)s" (`CLI.swift:155-157`). This helps only if the tool is still not running. | LATE |
| FM-16 | "Try it" shows "已切回 \(prev)" / "back to \(prev)" (`Engine.swift:248`). This is wrong: the check comes 0.1 s later (`InputSource.swift:33-35`), and nobody checks the retry. The macOS input menu still shows the voice tool. | First keystroke after the dictation. | Switch the input source by hand. | SILENT |
| FM-21 | Key absent: the menu shows "⚠︎ 读不到\(name)里的说话键，请在「语音来源」里选" / "⚠︎ Can't detect \(name)'s talk key — pick it under Voice Source" (`Menu.swift:138`). Settings shows "⚠︎ 没读到，请录制" / "⚠︎ Not found — record it" (`Settings.swift:366`). Doctor prints ✗ (`CLI.swift:149`). Key wrong: nothing. | Absent: when the user opens the menu. Wrong: after release, when no text arrives. | Absent: the menu line says what to do. Wrong: nothing. | VISIBLE (key absent) / SILENT (key wrong) |
| FM-24 | At launch: the Settings window opens and macOS shows its prompt (`Menu.swift:45-49`). The menu shows "⚠︎ 需要辅助功能权限，点这里去允许…" / "⚠︎ Needs Accessibility permission — Allow…" (`Menu.swift:126`). "Try it" shows "还没有辅助功能权限" / "No Accessibility permission yet" (`Settings.swift:301`). Revoked while running: the menu line appears, but `hijack status` still prints "allowed" (`CLI.swift:120`). | At launch: at once. Revoked: next shortcut press. | `usage.md:41` and the menu line. | VISIBLE |
| FM-25 | Nothing. The sleep and wake observers only write log lines (`Menu.swift:27-35`). | First keystroke after wake. | Press the shortcut again. | SILENT |
| FM-26 | Nothing. Typing lags in every app. Only `hijack stats` counts "slow key events" (`CLI.swift:307`). | During typing. The user cannot link the lag to Hijack. | Nothing documented. | SILENT |
| FM-11 (control) | "Try it": "切到\(detail)…", then "说完了，等文字上屏…" / "Done talking, waiting for the text…" (`Settings.swift:55`), then "等上屏 2.5 秒，已切回…" after `fallbackDelay` (`SessionMachine.swift:69-70`, `Engine.swift:230`, `:248`). No menu line. The input source flips to the voice tool for about 2.5 s. | Not a fault. | Hold the key longer. | Quiet (correct), "Try it" text misleading |

Notes on the FMEA "Signal" column. Three cells do not match the code:

- FM-24 says the menu shows "waiting for Accessibility" via `state.json`. That string does not exist. The menu reads `AXIsProcessTrusted()` directly (`Menu.swift:125`). Only the CLI reads `state.json`.
- FM-05 says "switching" shows in "Try it" with no error. After the key is sent, "Try it" changes to "Listening…", which is wrong (`Engine.swift:154`).
- FM-16 says "Menu bar shows the IME". That is the macOS input menu, not a Hijack surface. The Hijack surface ("Try it") says the restore worked.

## 3. Changes for SILENT and LATE rows

The changes use four surfaces that exist: the menu bar icon, the first lines of the menu, the "Try it" lines, and `hijack status` / `hijack doctor`.
The CLI has no `L()` calls (`CLI.swift`, 0 matches), so CLI wording is English only. `L()` adds spaces between Chinese and Latin text (`Shared.swift:22`), so the Chinese strings below have none.

### 3.1 Menu bar icon: three states (FM-01, FM-02, FM-04, FM-24, FM-25)

The icon exists but carries no state (`Menu.swift:92-101`). Give it three states. Set each state after the key-listener callback returns, so that the change adds no time to FM-26.

| State | When | Accessibility description (zh / en) |
|---|---|---|
| Idle | No dictation, key listener on | "Hijack" / "Hijack" |
| Active (filled) | Hijack holds the talk key, or a toggle session runs | "Hijack：正在听写" / "Hijack: dictating" |
| Off (slashed) | No Accessibility, or the key listener is off | "Hijack：快捷键无效" / "Hijack: shortcut not working" |

A stuck talk key (FM-01, FM-25) or a stuck toggle session (FM-04) then shows as "Active" after the user lets go. A dead key listener (FM-02) shows as "Off".

### 3.2 Menu first lines (FM-01, FM-02, FM-03, FM-04, FM-25)

Add these lines above the normal status line, in the style of `Menu.swift:126`. Show each line only while its condition is true.

| FM | Condition when the menu opens | zh | en | Click |
|---|---|---|---|---|
| FM-02 | Key listener off after the retry | ⚠︎ 系统关掉了按键监听，快捷键无效，点这里重新打开 Hijack | ⚠︎ macOS turned off the key listener; the shortcut does nothing — Reopen Hijack | Relaunch |
| FM-01, FM-04, FM-25 | A session is active, and the shortcut is up on the keyboard (hold mode) | ⚠︎ Hijack 还按着\(talkKey)，点这里松开 | ⚠︎ Hijack is still holding \(talkKey) — Release | Release the talk key, end the session |
| FM-04 (toggle) | A toggle session is active | 正在听写，点按\(key)停止 | Dictating — tap \(key) to stop | None |
| FM-03 | Secure Event Input is on | ⚠︎ \(app)开着安全输入（常见于密码框），关掉前快捷键无效 | ⚠︎ \(app) has Secure Input on (often a password field). The shortcut won't work until it's off | None |

When the app name for FM-03 is unknown, use "另一个 app" / "Another app".
The normal line ("按住\(key)用\(name)听写") must not appear while the FM-02 line shows. Today it claims the shortcut works (`Menu.swift:130`).

### 3.3 Last-dictation line (FM-05, FM-07, FM-08, FM-09, FM-14, FM-15, FM-16, FM-21 key wrong)

The engine already knows the cause when it writes the summary: echo, mic tool, window, and restore result (`Engine.swift:271-287`). "Try it" already has a "last" line (`Settings.swift:39`, `:313`).
Put the cause text in three places:

1. The "Try it" last line, in place of "已切回" / "back to".
2. A menu line "⚠︎ 上次听写：<cause>" / "⚠︎ Last dictation: <cause>". It stays until a dictation ends with the outcome "text arrived".
3. A `hijack status` line `  last dictation  <cause>` (English).

"Try it" must not say "已切回" / "back to" until the switch is confirmed (FM-16, `Engine.swift:247-248`, `InputSource.swift:33-35`).

| FM | Summary marker | zh cause | en cause |
|---|---|---|---|
| FM-05 | input source never switched (after FMEA action 5) | 没能切到\(voice)，这次没有听写 | Couldn't switch to \(voice); nothing was dictated |
| FM-07 | started inside the voice tool (after FMEA action 4) | 本来就在\(voice)，没有切回 | You were already in \(voice), so Hijack didn't switch back |
| FM-08 | echo missing | 没能按下\(voice)的说话键\(talkKey) | Couldn't press \(voice)'s talk key (\(talkKey)) |
| FM-09, FM-21 key wrong | echo present, mic tool off | \(voice)没有开始听。请确认它的说话键是\(talkKey) | \(voice) didn't start listening. Check that its talk key is \(talkKey) |
| FM-14 | window never closed | 等了\(t)秒文字还没上屏，已切回。可在「高级 › 最多等文字上屏」调大 | No text after \(t) s, so Hijack switched back. Raise Advanced › Longest wait for the text |
| FM-15 | window while held: not running | 没看到\(voice)的窗口，固定等了\(t)秒。请运行 hijack doctor | Hijack didn't see \(voice)'s window and waited a fixed \(t) s. Run hijack doctor |
| FM-16 | restore didn't stick after the retry | 没能切回\(prev)，现在还是\(voice)。请用输入法菜单切换 | Couldn't switch back to \(prev); you're still in \(voice). Switch with the input menu |

FM-14 uses the exact label from `Settings.swift:443`. Keep one word for one concept: "说话键" / "talk key", as in `Settings.swift:359`.

For FM-08 and FM-09 there is also a live signal. The engine samples the mic every 0.5 s while the key is held (`Engine.swift:253-266`). When the tool's mic reads "off" for 1 s, "Try it" shows "\(voice)还没开始听…" / "\(voice) isn't listening yet…" and the bars stop. When the mic reads "nil", keep "正在听…" / "Listening…", because FM-12 says the probe can be wrong.

### 3.4 `hijack status` and `hijack doctor` tell the truth (FM-02, FM-24, FM-26)

- FM-02: `state.json` must change when the key listener goes off (FMEA action 2). Then `hijack status` prints `  key listener    OFF — macOS turned it off; quit and reopen Hijack`. `hijack doctor` prints ✗ with the same fix (`CLI.swift:144`).
- FM-24, revoked while running: `state.json` must change when Accessibility goes away. Today `hijack status` prints "allowed" (`CLI.swift:120`).
- FM-26: `hijack status` prints `  slow key events N today (last HH:MM)` when N > 0. `hijack doctor` prints ⚠︎ "keys were slow N times today". Its fix line: "close the Hijack Settings window when you don't use it; if it continues, report it with `hijack log`". The fix text follows the cause in `docs/fmea.md:106`.

FM-26 gets no live signal. A live signal would need work on the main thread, and that thread is the cause.

### 3.5 FM-10: the app is dead

No Hijack surface exists between the crash and the next launch. Two changes:

1. Add to the Troubleshooting section of `docs/usage.md`: "If keys type symbols after Hijack quits, press and release \<talk key\> once. Then open Hijack." Chinese text is not needed, because `usage.md` is English. The "press and release" step is not verified (see §6).
2. After FMEA action 1 clears the key at start, `hijack status` prints `  last start      released a stuck <key>` until the next start.

### 3.6 User notifications: only FM-02

The task allows a notification only for S=5 rows: FM-01, FM-02 and FM-10.

- **FM-02: yes.** The app is alive. The fault blocks the main function until the user acts. The user may not see the menu bar: a full-screen app hides it, and `showMenuBarIcon` can remove the icon (`Menu.swift:102-103`). Post one notification when the retry fails, and at most one per launch.
  - Title: "Hijack 的快捷键失灵了" / "Hijack's shortcut stopped working".
  - Body: "系统关掉了按键监听，重试也没成功。点这里重新打开 Hijack。" / "macOS turned off the key listener, and the retry failed. Click to reopen Hijack."
- **FM-01: no.** Hijack does not know at the moment of the fault, so it cannot send a notification at the right time. If Hijack can detect the stuck key, it must release the key, not report it. The user notices the wrong keys at once. The "Active" icon and the menu line then give the cause and the step.
- **FM-10: no.** A dead process cannot post. At the next launch, FMEA action 1 has already released the key, so the user has nothing to do. The `hijack status` line records the event.

## 4. Rows that must stay quiet

- **FM-11 (a tap shorter than `holdDelay`).** This is by design. The icon, the menu and notifications must not change. `hijack stats` already keeps it out of the success rate (`Stats.swift:13`, "too short to start"). Today "Try it" says "等上屏 2.5 秒，已切回…", which claims a wait for text that never existed. Change it to a neutral line with no ⚠︎: "按得太短，没有开始听写" / "Too short; dictation didn't start".
- **FM-26 in the live UI.** See §3.4. A per-event signal adds main-thread work to the cause.
- **A normal tap-disable that `reconcile` fixes.** The FMEA log shows two on 2026-10-03 (`docs/fmea.md:59`). When the re-enable works and the key state agrees, the user has nothing to do. Show nothing. Only the failed retry (FM-02) gets a signal.
- **FM-12, FM-13, FM-22, FM-23** have S < 3. They are diagnostic. They stay in the log.

## 5. Ranked changes for 1.1.4

1. **Key listener off: icon "Off", menu line, true `hijack status`, one notification** (FM-02; also FM-24 revoked). Depends on FMEA action 2.
   - When the key-listener retry fails, the menu bar icon shall show the "Off" state within 2 s.
   - When the menu opens while the key listener is off, the menu shall show the FM-02 line from §3.2 as its first line.
   - When the key-listener retry fails, Hijack shall post one user notification within 2 s, and no more than one per launch.
   - When the key listener is off, `hijack status` shall print "key listener    OFF" and `hijack doctor` shall exit 1, within 2 s.
2. **Icon "Active" state and the "still holding" menu line** (FM-01, FM-04, FM-25).
   - When Hijack posts the talk-key press, the menu bar icon shall show the "Active" state within 100 ms.
   - When Hijack posts the talk-key release, the menu bar icon shall show the "Idle" state within 100 ms.
   - When the menu opens while a session is active and the shortcut is up, the menu shall show the §3.2 "still holding" line first.
3. **Last-dictation cause in "Try it", the menu and `hijack status`** (FM-05, FM-07, FM-08, FM-09, FM-14, FM-15, FM-16, FM-21 key wrong).
   - When a dictation summary carries a marker from the §3.3 table, "Try it" shall show the matching cause text within 500 ms.
   - When a dictation fails, the menu shall show "⚠︎ 上次听写：<cause>" / "⚠︎ Last dictation: <cause>" until a dictation ends with "text arrived".
   - When the restore switch is not confirmed, "Try it" shall not show "已切回" / "back to".
4. **Secure Input menu line and status line** (FM-03).
   - When the menu opens while Secure Event Input is on, the menu shall show the FM-03 line from §3.2 as its first line.
   - When Secure Event Input is on, `hijack status` shall print "secure input    on" with the app name when known.
5. **FM-10 recovery text** (FM-10). Depends on FMEA action 1.
   - When Hijack starts and releases a stuck modifier, `hijack status` shall print "last start      released a stuck <key>" until the next start.
   - The Troubleshooting section of `docs/usage.md` shall give the manual step for a stuck modifier after Hijack quits.

## 5a. Decision (owner, 2026-10-03)

Rule used: a surface that says something false must change. A fault with no signal from any other party, where the documented path leads the user wrong, must get a signal. The rest is optional and goes in only when it adds no main-thread work.

| Item | Decision | Why |
|---|---|---|
| 1, menu line + true `hijack status` / `doctor` | In. Required | The menu and the CLI say the shortcut works when it does not |
| 1, icon "Off" state | In | Changes at most twice per launch. No main-thread cost |
| 1, user notification | Out | The user finds out at the next press. The menu line then names the step |
| 2, icon "Active" state | Out | The voice tool's own window already shows listening. An icon change on each talk-key edge adds main-thread work (FM-26) |
| 2, "still holding" menu line | In | Cheap. It appears only when `reconcile` finds the key up and a session active |
| 3, the two false "Try it" texts | In. Required | "正在听…" with nobody listening and "已切回" before the check are false |
| 3, cause table in "Try it", menu, status | Out | Optional. Trigger to revisit: seven days of `hijack stats` on 1.1.4 |
| 4, Secure Input menu line + status line | In | One call when the menu opens. Without it the documented path points to Accessibility, which is wrong |
| 5, `usage.md` manual step | In. Required | FMEA action 1 covers only the case where Hijack starts again |
| 5, `hijack status` "last start" line | Out | Optional |

Acceptance lines for the items that are in stay as written in §5. The icon has two states: Idle and Off.

## 6. Gaps: what the code alone cannot show

- **Notice times** in §2 are estimates from the effect. No user study or screen recording supports them.
- **Manual release of a stuck modifier (FM-10).** The code cannot show that one physical press and release clears a modifier from a dead process. Test it before the `usage.md` text ships.
- **One press and release clears FM-01.** The code shows this path (`Engine.swift:339-341`). I did not run it. The fault-injection test FI-1 must show it, because the menu line in §3.2 and any help text depend on it.
- **Secure Input owner.** I do not know if the app can name the process that holds Secure Input without extra cost. If it cannot, use "另一个 app" / "Another app".
- **Notification permission.** A notification needs the user's consent. I cannot tell how macOS treats the first request from an accessory app at fault time. If the user denies it, FM-02 falls back to the icon and the menu line.
- **Revoked Accessibility while running (FM-24).** I cannot tell from code whether macOS disables the key listener with an event, or stops it silently. This decides which code path must update `state.json`.
- **Icon cost.** I cannot measure from code whether an icon change on each talk-key edge adds time to the main thread. Measure it with the signposts before 1.1.4 ships.
- **Mic probe (FM-12)** decides if the live "isn't listening yet" text in §3.3 is safe. A false "off" reading would alarm the user during a good dictation.
