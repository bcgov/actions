const core = require('@actions/core');
const github = require('@actions/github');
const fs = require('fs');
const path = require('path');

/**
 * Find CODEOWNERS file case-insensitively in GitHub-recognized locations
 * GitHub searches in order: root, .github/, docs/ (use first found)
 * @returns {string|null} Path to CODEOWNERS file or null if not found
 */
function findCodeownersFile() {
  const locations = [
    '.', // root
    '.github',
    'docs'
  ];

  for (const location of locations) {
    try {
      const dirPath = path.join(process.cwd(), location);
      if (!fs.existsSync(dirPath)) {
        continue;
      }

      const files = fs.readdirSync(dirPath);
      const codeownersFile = files.find(file => 
        file.toLowerCase() === 'codeowners'
      );

      if (codeownersFile) {
        const fullPath = path.join(location, codeownersFile);
        core.info(`Found CODEOWNERS at: ${fullPath}`);
        return fullPath;
      }
    } catch (error) {
      core.debug(`Error searching ${location}: ${error.message}`);
    }
  }

  core.info('No CODEOWNERS file found');
  return null;
}

/**
 * Extract assignees from CODEOWNERS file
 * @param {string} codeownersPath - Path to CODEOWNERS file
 * @returns {string[]} Array of usernames (without @ prefix)
 */
function extractAssignees(codeownersPath) {
  try {
    const codeownersContent = fs.readFileSync(codeownersPath, 'utf8');
    
    // Filter out comment lines (lines starting with #) and empty lines
    const lines = codeownersContent.split('\n')
      .map(line => line.trim())
      .filter(line => line && !line.startsWith('#'));
    
    // Extract usernames from CODEOWNERS (format: * @username or path @username)
    // NOTE: This intentionally extracts all usernames across all lines, regardless of path patterns.
    // This ensures deployment failures are visible to all repository maintainers, not just path-specific owners.
    // 
    // Regex breakdown:
    // - Matches @username or @org/team-name
    // - GitHub usernames: alphanumeric start/end, can contain hyphens/underscores in middle
    // - Pattern: @(username) or @(org/team-name)
    const usernameMatches = lines.join('\n').match(/@([a-zA-Z0-9](?:[a-zA-Z0-9_-]*[a-zA-Z0-9])?(?:\/[a-zA-Z0-9](?:[a-zA-Z0-9_-]*[a-zA-Z0-9])?)?)/g);
    
    if (usernameMatches) {
      // Remove '@', filter out team references (those containing '/')
      // Teams cannot be assigned to issues, only individual users
      const assignees = [...new Set(usernameMatches
        .map(m => m.substring(1))
        .filter(name => !name.includes('/'))
      )];
      
      core.info(`Found ${assignees.length} unique user(s) in CODEOWNERS`);
      return assignees;
    }
    
    core.info('No users found in CODEOWNERS');
    return [];
  } catch (error) {
    core.warning(`Could not read or parse CODEOWNERS: ${error.message}`);
    return [];
  }
}

/**
 * Create an issue for deployment failure
 * @param {Object} octokit - GitHub API client
 * @param {Object} context - GitHub context
 * @param {string} zone - Deployment zone
 * @param {string} workflowRunId - Workflow run ID
 * @param {string[]} assignees - Array of assignees
 */
async function createIssue(octokit, context, zone, workflowRunId, assignees) {
  const workflowUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${workflowRunId}`;
  const title = `ci(deploy): deployment failed in ${zone}`;
  const body = `❌ Deployment to **${zone}** zone failed.\n\n[View workflow run](${workflowUrl})`;

  // GitHub Issues API limits assignees to 10 per issue
  const maxAssignees = 10;
  const assigneesToUse = assignees.slice(0, maxAssignees);
  
  if (assignees.length > maxAssignees) {
    core.warning(`${assignees.length} assignees found, limiting to first ${maxAssignees}`);
  }

  try {
    const issue = await octokit.rest.issues.create({
      owner: context.repo.owner,
      repo: context.repo.repo,
      title: title,
      body: body,
      assignees: assigneesToUse
    });
    
    core.info(`Created issue #${issue.data.number} for deployment failure${assigneesToUse.length > 0 ? ` (assigned to: ${assigneesToUse.join(', ')})` : ''}`);
    core.setOutput('issue_number', issue.data.number);
    core.setOutput('issue_url', issue.data.html_url);
  } catch (error) {
    // If assignment fails due to permissions, retry without assignees but mention them
    if (error.status === 422) {
      core.warning(`Could not assign users: ${error.message}`);
      const bodyWithMentions = `${body}\n\ncc: ${assigneesToUse.map(u => `@${u}`).join(' ')}`;
      
      try {
        const issue = await octokit.rest.issues.create({
          owner: context.repo.owner,
          repo: context.repo.repo,
          title: title,
          body: bodyWithMentions
        });
        
        core.info(`Created issue #${issue.data.number} (mentioned: ${assigneesToUse.join(', ')})`);
        core.setOutput('issue_number', issue.data.number);
        core.setOutput('issue_url', issue.data.html_url);
      } catch (retryError) {
        core.setFailed(`Could not create issue: ${retryError.message}`);
      }
    } else {
      core.setFailed(`Could not create issue: ${error.message}`);
    }
  }
}

/**
 * Main function
 */
async function run() {
  try {
    // Get inputs
    const zone = core.getInput('zone', { required: true });
    const workflowRunId = core.getInput('workflow_run_id') || github.context.runId.toString();
    const reportIssue = core.getInput('report_issue') === 'true';

    core.info(`Zone: ${zone}`);
    core.info(`Workflow Run ID: ${workflowRunId}`);
    core.info(`Report Issue: ${reportIssue}`);

    if (!reportIssue) {
      core.info('Issue reporting is disabled (report_issue: false). Skipping...');
      return;
    }

    // Find and parse CODEOWNERS file
    const codeownersPath = findCodeownersFile();
    const assignees = codeownersPath ? extractAssignees(codeownersPath) : [];

    if (assignees.length === 0) {
      core.info('No assignees found - issue will be created without assignees');
    }

    // Create GitHub issue
    const token = core.getInput('token') || process.env.GITHUB_TOKEN;
    if (!token) {
      core.setFailed('GitHub token not found. Please provide a token via input or GITHUB_TOKEN environment variable.');
      return;
    }

    const octokit = github.getOctokit(token);
    await createIssue(octokit, github.context, zone, workflowRunId, assignees);

  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();
