const fs = require('fs');
const path = require('path');

const knipFile = process.argv[2] || './knip-output.json';
const dir = process.env.DIR || '.';

try {
  if (!fs.existsSync(knipFile)) {
    console.error(`::error::Knip output file not found: ${knipFile}`);
    process.exit(0); // Exit gracefully so workflow continues but with error log
  }

  const content = fs.readFileSync(knipFile, 'utf8');
  if (!content.trim()) {
    console.error('::error::Knip output file is empty');
    process.exit(0);
  }

  const data = JSON.parse(content);
  
  const unusedFiles = (data.files || []).length;
  const issues = data.issues || [];
  const unusedDeps = issues.flatMap(i => i.dependencies || []).length;
  const unusedDevDeps = issues.flatMap(i => i.devDependencies || []).length;
  const unusedExports = issues.flatMap(i => i.exports || []).length;

  // GitHub Annotations
  (data.files || []).forEach(file => console.log(`::warning file=${dir}/${file},line=1::Unused file`));
  
  issues.forEach(issue => {
    const file = issue.file || 'package.json';
    (issue.dependencies || []).forEach(dep => console.log(`::warning file=${dir}/${file},line=${dep.line || 1}::Unused dependency: ${dep.name}`));
    (issue.devDependencies || []).forEach(dep => console.log(`::warning file=${dir}/${file},line=${dep.line || 1}::Unused devDependency: ${dep.name}`));
    (issue.exports || []).forEach(exp => console.log(`::notice file=${dir}/${file},line=${exp.line || 1}::Unused export: ${exp.name}`));
  });

  // Summary for Step Summary
  const summary = [
    `## 🔍 Knip Analysis Results`,
    '',
    '| Category | Count |',
    '|----------|-------|',
    `| Unused files | ${unusedFiles} |`,
    `| Unused dependencies | ${unusedDeps} |`,
    `| Unused devDependencies | ${unusedDevDeps} |`,
    `| Unused exports | ${unusedExports} |`,
    ''
  ].join('\n');

  fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);

} catch (error) {
  console.error(`::error::Failed to process Knip results: ${error.message}`);
  process.exit(0);
}
