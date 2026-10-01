import path from 'node:path'
import process from 'node:process'
import {pathToFileURL} from 'node:url'

// The committed ncc bundle reads Knip and JUnit files from the process
// working directory. A node24 action starts in the workspace, so move to dir
// before loading it.
const workspace = process.env.GITHUB_WORKSPACE
if (!workspace) {
  process.stderr.write('::error::GITHUB_WORKSPACE is not set\n')
  process.exit(1)
}

const dir = process.env.INPUT_DIR || '.'
process.chdir(path.resolve(workspace, dir))

await import(
  pathToFileURL(path.join(import.meta.dirname, '../dist/index.js')).href
)
