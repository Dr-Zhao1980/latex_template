# 实际验证记录

验证日期：2026-11-21（Asia/Shanghai）。这里区分真实运行、模拟测试和未验证范围；未在另一台实体电脑上执行测试。

## 当前环境

- Windows，系统版本 `10.0.26300.0`。
- Windows PowerShell `5.1.26100.9818`；另通过 PowerShell `7.6.9` 的仅配置测试。
- TeX Live 2026，latexmk `4.88`，XeTeX `0.999998`，实际使用 BibTeX。
- 本机 LaTeX Workshop `10.19.0` 源码核对，并按生成的 command / cwd / args 通过 Node `spawn` 执行完整配方。
- Git Bash `5.3.15` 用于 SH 语法与模拟流程测试。当前没有可运行的 WSL Linux 发行版。

## 通过的测试

| 测试 | 实际结果 | 原始输出 |
|---|---|---|
| BAT 与 PS1 分别单独复制到项目后运行 | 各 7 组，共 14 组通过；真实 XeLaTeX 和 BibTeX | `tests/results/windows-integration.txt` |
| Enter 保留终端 | 8 个场景通过；输入 Enter 前进程保持运行，输入后返回正确状态 | `tests/results/windows-enter.txt` |
| 主文件选择、搬移项目、失效安装提示、最小 PATH、文件占用 | 5 组通过 | `tests/results/windows-portability.txt` |
| 无可见 Shell 窗口 | EXE 的 PE 子系统确认为 GUI；构建期间枚举可见窗口未发现新构建终端 | `tests/results/windows-windowless.txt` |
| 原样执行 VS Code 配方 | 通过 Node spawn，按真实 cwd、command、args 执行，未对 command 进行占位符替换 | `tests/results/windows-recipe.txt` |
| PowerShell 7 入口 | 生成配置、编译 GUI 启动器、运行清理模式成功 | `tests/results/powershell7.txt` |
| Bash 逻辑 | 3 组模拟流程通过，`bash -n` 通过 | `tests/results/bash-simulated.txt` |

14 组 Windows 真实编译回归覆盖：

1. 首次初始化及已有 `.vscode` / `build` 的重复初始化。
2. 中文、空格、括号、方括号、`&`、`!` 路径，多点号中文主文件名。
3. `\include` 子目录、目录、交叉引用、参考文献、SyncTeX 文件输出。
4. 根目录和章节目录旧辅助文件归档；保留普通用户日志和资料。
5. JSONC 注释/尾随逗号解析、保留无关配置、修复旧外部编译命令。
6. 未修改源码时，内部 PDF 时间戳保持不变；发布文件通过原子替换更新。
7. 删除隐藏启动器后重复初始化能修复，settings 保持幂等。
8. 删除初始化脚本、整个 build 及根目录 PDF 后，永久 GUI 启动器重新完成编译。
9. 真实 TeX 错误经 GUI 入口返回非零退出码，根目录旧 PDF 的 SHA256 不变。
10. Windows 文件锁阻止 PDF 发布时安全失败，保留原文件。
11. clean-all 与已有操作锁互斥，超时返回 75。
12. clean、clean-all 保留成品和诊断信息，深度清理后可以重建。

8 个 Enter 测试包括 BAT/PS1 的成功、缺少源码、未知参数，以及 BAT 的 PowerShell 缺失和解包失败。测试使用保持打开的标准输入，确认进程在输入 Enter 前不退出。

## 修复的主要原因

- 完成弹窗不能兑现“终端按 Enter 后再关闭”；改为独立入口收尾，BAT 还覆盖解包和解释器启动失败。
- PowerShell 部分路径接口会将方括号解释为通配符；相关进程与文件操作改为 .NET 字面路径接口。
- 重复初始化曾因永久 PS1 未变化而提前返回，漏装缺失的隐藏启动器；现在分别检查组件。
- 旧编译流程缺少统一排他锁，PDF 直接覆盖也可能损坏成品；现在对初始化/编译/清理加锁并原子发布。
- 文档与测试曾使用代码未实现的参数，并依赖仓库外的模板；现在测试从当前发布脚本生成独立项目。
- 新默认隐藏启动器不依赖 VBScript 可选组件。
- LaTeX Workshop 对工具参数和 cwd 展开占位符，command 保持原值，因此 Windows 工具使用相对命令 `./.vscode/build-latex.exe` 和正确 cwd。已核对[官方编译计划实现](https://raw.githubusercontent.com/James-Yu/LaTeX-Workshop/master/src/compile/plan.ts)。输出参数依照 [latexmk 官方说明](https://mirrors.ctan.org/support/latexmk/latexmk.txt)。

## 未验证范围

- 未在第二台实体 Windows 电脑、Windows 10、MiKTeX 或受企业策略限制的设备实测。
- 未在原生 Linux / WSL 执行真实 TeX 编译、原生 flock 竞争、sudo/UAC 提权或文件所有权修复。Git Bash 缺少 flock，模拟测试用的是显式标注的替身，不能作为 Linux 互斥验收结果。
- 未自动操作实际 VS Code 的保存、重开窗口或 PDF 正反向搜索界面。已验证生成配置和完整配方执行，以及 SyncTeX 文件存在；界面操作仍需目标机确认。
- 本轮真实文献编译测试使用 BibTeX，未单独测试 Biber、特殊索引、minted 或自定义外部命令。

请在目标机器上解压后使用其中的新脚本。若仍有问题，保留终端内容与 build 中的诊断日志，足以定位环境、权限或文档依赖差异。
