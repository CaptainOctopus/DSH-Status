# DSH Status 工具集 — 交付清单

> 生成时间：2026-08-30 17:09（路径与目录布局于 2026-08-31 更新）
> 项目根：`~/WorkBuddy/DSH-status/`（源码统一在 `src/` 下，为唯一真源）
> 冒烟测试：10/10 全通过（退出码 0）

DSH Status 是一套**纯本地、只监听 127.0.0.1 的个人小工具**，由三部分组成：
1. 菜单栏原生 app（Objective-C，状态栏显示内存占用 + 一键启停模型服务）
2. 网页控制台（http.server 后端 + 深色前端，可展开查看各模型权重/常驻状态）
3. 命令行管理脚本（统一封装启停、状态、扫描逻辑）

所有交付物均已实盘落盘，路径经 `ls` 一一核实存在。

---

## A. 项目源码（单一真源，工作区）

| 文件（相对项目根） | 作用 | 大小 |
|------|------|------------|
| `src/dsh-manager.sh` | 命令行管理脚本（软链名 `dshctl`）：status / mem / models / web start\|stop / load / unload / omlx_scan / model_weights / config-harness / config-workbuddy 等 | 29.6 KB |
| `src/dsh-web-control.py` | 网页控制台后端 :8899（软链名 `dshweb`），零额外依赖，纯标准库 | 14.9 KB |
| `src/dsh-control.html` | 网页控制台前端（深色 UI，模型可 ▸/▾ 展开层级，⟳ 手动重扫） | 11.5 KB |
| `src/dsh-smoke-test.py` | 回归冒烟测试（10 项非侵入检查，锁核心契约） | 10.5 KB |
| `src/dsh-menubar/DSHStatus.m` | 菜单栏 app 源码（Objective-C + Cocoa） | 36.3 KB |
| `src/dsh-menubar/DSHStatus.swift` | Swift 备选源码（本机 CLT 修好 `SwiftBridging` 重定义后可启用） | 10.1 KB |
| `src/dsh-menubar/build.sh` | 一键编译打包脚本（编译 → 组装 .app → ad-hoc 签名 → 生成 dmg 含 AppIcon） | 5.6 KB |
| `src/dsh-menubar/make_icon.py` | 应用图标源脚本（深蓝紫 squircle + 发光青蓝波形 + 三个绿点） | 2.7 KB |
| `src/dsh-menubar/AppIcon.icns` | 生成的应用图标（16~1024 各尺寸 10 张） | 278 KB |
| `src/dsh-menubar/DSHStatus` | 已编译二进制（与 app 内一致，可独立运行；arm64，编译零警告） | 96.1 KB |

> 模型权重**不在本仓库内**（约 29 GB），原存放于旧工作区  
> `~/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab/models`（Hermes-4-14B / Qwen3.5-4B / Qwen3.5-9B）  
> 与 `~/WorkBuddy/2026-08-28-23-12-48/llamacpp-models`，由 `dsh-manager.sh` 按候选列表自动探测。  
> **2026-08-31 更新**：上述权重已移入废纸篓（`~/.Trash/mlx-agent-lab-20260831`、
> `~/.Trash/llamacpp-models-20260831`），本机现为 model-less 状态，可随时拖回原位恢复。

---

## B. 安装到系统的产物（直接使用的入口）

| 路径 | 说明 |
|------|------|
| `~/Applications/DSH Status.app` | 菜单栏 app（已签名，`LSUIElement=true` 隐藏 Dock 图标，自带 AppIcon.icns） |
| `~/.local/bin/dshctl` → `~/WorkBuddy/DSH-status/src/dsh-manager.sh` | 命令行入口软链（已在 PATH） |
| `~/.local/bin/dshweb` → `~/WorkBuddy/DSH-status/src/dsh-web-control.py` | 网页控制台入口软链（已在 PATH） |
| `~/Library/LaunchAgents/com.rory.dshstatus.plist` | 登录自启（仅 Aqua 会话；`KeepAlive/SuccessfulExit=false`：崩溃自动重启、主动退出不复活） |

