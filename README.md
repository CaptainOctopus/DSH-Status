# DSH Status

> 纯本地、只监听 `127.0.0.1` 的本地模型后端监控与管理工具集（菜单栏 app + 网页控制台 + 命令行）。

在你自己机器上跑多个本地大模型后端（oMLX / llama.cpp / DSH Web）时，  
**DSH Status** 把它们统一收拢到一个地方：菜单栏一眼看内存与状态、网页里逐层展开看每个模型的权重占用、命令行一键启停与配置。

- 菜单栏原生 App（Objective-C + Cocoa）：状态栏实时显示内存占用，下拉可一键启停各后端
- 网页控制台（`:8899`，零额外依赖，纯标准库）：模型层级可展开，手动重扫
- 命令行脚本（`dshctl`）：`status` / `mem` / `models` / `load` / `unload` / `config-harness` / `config-workbuddy`
- 一键把本地模型配置到 **DeepSeekHarness（DSH Web）** 或生成 **WorkBuddy** 可粘贴配置
- 自包含安装包 `DSH-Status.dmg`：内联 Python，拷到任意 Mac 拖进「应用程序」即用，无需本机 WorkBuddy / Python / Node

---

## 功能特性

| 模块     | 说明                                                                       |
| ------ | ------------------------------------------------------------------------ |
| 内存监控   | 菜单栏实时显示已用内存%（`vm_stat`，与系统监视器口径一致）                                       |
| 后端监控   | oMLX `:8000`、llama.cpp `:8001`/`:8002`、DSH Web `:3080`、控制台 `:8899` 存活与状态 |
| 模型权重视图 | 逐模型权重 / 常驻内存，父（omlx 服务）—子（9B/4B/Hermes-14B）层级展开                          |
| 一键启停   | 菜单栏 / 网页 / 命令行都能拉起或停掉指定后端或模型                                             |
| 一键配置   | → Harness 改写 `settings.yaml`；📋WB 复制 WorkBuddy「添加模型」字段                   |
| 登录自启   | 首次运行注册 LaunchAgent（崩溃自重启、主动退出不复活）                                        |
| 跨机可移植  | `DSH-Status.dmg` 自包含，model-less 机器上也能只看内存与状态                             |

---

## 架构与端口

```
┌─────────────┐   ┌──────────────┐   ┌──────────────┐
│ 菜单栏 App   │   │ 网页控制台     │   │ 命令行 dshctl  │
│ (DSHStatus)  │   │  :8899        │   │ (dsh-manager) │
└──────┬──────┘   └──────┬───────┘   └──────┬───────┘
       │                 │                  │
       └─────────────────┴──────────────────┘
                         │ 统一调用
                         ▼
              ┌──────────────────────────────┐
              │  dsh-manager.sh (统一封装)      │
              └──────────────┬───────────────┘
                             │ 启停 / 探测
        ┌──────────┬─────────┼──────────┬──────────┐
        ▼          ▼         ▼          ▼          ▼
     oMLX:8000  llamacpp  llamacpp  DSH Web:3080  模型目录
                :8001     :8002     (Harness)
```

| 端口   | 服务                                                         |
| ---- | ---------------------------------------------------------- |
| 3080 | DSH Web（DeepSeekHarness）                                   |
| 8000 | oMLX（单进程，`--model-dir` 含 9B/4B/Hermes-14B 子模型，按需 + LRU 加载） |
| 8001 | llama.cpp Qwen3-8B-abliterated                             |
| 8002 | llama.cpp Qwen3-14B-abliterated                            |
| 8899 | 网页控制台（DSH Status Web，本工具自带）                                |

> 所有端口均绑定 `127.0.0.1`（loopback）。按本机个人工具的安全约定，**无需鉴权**；  
> 仅当误配为 `0.0.0.0` 暴露到局域网/公网时才需要鉴权。

---

## 目录结构

```
DSH-Status/
├── README.md                 # 本文件（项目总结）
├── MANIFEST.md               # 交付清单（含冒烟测试覆盖项）
├── DSH-Status.dmg            # 自包含安装包（核心交付物，拷到任意 Mac 即用）
├── dsh-manager.sh            # 命令行管理脚本（软链名 dshctl）
├── dsh-web-control.py        # 网页控制台后端 :8899（纯标准库）
├── dsh-control.html          # 网页控制台前端（深色 UI）
├── dsh-smoke-test.py         # 回归冒烟测试（10 项非侵入检查）
└── dsh-menubar/              # 菜单栏 app 源码
    ├── DSHStatus.m           # Objective-C + Cocoa 源码
    ├── DSHStatus.swift       # Swift 备选源码
    ├── DSHStatus             # 已编译二进制（可由 build.sh 重新生成）
    ├── build.sh              # 一键编译打包：编译 → 组装 .app → 签名 → 出 dmg
    ├── make_icon.py          # 应用图标生成脚本
    ├── AppIcon.icns          # 应用图标（16~1024 各尺寸）
    └── icon_1024.png         # 图标源图
```

> 注：`dist/DSH Status.app` 为 `build.sh` 的编译产物，不纳入版本库（可重建）；  
> 模型权重（`llamacpp-models/`、`mlx-agent-lab/models/`）属于数据，不随源码分发。

