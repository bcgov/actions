import fs from 'node:fs'
import path from 'node:path'
import * as core from '@actions/core'

/**
 * Annotates deptry JSON output (deptry --json-output).
 * @param {string} outputFile - Path to the deptry JSON file
 * @param {string} baseDir - App/package directory for annotation paths
 * @returns {{totalIssues: number, byCode: object}}
 */
export function analyzeDeptry(outputFile, baseDir) {
  const content = fs.readFileSync(outputFile, 'utf8')
  const data = content.trim() ? JSON.parse(content) : []
  const items = Array.isArray(data) ? data : []
  const byCode = {}
  items.forEach(item => {
    const code = item.error?.code || 'DEP'
    byCode[code] = (byCode[code] || 0) + 1
    const loc = item.location || {}
    core.warning(`${code} ${item.error?.message || item.module}`, {
      file: path.join(baseDir, loc.file || 'pyproject.toml'),
      title: `deptry: ${code}`,
      startLine: loc.line || 1
    })
  })
  return {totalIssues: items.length, byCode}
}

/**
 * Annotates Maven dependency:analyze log output.
 * @param {string} logFile - Path to the mvn log
 * @param {string} baseDir - App/package directory for annotation paths
 * @returns {{totalIssues: number, byCode: object}}
 */
export function analyzeMaven(logFile, baseDir) {
  const lines = fs.readFileSync(logFile, 'utf8').split(/\r?\n/)
  const byCode = {}
  let section = ''
  let total = 0
  for (const line of lines) {
    const text = line.replace(/^\[WARNING\]\s?/, '')
    if (/Used undeclared dependencies found/.test(text)) {
      section = 'Used undeclared'
    } else if (/Unused declared dependencies found/.test(text)) {
      section = 'Unused declared'
    } else if (/Non-test scoped test only dependencies found/.test(text)) {
      section = 'Test-only, non-test scope'
    } else if (section && /^\[WARNING\]\s+\S+:\S+:\S+/.test(line)) {
      const dep = text.trim()
      byCode[section] = (byCode[section] || 0) + 1
      total++
      core.warning(`${section} dependency: ${dep}`, {
        file: path.join(baseDir, 'pom.xml'),
        title: `Maven: ${section} dependency`,
        startLine: 1
      })
    } else {
      section = ''
    }
  }
  return {totalIssues: total, byCode}
}