> 系统安装的三处均**软链/指向工作区源码**，源码是唯一真源。重编译 `build.sh` 或改脚本后，软链与 plist 无需改动。

---

## C. 运行依赖（隔离环境，本机自带）

| 路径 | 用途 |
|------|------|
| `~/.workbuddy/binaries/python/envs/default/bin/python3` | 跑 `dsh-web-control.py` / `dsh-smoke-test.py`（Python 3.13.12 隔离 venv） |
| `/Users/rory_zhang/.workbuddy/binaries/node/versions/22.22.2/bin/node` | 跑 DSH Web（:3080） |

> 菜单栏 app 经 `NSTask` 调脚本时，已显式把 managed node / python 注入 PATH，不受 GUI 会话缺 PATH 影响。

---

## 端口地图

| 端口 | 服务 |
|------|------|
| 3080 | DSH Web（Harness） |
| 8000 | oMLX（单进程，--model-dir 含三个子模型，按需 + LRU 加载） |
| 8001 | llamacpp qwen3-8b（Qwen3-8B-abliterated） |
| 8002 | llamacpp qwen3-14b（Qwen3-14B-abliterated） |
| 8899 | 网页控制台（DSH Status Web） |

### 一键配置到其他应用

- **DeepSeekHarness（DSH Web）**：点击「→Harness」按钮 / 菜单「⚙ 配置到 DeepSeekHarness」即可直接改写 `~/.dsh/settings.yaml` 的 `agent-default-model`（保留注释）。
- **WorkBuddy**：点击「⚙WB」按钮 / 菜单「⚙ 配置到 WorkBuddy」，即直接把该模型 upsert 进 `~/.workbuddy/models.json`（vendor=Custom 分组，重启 WorkBuddy 后下拉即出现），无需手动粘贴。

---

## 日常使用

```bash
# 菜单栏：开机自启，或双击 ~/Applications/DSH Status.app
# 网页控制台：
dshweb            # 启动后端，然后浏览器开 http://127.0.0.1:8899
# 命令行：
dshctl status     # 看整体状态
dshctl config-harness [model_id]   # 把本地模型配置为 DeepSeekHarness(DSH Web)默认模型
dshctl config-workbuddy [model_id] # 直接写入 WorkBuddy 自定义模型库（~/.workbuddy/models.json）
dshctl help       # 全部子命令
dshctl web start  # 单独起 DSH Web
dshctl mem        # 内存占用（与系统监视器口径对齐）
# 改完任何一块做回归验证：
python3 ~/WorkBuddy/DSH-status/src/dsh-smoke-test.py
#   --quiet 仅打印 FAIL + 汇总；退出码 0 = 全过，非 0 = 有失败
```

---

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.rory.dshstatus
rm -rf "$HOME/Applications/DSH Status.app" \
       "$HOME/Library/LaunchAgents/com.rory.dshstatus.plist"