---

## 快速开始（在本机已部署模型的环境下）

```bash
# 网页控制台
python3 dsh-web-control.py          # 然后浏览器打开 http://127.0.0.1:8899

# 命令行
./dsh-manager.sh status             # 看整体状态
./dsh-manager.sh mem                # 内存占用
./dsh-manager.sh models             # 已注册模型
./dsh-manager.sh help               # 全部子命令

# 菜单栏
open "dist/DSH Status.app"          # 或执行 dsh-menubar/build.sh --install-local
```

---

## 构建自包含安装包

```bash
cd dsh-menubar
bash build.sh                # 生成 dist/DSH Status.app + 上级 DSH-Status.dmg
bash build.sh --install-local   # 额外装到本机 ~/Applications 并启动
```

`build.sh` 会把 Python 解释器内联进 `Contents/Resources/python/`，app 用  
`[[NSBundle mainBundle] resourcePath]` 定位脚本与资源，因此**可整体拷到任意 Mac**。  
`python` 仅用标准库、unix 布局，已验证可整体搬迁。

---

## 跨机安装（不带走模型）

1. 把 `DSH-Status.dmg` 拷到目标 Mac → 打开 → 拖 `DSH Status.app` 到「应用程序」。
2. 双击启动（首次运行自动注册登录自启）。
3. 若 Gatekeeper 报「已损坏」：
   ```bash
   xattr -dr com.apple.quarantine /Applications/DSH\ Status.app
   ```
4. **无需** WorkBuddy / 独立 Python / Node；model-less 机器上只显示内存 + 服务状态。

### 模型文件放哪里？

`DSH-Status.dmg`  intentionally 不含模型权重（太大），启动模型时需要让 app 找到它们。  
`dsh-manager.sh` 会按以下优先级自动探测（**第一个含有实际模型文件的目录生效**）：

| 后端 | 探测路径（按优先级） |
| ---- | ------------------- |
| oMLX | `DSH Status.app/Contents/Resources/mlx-agent-lab/models` |
|      | `~/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab/models` |
|      | `~/.dsh/models/omlx` |
| llama.cpp | `DSH Status.app/Contents/Resources/llamacpp-models` |
|           | `~/WorkBuddy/2026-08-28-23-12-48/llamacpp-models` |
|           | `~/.dsh/models/gguf` |

**推荐做法（保持工作区不移动）**：保留原来的 `mlx-agent-lab/models/` 和 `llamacpp-models/`，安装后的 app 会自动回退到这些目录加载模型。  
**跨机/干净环境**：在目标 Mac 上新建 `~/.dsh/models/omlx` 和 `~/.dsh/models/gguf`，把 `.safetensors`/`.gguf` 模型文件放进去即可。

如果模型找不到，菜单栏点击「启动」后会弹窗提示具体缺失路径，不再静默失败。

---

## 一键配置到其他应用

- **DeepSeekHarness（DSH Web）**：点「→Harness」或菜单「⚙ 配置到 DeepSeekHarness」，  
  直接改写 `~/.dsh/settings.yaml` 的 `agent-default-model`（行级替换，**保留注释**）。
  ```bash
  ./dsh-manager.sh config-harness [model_id]   # 支持模糊匹配，写前自动备份
  ```
- **WorkBuddy**：点「📋WB」或菜单「📋 复制 WorkBuddy 配置」，生成并复制  
  「添加模型」对话框所需字段（自定义 / endpoint `http://localhost:8000/v1/chat/completions`  
  / 模型名 / 工具调用✅），粘贴到 WorkBuddy 设置 → 模型 → 添加模型 → 自定义 即可。

---

## 回归验证（冒烟测试 10/10）

```bash
python3 dsh-smoke-test.py          # 全量；退出码 0 = 全过
python3 dsh-smoke-test.py --quiet  # 仅打印 FAIL + 汇总
```

覆盖：`help` / `omlx_scan` / `model_weights` / `mem` / `status` / 网页 `status`·`rescan`·`action`  
（安全探测，绝不误杀在跑模型）/ `DSHStatus.m` 语法检查 / 菜单栏二进制签名有效。

设计原则 = **非侵入**：只读命令不动状态；控制台仅在未运行时拉起临时实例做探针并保持运行；  
不触碰 `:3080/:8000/:8001/:8002` 启停。

---

## 卸载

```bash
launchctl bootout gui/$(id -u)/com.rory.dshstatus
rm -rf "$HOME/Applications/DSH Status.app" \
       "$HOME/Library/LaunchAgents/com.rory.dshstatus.plist"
# 软链（若曾建）：
rm -f ~/.local/bin/dshctl ~/.local/bin/dshweb
```

---

## 环境要求

- macOS 11+（菜单栏 app 为 Apple Silicon / Intel 通用编译目标，本机 M1 Pro 验证）
- 命令行：`bash` 3.2+、`curl`、`clang`（仅重编译 app 时需要）、`codesign`（签名用）
- 网页控制台：Python 3.9+（纯标准库，无第三方依赖）
- 模型后端：oMLX / llama.cpp / DSH Web 按需安装，工具本身不捆绑模型

---

## 许可证

个人工具，随源码提供，按现状使用（无明示担保）。如需正式许可证可后续补充。

