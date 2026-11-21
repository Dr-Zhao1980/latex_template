# LaTeX 一次初始化与永久静默编译

将**一个**初始化脚本放到主 `.tex` 所在目录：Windows 任选 `setup-latex.bat` 或 `setup-latex.ps1`；Linux / WSL 使用 `setup-latex.sh`。三者均自包含，不需要另外两个脚本，也不需要本仓库的 `src/`、`tools/` 或 `tests/`。

**Windows 默认无论成功、编译错误、参数错误，还是 BAT 启动 PowerShell / 解包失败，都保留黑色终端，按 Enter 后才结束。** PS1 也默认等待 Enter，不再使用完成弹窗。只有明确指定 `-NoPause` 或 `LATEX_SETUP_NO_PAUSE=1` 才跳过等待，供自动化使用。日常 VS Code 编译始终后台运行，不显示结束提示。

## 环境准备

- Windows 10/11：Windows PowerShell 5.1、系统 .NET Framework 4.x，以及包含 `xelatex`、`latexmk`、`xdvipdfmx` 的 TeX Live。初始化使用系统 C# 编译器生成无控制台启动器，不需要安装开发工具。也可从 PowerShell 7 启动初始化。
- Linux / Ubuntu / WSL：Bash、GNU 基础工具、util-linux 的 `flock`、原生 Linux TeX Live。合并**已有** JSONC 设置需要 Python 3，新设置可直接生成。Ubuntu 若缺少软件，可自行安装 `texlive-xetex latexmk util-linux python3`；中文、文献、字体和宏包按文档需要补充。
- VS Code / Remote-WSL：安装并启用 **LaTeX Workshop**，将项目目录作为工作区打开并信任。脚本生成项目配置，不会擅自安装编辑器、扩展或整套 TeX Live。

Windows 优先检测 PATH，也检查用户/系统 PATH、TeX 环境变量及常见安装树，动态识别年份目录，包括 `D:\APPgallery\texlive\texlive\<年份>\bin\windows`。没有固定的项目路径或 TeX Live 年份。TeX Live 内部的 Perl 可以正常使用，不强制安装独立 Perl。

## Windows 初始化

最简单：双击放在主文件旁的 `setup-latex.bat`。

```powershell
# 单独使用 PS1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-latex.ps1

# 多个主文档时指定文件，也可以把 .tex 拖到 BAT 上
.\setup-latex.bat -MainFile "课程 笔记.tex"

# 指定其他项目和 TeX 安装目录
.\setup-latex.bat -ProjectRoot "D:\项目 空格(甲)" -TeXBin "D:\软件\texlive\2027\bin\windows"

# 仅配置并归档/普通清理缓存，不要求已经安装 TeX
.\setup-latex.bat -ConfigureOnly

# 限定本项目，不调整已有的上一级工作区配置
.\setup-latex.bat -ProjectOnly

# 真实编译隔离的小文档，诊断工具链，不编译用户源码
.\setup-latex.bat -DiagnoseOnly
```

默认优先 `main.tex`，否则识别含 `\documentclass` 的主文档。多个候选时交互选择，非交互模式要求指定文件。显式选择章节时，可解析 `% !TeX root = ../main.tex`。PDF 与主文档同名。

其他参数：`-TexFile`、`-File`、`-MainFile` 是同义参数；`-NoSettings` 跳过 settings 更新但安装永久编译器；`-CleanOnly` 归档并普通清理，不编译；`-Mode build|clean|clean-all` 选择操作。

## Linux / WSL 初始化

```bash
bash setup-latex.sh
bash setup-latex.sh --file "课程 笔记.tex" --tex-bin /usr/local/texlive/2027/bin/x86_64-linux
bash setup-latex.sh --project "/home/me/项目 空格(甲)" --project-only
bash setup-latex.sh --configure-only --no-pause
bash setup-latex.sh --diagnose-only
```

SH 不调用 Windows 程序；WSL 使用 Remote-WSL 和 Linux TeX。请在对应系统初始化，Windows 与 Linux 使用各自的启动器。交互式终端下 SH 也会等待 Enter；`--no-pause` 或 `LATEX_SETUP_NO_PAUSE=1` 用于非交互调用。生成的 SH 编译器会自动设置执行权限，也可以始终通过 `bash` 调用。

## 永久编译

```text
项目/
├── 主文档.tex、references.bib、chapters/、图片等源码
├── 主文档.pdf                   最后一次成功编译的成品
├── .vscode/
│   ├── settings.json            保存后编译、手动 Build、SyncTeX
│   ├── build-latex.ps1          Windows 永久编译器
│   ├── build-latex.exe          Windows 默认无控制台启动器
│   ├── hidden-launcher.cs       启动器完整源码
│   ├── build-latex.vbs          可选的旧环境兼容入口
│   ├── latex-project.json       Windows 主文件和 TeX 路径提示
│   └── build-latex.sh           Linux 永久编译器（对应系统生成）
└── build/
    ├── 主文档.pdf、aux、bbl、log、synctex.gz 等
    ├── latexmk.stdout.log、latexmk.stderr.log
    ├── last-build-status.txt、last-clean-status.txt
    ├── setup-*.log、latex-diagnostic-report.txt
    ├── legacy/                 历史产物，保留相对子目录及独立批次
    └── settings-backups/        原配置备份
```

Linux 另保存 `.vscode/latex-main.txt` 和 `latex-bin.txt`。`.vscode/.latex-operation.lock` 是正常锁文件，运行中不要删除。

