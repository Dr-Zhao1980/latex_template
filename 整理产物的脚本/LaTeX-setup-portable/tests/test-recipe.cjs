// Executes the actual generated tool with the same cwd/argument expansion as LaTeX Workshop.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const project = path.resolve(process.argv[2]);
const settings = JSON.parse(fs.readFileSync(path.join(project, '.vscode/settings.json'), 'utf8').replace(/^\uFEFF/, ''));
const config = JSON.parse(fs.readFileSync(path.join(project, '.vscode/latex-project.json'), 'utf8'));
const source = path.join(project, config.mainFile);
const tool = settings['latex-workshop.latex.tools'][0];
const expand = value => value.replaceAll('%DOC_EXT%', source).replaceAll('%DIR%', project);
const result = spawnSync(tool.command, tool.args.map(expand), { cwd: expand(tool.cwd), windowsHide: true, shell: false, encoding: 'utf8', timeout: 120000 });
if (result.error || result.status !== 0) {
  console.error(result.error || result.stderr || `Exit ${result.status}`);
  process.exit(1);
}
console.log('PASS: exact generated LaTeX Workshop command, cwd and arguments via Node spawn (no command placeholder expansion)');
