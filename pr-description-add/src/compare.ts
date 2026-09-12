/**
 * Normalizes text for comparison by trimming and normalizing whitespace.
 * This helps detect duplicates even with minor whitespace differences.
 */
export function normalizeText(text: string): string {
  return text
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '\n')
    .split('\n')
    .map(line => line.trimEnd())
    .join('\n')
    .trim()
}

/**
 * Canonicalizes GFM task-list markers so [x]/[X]/[ ] do not count as a
 * different block. Task labels are preserved.
 */
export function normalizeCheckboxState(text: string): string {
  return text.replace(/^(\s*-?\s*)\[(?: |x|X)\]/gm, '$1[ ]')
}
