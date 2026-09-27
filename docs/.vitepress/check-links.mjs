import { readdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function markdownFiles(directory) {
  return readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name))
    .flatMap((entry) => {
      const path = resolve(directory, entry.name)
      if (entry.isDirectory()) {
        return ['.vitepress', 'node_modules'].includes(entry.name) ? [] : markdownFiles(path)
      }
      return entry.isFile() && entry.name.endsWith('.md') ? [path] : []
    })
}

const binary = process.env.LEMON_DOCS_LINK_CHECK_BIN || resolve(docsRoot, 'node_modules/.bin/markdown-link-check')
const result = spawnSync(binary, [
  '--config', resolve(docsRoot, '.mlc.json'),
  '--quiet',
  ...markdownFiles(docsRoot),
], { cwd: docsRoot, stdio: 'inherit' })

if (result.error) console.error(result.error.message)
process.exit(result.status ?? 1)
