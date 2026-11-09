# LaTeX 编译与产物整理

**两个脚本各自独立，任选一个使用。** 把 `.bat` 或 `.ps1` 放在 LaTeX 主文件同级目录；不要求主文件叫 `main.tex`。

## 直接使用

- `.bat`：放到主文件旁双击即可，不需要同目录有 `.ps1`。
- `.ps1`：单独放到主文件旁，通过 PowerShell 运行。
- 默认以脚本所在目录为准，不会因为终端当前目录不同而处理错项目。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-latex.ps1
```

默认依次执行：

1. 识别主文件，支持中文、空格文件名与 `% !TeX root`。
2. 把散落的辅助文件及 `build/` 中的旧编译缓存归档到 `build/legacy/`，保留源码、图片和 PDF。
3. 备份并修复项目和上一级的 `.vscode/settings.json`，兼容直接打开项目或打开父目录的情况；保留无关的编辑器设置。
4. 修复项目的 `latexmkrc` / `.latexmkrc`，统一主文件、XeLaTeX、输出目录和 SyncTeX 配置。
5. 检查 TeX Live 并完成编译，输出 `build/主文件名.pdf`，项目目录另放一份同名 PDF；新辅助文件统一留在 `build/`。

`.bat` 内嵌完整实现；运行时的临时 PowerShell 文件会自动清除。两个版本具有相同功能。

## 可选参数

`.bat` 与 `.ps1` 支持相同参数：

```powershell
# 多个主文件时，明确选择一个
.\setup-latex.bat -MainFile "课程 笔记.tex"

# 指定其他目录或文件，也可以直接拖到 .bat 上
.\setup-latex.bat "D:\学习资料\我的笔记\课程 笔记.tex"

# 清理并修复配置，暂不编译；不需要 TeX Live
.\setup-latex.bat -ConfigureOnly

# 只清理旧辅助文件，不修改配置、不编译
.\setup-latex.bat -CleanOnly

# 只修复项目目录的配置，跳过上一级目录
.\setup-latex.bat -ProjectOnly
```

配置文件的原版保存在同目录的 `.backup-时间戳` 文件中。重复运行不会反复追加配置块。编译失败时，已完成的清理和配置修复仍然生效，错误日志保留在 `build/`。

主文件改名后应同步更新章节中的 `% !TeX root` 路径，再运行任意一个脚本。默认使用 XeLaTeX，完整编译需要 TeX Live 与 latexmk 4.86 或更新版本。

回归测试会分别创建只有 `.bat` 或只有 `.ps1` 的项目，检查独立运行、旧产物归档、项目与父目录配置、命令行配置、实际编译及失败处理：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-setup-latex.ps1
```
