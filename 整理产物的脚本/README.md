# LaTeX 编译与产物整理

两个文件放在一起使用，不要求主文件名为 `main.tex`。

- 将项目文件夹或主 `.tex` 文件拖到 `setup-latex.bat` 上即可运行。
- 不带参数时，查找当前目录、脚本目录及脚本上一级中的 LaTeX 主文件；支持嵌套目录。
- 根据 `\documentclass` 和 `% !TeX root = ...` 识别主文件，跳过编译目录、备份和垃圾箱。
- 找到多个主文件时列出候选，需指定入口，不会自行选择第一个。

```powershell
# 自动查找指定目录中的主文件
.\setup-latex.bat "D:\学习资料\我的笔记"

# 指定文件，支持中文和空格
.\setup-latex.bat "D:\学习资料\我的笔记\课程 笔记.tex"

# 一个项目中有多个主文件时，明确选择入口
.\setup-latex.bat -ProjectRoot "D:\学习资料\我的笔记" -MainFile "课程 笔记.tex"

# 只整理辅助文件，不编译、不改 VS Code 配置，也不需要安装 TeX Live
.\setup-latex.bat "D:\学习资料\我的笔记" -CleanOnly
```

默认使用 XeLaTeX。PDF 按主文件名生成，例如 `build/课程 笔记.pdf`，项目目录另放一份同名 PDF；辅助文件留在 `build/`。散落的旧辅助文件归档到 `build/legacy/`，保留源码、图片和 PDF。

自动生成的 VS Code 配方使用当前主文件，重命名后不会继续寻找旧的 `main.tex`。移动主文件到其他目录时，需同步更新章节中的 `% !TeX root` 路径。

也可使用 PowerShell 直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup-latex.ps1 "项目目录" -NoDialog
```

运行回归检查（需要 TeX Live）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test-setup-latex.ps1
```
