# LaTeX 学习笔记模板

用于学习笔记、专题报告及论文初稿的中文模板。默认内容仅包含简短占位文字、公式、定理、图表和文献引用示例。

[返回模板集](../README.md) · [编译配置](../docs/编译与环境配置.md) · [结构对应表](../docs/旧笔记迁移指南.md) · [语法速查](../docs/语法速查.md)

## 开始使用

1. 复制本目录，使用 VS Code 打开复制后的文件夹。
2. 修改 `main.tex` 顶部的标题、作者、学校、专业或课程、指导教师及日期。
3. 按需替换 `chapters/正文/` 与 `chapters/附录/` 中的简短示例。
4. 在本目录执行 `latexmk main.tex`，打开 `build/main.pdf`。

需要 TeX Live 中的 XeLaTeX、latexmk、BibTeX、ctex、Fandol、natbib、gbt7714、pgfplots、tcolorbox 等组件。Windows 用户可双击 `setup-latex.bat`；该启动文件调用同目录 `setup-latex.ps1`，完成检查、配置和编译后还会复制一份 `main.pdf` 到模板目录。

## 内容结构

```text
chapters/
├── 正文/
│   ├── 00-摘要.tex
│   ├── 01-绪论.tex
│   ├── 02-基础理论.tex
│   ├── 03-模型建立.tex
│   ├── 04-方法与推导.tex
│   ├── 05-结果与分析.tex
│   ├── 06-讨论与扩展.tex
│   └── 07-总结与展望.tex
└── 附录/
    ├── 附录1-符号与关系速查.tex
    ├── 附录2-补充推导.tex
    ├── 附录3-补充材料.tex
    └── 附录4-参数说明.tex
```

正文承载主要论述，附录放置符号速查、长推导、补充材料与参数说明。模板只保留各部分的最小示例；原始笔记另行归档，不随模板发布。

## 层级与编号

| 内容 | 默认形式 |
| --- | --- |
| 正文层级 | 第 1 章、1.1、1.1.1 |
| 前置页 / 正文页码 | 罗马数字 / 阿拉伯数字 |
| 正文公式、图、表 | 按章编号，如 `(3.1)`、图 5.1、表 5.1 |
| 附录标题 | 附录一、附录二、附录三、附录四 |
| 附录公式、图、表 | 加“附”前缀，如 `(附2.1)`、表附1.1 |
| 参考文献 | 使用 `gbt7714-numerical` 顺序编码样式 |

采用 A4、中文小四号、黑白标题及常见论文层级。页边距、字体、行距、标题、页眉页脚统一在 `config/note-style.sty` 修改；具体学校或期刊的格式仍需按其要求适配。

## 增删章节与附录

在对应目录新建 `.tex`，顶部写入：

```latex
% !TeX root = ../../main.tex
\chapter{新的标题}
\label{chap:new-topic}
\section{小节标题}
此处填写内容。
```

正文在 `main.tex` 的正文列表中添加 `\input{chapters/正文/文件名.tex}`；附录在 `\noteappendix` 后添加 `\input{chapters/附录/文件名.tex}`，附录标签建议使用 `app:` 前缀。编号由载入顺序自动生成，删改文件时同步修改列表。

正文和附录使用 `\label`、`\ref`、`\eqref` 互相引用。不要手写固定编号，也不要将 `\chapter` 放进链接或普通正文中。

## 图片、文献与可选组件

图片放进 `media/`，使用 `\includegraphics{文件名.png}`。默认示例图由 pgfplots 绘制，不需要外部图片。

将自己的文献填入 `references.bib`，正文使用 `\cite{文献键}`。当前只有一条示例；删除所有引文后，可将 `\notebibliographytrue` 改为 `\notebibliographyfalse`。

保留了 `\dimvec`、`\dimmat`、`\dimop`、`\pder` 等数学命令，以及 `noteinfo`、`notewarning`、`notequestion` 可选笔记框。写法见 [语法速查](../docs/语法速查.md)，默认论文页面不放置这些提示框。