# 软链可选清理：
rm -f ~/.local/bin/dshctl ~/.local/bin/dshweb
# 源码保留在 ~/WorkBuddy/DSH-status/，确认不再需要时可整体删除
# ⚠️ 但请勿删除 ~/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab 与 llamacpp-models
#    （约 29 GB 模型权重，仍被 dsh-manager.sh 探测引用）
```

---

## 冒烟测试覆盖项（10 项）

1. `dsh-manager.sh help`：退出码 0 且非空
2. `omlx_scan`：每行 `name|GB` 且 GB>0，覆盖磁盘模型目录
3. `model_weights`：含 llamacpp 双模型 + oMLX 子模型（解析 5 个）
4. `mem`：已用% ∈ [0,100] 且总/已用 > 0（与系统监视器口径一致）
5. `status`：退出码 0
6. 网页 `/api/status`：结构完整 + oMLX 层级（`sub` 为 `{name,weight,resident}` 对象数组）
7. 网页 `/api/rescan`：返回 weights 字典（清缓存重扫）
8. 网页 `/api/action`：安全探测（仅对「已停止」模型发 unload，no-op，绝不误杀在跑模型）
9. `DSHStatus.m`：`clang -fsyntax-only -framework Cocoa` 语法检查通过
10. 菜单栏二进制：存在且 `codesign` 有效

> 设计原则=非侵入：只读命令不动状态；控制台仅在未运行时拉起临时实例做探针并保持运行；不触碰 :3080/:8000/:8001/:8002 启停。
>
> **model-less 降级（2026-08-31 新增）**：本机无模型权重时，第 2、3、7 项的「权重完整性」断言
> 自动跳过（结果标注 `[model-less: ...]`），只校验命令与接口可正常返回，纯监控机器上仍为 10/10。
> 模型目录可用环境变量 `DSH_MODELS_DIR` 覆盖；指向含子目录的位置时断言会重新生效。

---

## 可移植安装包（2026-08-30 新增）

**目标**：产出一个不依赖本机 WorkBuddy 安装路径的安装包，拷到任意 Mac 即可用。

### 交付物
| 路径 | 说明 |
|------|------|
| `DSH-Status.dmg`（项目根目录，~41MB） | 可分发安装包，内含自包含 `DSH Status.app` |
| `dist/DSH Status.app` | 自包含 app（编译产物，`python` 已内联进 `Contents/Resources/`） |

### 自包含改造要点
- **去掉全部写死路径**：
  - `DSHStatus.m`：用 `[[NSBundle mainBundle] resourcePath]` 定位 `dsh-manager.sh` / `dsh-web-control.py` 与内联 `python`；`runManager`/`openWeb` 的 PATH 改为优先用 bundle 内 python（node 不打包）。
  - `dsh-manager.sh`：`WORKSPACE` 改为由脚本自身位置推导（`${BASH_SOURCE[0]}`），`OMLX_*` 改为环境变量可覆盖。
  - `dsh-web-control.py`：shebang 改 `#!/usr/bin/env python3`；`SCRIPT` 改为相对 `__file__`。
- **内联 python 解释器**：`~/.workbuddy/binaries/python/versions/3.13.12`（unix 布局，已验证可整体搬迁，仅用 stdlib）拷入 `Contents/Resources/python/`。
- **运行时自注册登录自启**：`setupAutoStart` 首次运行写 `~/Library/LaunchAgents/com.rory.dshstatus.plist`（指向 app 实际路径）并 `launchctl load`，无需安装器。

### 另一台 Mac 安装方式
1. 把 `DSH-Status.dmg` 拷过去 → 打开 → 拖 `DSH Status.app` 到「应用程序」。
2. 双击启动（首次运行自动注册登录自启）。
3. 若 Gatekeeper 报「已损坏」：`xattr -dr com.apple.quarantine /Applications/DSH\ Status.app`（个人机器间自用）。
4. **无需** WorkBuddy / 独立 python / node；model-less 机器上只显示内存 + 服务状态。

### 重新打包
```bash
cd ~/WorkBuddy/DSH-status/src/dsh-menubar
bash build.sh                # 生成 dist/DSH Status.app + DSH-Status.dmg
bash build.sh --install-local# 额外装到本机 ~/Applications 并启动
```

### 已验证（纯内部资源，无外部依赖）
- bundled python 自定位 `prefix = .../Resources/python` ✅
- bundled python 启动 bundled `dsh-web-control.py` → `:8899/api/status` HTTP 200 ✅
- bundled `dsh-manager.sh mem` 正常（vm_stat，无外部依赖）✅
- bundled `dsh-manager.sh omlx_scan` 无模型目录时优雅空输出、exit 0 ✅