初始化成功后，可以删除所有 `setup-latex.*`，也可以删除整个 `build/` 和根目录旧 PDF。只要源码与完整 `.vscode/` 仍在，保存或点击 **Build LaTeX project** 就会重建并发布 PDF。安装路径仅作为提示，移动项目或换电脑后会重新发现工具链。

编译使用 `latexmk -norc -pdfxe -synctex=1 -outdir=build -auxdir=build`，让标准 XeLaTeX、BibTeX/Biber、MakeIndex 流程在输出目录工作，为 `\include{chapters/part}` 创建辅助目录。日常保留缓存，不强制重编译，不在失败后自动删除缓存反复重试。旧 `latexmkrc` 不修改、不执行，防止旧输出路径和命令覆盖新流程。自定义 shell-escape、minted、外部生成器或特殊索引流程需要扩展永久编译器，并遵守输出目录约定。

成功后在 `build/` 暂存并原子替换根目录 PDF。TeX 失败、PDF 被占用或发布失败时，不覆盖上次成功的成品。失败码传回 VS Code，诊断日志保留在 `build/`。

Windows 默认使用 GUI 子系统 EXE，启动隐藏 PowerShell，原生子进程也采用 `CreateNoWindow`，不依赖 VBScript 可选组件。VBS 仅为额外兼容文件。若设备策略禁止项目中的 EXE 或脚本，需要由设备管理员针对项目允许运行，工具不会关闭系统安全功能。

设置更新保留无关的配置值，支持 JSONC 注释和尾随逗号；重新序列化时不保留原注释格式。无法解析的原文件保持不变并报告错误。备份只放在 build 内。默认也修复**已存在**的上一级 `.vscode` 中的 LaTeX 设置；`-ProjectOnly` / `--project-only` 可限定本项目。更高层或 `.code-workspace` 的覆盖配置需另外核查，建议直接打开项目文件夹或加入多根工作区，再重新加载窗口。

## 主动清理

永久编译器即可清理，不依赖初始化脚本，也不要求 TeX 已安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.vscode\build-latex.ps1 -Mode clean
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.vscode\build-latex.ps1 -Mode clean-all
```

```bash
bash .vscode/build-latex.sh '' "$PWD" '' clean
bash .vscode/build-latex.sh '' "$PWD" '' clean-all
```

| 操作 | 行为 |
|---|---|
| build | 增量编译，成功后发布根目录 PDF |
| clean | 删除识别出的可再生辅助文件；保留内部及根目录 PDF、日志、归档和备份 |
| clean-all | 额外删除内部 PDF 和 TeX 日志；保留根目录 PDF、诊断日志、归档和备份 |

两种清理都保留源码、`.vscode/` 和未识别的用户文件，不直接清空 build。历史归档不会覆盖已有文件，无对应 TeX 的普通 `.log`/`.out` 不擅自迁移。初始化、清理和编译使用同一个排他锁，默认等待 120 秒；Windows 编译器可用 `-LockTimeout`，Bash 用 `LATEX_LOCK_TIMEOUT` 调整。锁超时返回 75，不改写其他操作的状态日志。

## 权限与故障排查

初始化实际检查创建、读取、修改、删除权限。默认普通用户运行，不永久修改系统 PATH、ACL、UAC 或执行策略，推荐使用自己的可写目录。

- **运行报错**：查看保留的终端、`build/latex-diagnostic-report.txt`、`setup-latex-status.log`、`latexmk.stdout.log`、`latexmk.stderr.log` 及主文件 `.log`。
- **另一台电脑找不到 TeX**：使用 `-DiagnoseOnly`，必要时 `-TeXBin` / `--tex-bin` 指定安装的 bin 目录。独立小文档会真实测试完整工具链。
- **宏包/字体缺失**：在 TeX Live Manager 安装实际需要的包，检查源码字体名、图片路径。工具不改源码。
- **PDF/配置被占用**：关闭占用程序后重试，旧成品保留。`build` 已是一个文件时会诊断冲突并保留该文件。
- **权限不足**：优先移动到可写目录。确需提权时，Windows 显式运行 `.\setup-latex.bat -Elevate`，使用标准 UAC；Linux 显式运行 `bash setup-latex.sh --sudo`。权限仅作用于本次初始化，不保存管理员凭据；只读磁盘或企业策略仍需所有者处理。Linux 提权后会将项目输出目录交还原调用用户。
- **仍执行旧配方**：确认 LaTeX Workshop 已启用、工作区正确，重新加载窗口，选择生成的 recipe，检查更高层工作区的覆盖设置。

Enter 等待适用于正常退出和可捕获错误，无法阻止操作系统强制终止、关机或用户主动关闭窗口。需要等待输入时，不要用 `-NonInteractive` 启动初始化；自动化明确加 `-NoPause`。

## 验证与维护

实际结果与平台范围见 [TEST-RESULTS.md](TEST-RESULTS.md)，原始输出在 `tests/results/`。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-setup-latex.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-build-latex.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-portability.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-windowless.ps1 -ProjectRoot "已初始化的测试项目路径"
```

```bash
bash -n setup-latex.sh
bash tests/test-bash.sh  # 模拟工具链，不等同于原生 Linux TeX 验收
```

`src/` 是可编辑的编译器/启动器源码。修改后运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/update-bundle.ps1`，将完整实现重新内嵌到三个发布脚本。安装后的永久编译器不引用本仓库。
