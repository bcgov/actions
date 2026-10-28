import { describe, it, expect, vi, beforeEach } from 'vitest';
import { analyzeDeptry, analyzeMaven } from '../src/deps.js';
import fs from 'node:fs';
import * as core from '@actions/core';

vi.mock('node:fs');
vi.mock('@actions/core');

describe('analyzeDeptry', () => {
  beforeEach(() => vi.clearAllMocks());

  it('counts and annotates deptry violations by code', () => {
    fs.readFileSync.mockReturnValue(
      JSON.stringify([
        { error: { code: 'DEP002', message: "'requests' defined as a dependency but not used" }, module: 'requests', location: { file: 'pyproject.toml', line: 9 } },
        { error: { code: 'DEP001', message: "'yaml' imported but missing" }, module: 'yaml', location: { file: 'app/main.py', line: 3 } }
      ])
    );
    const stats = analyzeDeptry('deptry-output.json', 'backend');
    expect(stats.totalIssues).toBe(2);
    expect(stats.byCode).toEqual({ DEP002: 1, DEP001: 1 });
    expect(core.warning).toHaveBeenCalledWith(expect.stringContaining('DEP001'), expect.objectContaining({ file: 'backend/app/main.py', startLine: 3 }));
  });

  it('treats an empty file as no issues', () => {
    fs.readFileSync.mockReturnValue('');
    expect(analyzeDeptry('x.json', '.').totalIssues).toBe(0);
  });
});

describe('analyzeMaven', () => {
  beforeEach(() => vi.clearAllMocks());

  it('parses used-undeclared and unused-declared sections', () => {
    fs.readFileSync.mockReturnValue(
      [
        '[INFO] --- dependency:3.11.0:analyze (default-cli) @ app ---',
        '[WARNING] Used undeclared dependencies found:',
        '[WARNING]    org.slf4j:slf4j-api:jar:2.0.16:compile',
        '[WARNING] Unused declared dependencies found:',
        '[WARNING]    org.springframework.boot:spring-boot-starter-web:jar:3.4.0:compile',
        '[WARNING]    org.postgresql:postgresql:jar:42.7.4:runtime',
        '[INFO] BUILD SUCCESS'
      ].join('\n')
    );
    const stats = analyzeMaven('dependency-analyze.log', 'backend');
    expect(stats.totalIssues).toBe(3);
    expect(stats.byCode).toEqual({ 'Used undeclared': 1, 'Unused declared': 2 });
    expect(core.warning).toHaveBeenCalledWith(expect.stringContaining('slf4j-api'), expect.objectContaining({ file: 'backend/pom.xml' }));
  });

  it('reports nothing for a clean build', () => {
    fs.readFileSync.mockReturnValue('[INFO] No dependency problems found\n[INFO] BUILD SUCCESS');
    expect(analyzeMaven('x.log', '.').totalIssues).toBe(0);
  });
});
