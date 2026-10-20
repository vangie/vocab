# 生词 Vocab

像系统「词典」一样简洁的 macOS 查词工具，多了**生词本**和**背单词**。

- **同一批词典**：直接读取系统词典服务里的词典——内置词典和 `~/Library/Dictionaries` 里自己装的（如朗文 LDOCE5、麦克米伦），不复制、不转换。
- **发音在任何视图都能播放**：词典里的发音按钮（`javascript:new Audio(...)` 或 `<audio>` + `onmousedown`）由原生 AVAudioPlayer 播放，「全部」视图里也能播。
- **三指轻点查词**：可选接管系统的三指查词，在光标旁弹出释义，一键「加入生词本」；关掉开关即恢复系统原设置。
- **生词本 + 间隔重复**：本地 SQLite 存储，FSRS-6 调度（默认参数，可调目标记忆率与学习步长）；可导出 CSV。
- **背单词**：看词想意思、看意思选词、看词选意思、拼写、音节拆分、词根词缀混合出题，易混词做干扰项；答题快慢映射为「忘了 / 模糊 / 记得 / 简单」四档。
- **深色模式**、中文界面。

> v1 不含 AI 释义和同步，代码里留好了接口（`WordExplainer`、`WordbookSync`）。

## 构建与运行

需要 macOS 14+、Xcode（Swift 6）。

```bash
make app        # 生成 build/Vocab.app
open build/Vocab.app
make test       # 单元测试
make smoke      # 无界面冒烟测试：查词、渲染截图、播放发音
```

不会自动安装到「应用程序」，需要的话自己把 `build/Vocab.app` 拖过去。

## 三指查词与权限

在「设置 › 通用」打开「接管三指查词」：

1. 关闭系统「触控板 › 查询与数据检测器 › 三指轻点」（写入 `com.apple.AppleMultitouchTrackpad` 与 `com.apple.driver.AppleBluetoothMultitouch.trackpad` 的 `TrackpadThreeFingerTapGesture = 0`，以及 `-currentHost` 全局域的 `com.apple.trackpad.threeFingerTapGesture = 0`，再调用 `activateSettings -u` 立即生效）。
2. 原值会先保存；关闭开关或退出「生词」时自动恢复，下次启动再接管。
3. 读取光标下的单词需要「辅助功能」权限，首次使用会弹出系统提示。

三指手势通过私有框架 `MultitouchSupport` 识别，词典内容通过私有 `DCS*` 接口读取，所以本应用无法上架 App Store，系统大版本更新后可能需要适配。

### 稳定签名（推荐）

临时（ad-hoc）签名每次构建都会变，macOS 会因此作废「辅助功能」授权。运行一次：

```sh
scripts/setup-signing.sh   # 在独立钥匙串中创建自签名身份 "Vocab Local Signing"，不碰登录钥匙串，无弹窗
make app                   # 之后自动用它签名
```

之后重新授权一次辅助功能，以后重新构建就不必再授权了。也可以用 `VOCAB_SIGN_IDENTITY` 指定其他身份。

### 本地图标

把自己的 1024px PNG 放到 `Local/AppIcon.png`（不纳入版本库），`make app` 会用它替换默认图标。

## 项目结构

| 路径 | 说明 |
|---|---|
| `Sources/VocabCore` | 词典服务封装、HTML 处理、发音、生词本、调度算法、手势与辅助功能 |
| `Sources/CMultitouch` | MultitouchSupport 回调与三指轻点识别（C） |
| `Sources/Vocab` | SwiftUI 界面、查词浮窗、设置 |
| `Sources/vocab-smoke` | 命令行冒烟测试工具 |
| `Tests/VocabCoreTests` | 单元测试 |

---

## English

**Vocab** is a minimal macOS dictionary app in the spirit of Apple's Dictionary.app, with a wordbook and spaced-repetition review.

- Reads the **same dictionaries** as the system (built-in plus `~/Library/Dictionaries`) through DictionaryServices' private `DCS*` API and renders each entry in a WKWebView with its own stylesheet.
- Dictionary **audio plays everywhere**, including the combined "All" view: speaker clicks are routed to AVAudioPlayer.
- Optional **three-finger tap takeover**: disables the system Look Up tap gesture (original values are saved and restored), detects taps with `MultitouchSupport`, reads the word under the pointer via the Accessibility API, and shows a Look-Up-style panel with an "add to wordbook" button.
- **Wordbook** in SQLite with FSRS-6 scheduling (default parameters, adjustable desired retention and learning steps), CSV export. Dark mode. Chinese UI.
- **Review** mixes recall, meaning↔word multiple choice, spelling, syllable and root questions with confusable distractors; answer speed maps to four grades.

Build: `make app` → `build/Vocab.app`. Tests: `make test`. Headless smoke test: `make smoke`.

Uses private frameworks, so it cannot ship on the Mac App Store. MIT licensed.

### Local icon

Put your own 1024px PNG at `Local/AppIcon.png` (gitignored) to override the icon locally; `make app` picks it up.

### Stable signing (recommended)

Ad-hoc signatures change on every build, which invalidates the Accessibility grant. Run `scripts/setup-signing.sh` once: it creates a self-signed "Vocab Local Signing" identity in a dedicated keychain (login keychain untouched, no prompts), and `make app` then signs with it. Grant Accessibility once more; later rebuilds keep the grant. `VOCAB_SIGN_IDENTITY` overrides the identity.



## Install / deploy

    make install

Builds a release, signs it (local signing identity if set up by `scripts/setup-signing.sh`, otherwise
ad-hoc), quits the running app, replaces `/Applications/Vocab.app` (`INSTALL_DIR=~/Applications` to
override), clears quarantine, registers it with LaunchServices and relaunches. Safe to run repeatedly;
data in `~/Library/Application Support/Vocab` is never touched. With an ad-hoc signature macOS may ask
for Accessibility permission again after an install — the app's permission guide opens when needed.
