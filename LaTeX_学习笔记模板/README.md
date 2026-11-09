# LaTeX 学习笔记模板

用于课程笔记、专题记录和公式推导。正文按 `01-章节1.tex`、`02-章节2.tex` 等命名，只提供简短文字与排版示例。

[返回模板集](../README.md) · [脚本说明](../整理产物的脚本/README.md) · [编译配置](../docs/编译与环境配置.md) · [语法速查](../docs/语法速查.md)

## 开始使用

1. 复制本目录，用 VS Code 打开复制后的文件夹。
2. 修改 `main.tex` 中的笔记标题、作者、课程或主题、日期。
3. 替换正文和附录中的示例，按需要增删章节。
4. 执行 `latexmk main.tex`，打开 `build/main.pdf`；Windows 也可双击 `setup-latex.bat`；两个初始化脚本各自独立，任选一个即可。

需要 TeX Live 中的 XeLaTeX、latexmk、BibTeX、ctex、Fandol、natbib、gbt7714、pgfplots、tcolorbox 等组件。

## 内容结构

```text
chapters/
├── 01-正文/
│   ├── 01-章节1.tex
│   ├── 02-章节2.tex
│   ├── 03-章节3.tex
│   ├── 04-章节4.tex
│   ├── 05-章节5.tex
│   ├── 06-章节6.tex
│   ├── 07-章节7.tex
│   └── 08-章节8.tex
└── 02-附录/
    ├── 附录1-符号与关系速查.tex
    ├── 附录2-补充推导.tex
    ├── 附录3-补充材料.tex
    └── 附录4-参数说明.tex
```

章节从第 1 章开始，与文件名前缀一致。每章都可改成自己的主题；标题区与目录放在一起，正文直接开始记笔记。

保存 `.tex` 时会通过 `.vscode/build-latex.ps1` 增量编译。成功保留缓存；失败清理辅助文件后只重试一次，仍失败则报告错误。日常构建不会先清空 `build/`。

## 增删章节

复制一个正文文件，例如 `09-章节9.tex`：

```latex
% !TeX root = ../../main.tex
\chapter{章节9}
\label{chap:chapter9}
\section{学习要点}
这里记录学习内容。
```

在 `main.tex` 的正文列表中添加 `\input{chapters/01-正文/09-章节9.tex}`。附录文件在 `\noteappendix` 后载入，显示“附录一”至“附录四”。删除文件时同步删除对应的载入行。

公式、图表按章编号；附录加“附”前缀，例如 `(附2.1)`。使用 `\label`、`\ref`、`\eqref` 引用，编号随顺序自动更新。

## 编译与主文件改名

脚本可识别任意名称的主文件。可以把项目目录或 `.tex` 文件拖到 `setup-latex.bat` 上，也可明确指定：

```powershell
.\setup-latex.bat -MainFile "课程 笔记.tex"
.\setup-latex.bat -MainFile "课程 笔记.tex" -CleanOnly
```

主文件改名时，同步修改章节顶部的 `% !TeX root` 和 `latexmkrc` 中的默认文件。VS Code 配方使用实际主文件，不固定为 `main.tex`；输出文件也会跟随主文件名。

图片放入 `media/`，文献写入 `references.bib`。页面样式、数学命令、定理与可选笔记框集中在 `config/note-style.sty`。
