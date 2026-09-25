// Preserve command strings for auditing reported counts and protocol compliance.
// This does not execute agent JavaScript, infer loop execution, or count prose.
const fs = require('node:fs');
const path = require('node:path');
const out = path.resolve(__dirname, '..');
const repo = path.resolve(out, '../../..');
const ts = require(path.join(repo, 'node_modules/typescript'));
const schedule = JSON.parse(fs.readFileSync(path.join(__dirname, 'schedule.json'), 'utf8'));
const rows = [];
for (const [run] of schedule) {
  const file = path.join(out, 'evidence', `${run}-usage.json`);
  if (!fs.existsSync(file)) continue;
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  const commands = [];
  for (const call of data.tool_calls) {
    if (call.name === 'exec_command' || call.name.endsWith('__exec_command')) {
      const args = JSON.parse(call.arguments);
      commands.push({timestamp: call.timestamp, call_id: call.call_id, command: args.cmd, literal: true});
      continue;
    }
    if (call.name !== 'exec') continue;
    const ast = ts.createSourceFile('call.js', call.input || call.arguments || '', ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    function visit(node) {
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) && node.expression.name.text === 'exec_command') {
        const args = node.arguments[0];
        if (args && ts.isObjectLiteralExpression(args)) {
          const prop = args.properties.find(p => ts.isPropertyAssignment(p) && (p.name.text || p.name.getText(ast)) === 'cmd');
          if (prop) {
            const value = prop.initializer;
            const literal = ts.isStringLiteral(value) || ts.isNoSubstitutionTemplateLiteral(value);
            commands.push({timestamp: call.timestamp, call_id: call.call_id, command: literal ? value.text : value.getText(ast), literal});
          }
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(ast);
  }
  fs.writeFileSync(path.join(out, 'evidence', `${run}-commands.json`), JSON.stringify(commands, null, 2) + '\n');
  const row = {run, extracted_exec_command_calls: commands.length, nonliteral_commands: commands.filter(c => !c.literal).length};
  for (const action of ['check', 'capture', 'dev']) {
    const regex = new RegExp('(?:^|\\n)\\s*npx\\s+--no-install\\s+weaver\\s+' + action + '\\b', 'g');
    row[`${action}_literal_command_lines`] = commands.filter(c => c.literal).reduce((n, c) => n + [...c.command.matchAll(regex)].length, 0);
  }
  rows.push(row);
}
fs.writeFileSync(path.join(out, 'evidence', 'command-audit.json'), JSON.stringify(rows, null, 2) + '\n');
console.log(JSON.stringify(rows));
