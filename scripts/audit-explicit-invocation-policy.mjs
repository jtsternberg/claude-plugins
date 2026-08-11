#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_REPO = path.resolve(SCRIPT_DIR, '..');

export const RISK_BY_SKILL = new Map([
	['beads-workflow:fix-findings-beads-tasks', ['local-side-effect', 'Creates Beads tasks, edits files, and commits fixes.']],
	['beads-workflow:tackle-epic', ['local-side-effect', 'Claims and closes Beads work, edits files, commits, and prepares PRs.']],
	['bible:bible-nlt-lookup', ['read-only-or-advisory', 'Reads scripture references from the NLT API.']],
	['export-presentation:export-presentation', ['local-side-effect', 'Runs browser export flows and writes PDF/PNG artifacts.']],
	['generating-blog-images:blog-image-prompts', ['read-only-or-advisory', 'Generates prompt text and placement advice.']],
	['git-commits:commit-staged', ['local-side-effect', 'Creates local Git commits from staged changes.']],
	['git-commits:commit-unstaged', ['local-side-effect', 'Stages files and creates local Git commits.']],
	['git-tree:create-git-tree', ['local-side-effect', 'Creates worktrees and symlinks in the local filesystem.']],
	['gws:google-doc-to-md', ['local-side-effect', 'Reads Google Docs and writes local markdown.']],
	['gws:md-to-google-doc', ['external-side-effect', 'Creates or updates Google Drive documents.']],
	['headline-refiner:headline-refiner', ['read-only-or-advisory', 'Transforms provided headline text only.']],
	['hotline:hotline-add-contact', ['local-side-effect', 'Updates local hotline directory/contact state.']],
	['hotline:hotline-pickup', ['local-side-effect', 'Caches local workspace caller identity.']],
	['hotline:hotline-ringing', ['coordination-side-effect', 'Accepts incoming agent coordination work and emits protocol status.']],
	['hotline:hotline-whoami', ['read-only-or-advisory', 'Reports local caller identity without changing state.']],
	['mac-caffeinate:caffeinate-computer', ['local-side-effect', 'Starts a local macOS caffeinate process.']],
	['paperclip:paperclip', ['local-side-effect', 'Controls a locally running Paperclip service.']],
	['pr-workflow:address-pr-comments-human', ['local-side-effect', 'Drafts PR feedback fixes locally for human approval.']],
	['pr-workflow:address-pr-comments', ['external-side-effect', 'May push commits and reply to GitHub PR comments.']],
	['pr-workflow:qa-walkthrough-pr', ['local-side-effect', 'Creates and updates local Beads QA issues.']],
	['pr-workflow:update-pr-description', ['external-side-effect', 'Edits GitHub pull request metadata.']],
	['pr-workflow:watch-pr-then-action', ['external-side-effect', 'Polls GitHub and then performs an arbitrary follow-up action.']],
	['session-tools:note-to-self', ['local-side-effect', 'Records a durable conversation breadcrumb.']],
	['session-tools:sessions-catch-up', ['read-only-or-advisory', 'Reads another transcript and reports a briefing.']],
	['session-tools:sessions-fork', ['read-only-or-advisory', 'Reads another transcript and imports context into the current session.']],
	['session-tools:sessions-weekly-recap', ['local-side-effect', 'Writes recap notes from transcript history.']],
	['skill-tools:create-skill', ['local-side-effect', 'Scaffolds and edits skill files.']],
	['skill-tools:create-slash-command', ['local-side-effect', 'Scaffolds and edits command files.']],
	['skill-tools:create-subagent', ['local-side-effect', 'Scaffolds and edits subagent files.']],
	['skill-tools:review-skill', ['read-only-or-advisory', 'Reviews skill files and reports findings.']],
	['skill-tools:review-slash-command', ['read-only-or-advisory', 'Reviews command files and reports findings.']],
	['skill-tools:validate-dual-harness-skill', ['read-only-or-advisory', 'Audits a skill contract and reports findings.']],
	['slides-presentation:create-slides-presentation', ['local-side-effect', 'Creates a local HTML slide deck artifact.']],
]);

function filesBelow(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const file = path.join(dir, entry.name);
		return entry.isDirectory() ? filesBelow(file) : [file];
	});
}

function parseFrontmatter(text) {
	const frontmatter = text.match(/^---\s*\n([\s\S]*?)\n---(?:\s*\n|$)/)?.[1];
	const result = {};
	if (!frontmatter) return result;

	for (const line of frontmatter.split(/\n/)) {
		const match = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
		if (!match) continue;
		result[match[1]] = match[2].replace(/^['"]|['"]$/g, '');
	}
	return result;
}

function frontmatterBoolean(text, key) {
	const value = parseFrontmatter(text)[key];
	if (value === 'true') return true;
	if (value === 'false') return false;
	return undefined;
}

function openaiPolicyBoolean(text) {
	const policy = text.match(/^policy:\s*\n((?:[ \t]+.*\n?)*)/m)?.[1];
	const match = policy?.match(/^\s+allow_implicit_invocation:\s*(true|false)\s*$/m);
	if (!match) return undefined;
	return match[1] === 'true';
}

export function collectExplicitInvocationPolicy(repo = DEFAULT_REPO) {
	const pluginsRoot = path.join(repo, 'plugins');
	const skills = filesBelow(pluginsRoot)
		.filter((file) => file.endsWith('/SKILL.md'))
		.sort()
		.map((skillFile) => {
			const text = fs.readFileSync(skillFile, 'utf8');
			const frontmatter = parseFrontmatter(text);
			const plugin = path.relative(pluginsRoot, skillFile).split(path.sep)[0];
			const metadataFile = path.join(path.dirname(skillFile), 'agents/openai.yaml');
			const metadata = fs.existsSync(metadataFile) ? fs.readFileSync(metadataFile, 'utf8') : '';
			const key = `${plugin}:${frontmatter.name}`;
			const risk = RISK_BY_SKILL.get(key);
			return {
				key,
				plugin,
				name: frontmatter.name,
				description: frontmatter.description,
				skillFile: path.relative(repo, skillFile),
				metadataFile: fs.existsSync(metadataFile) ? path.relative(repo, metadataFile) : null,
				claudeExplicitOnly: frontmatterBoolean(text, 'disable-model-invocation') === true,
				codexAllowImplicit: metadata ? openaiPolicyBoolean(metadata) : undefined,
				riskClass: risk?.[0],
				riskNote: risk?.[1],
			};
		});

	return {
		skills,
		explicitOnly: skills.filter((skill) => skill.claudeExplicitOnly),
		codexExplicitOnly: skills.filter((skill) => skill.codexAllowImplicit === false),
	};
}

export function policyErrors(report) {
	const errors = [];
	for (const skill of report.explicitOnly) {
		if (skill.codexAllowImplicit !== false) {
			errors.push(`${skill.key}: Claude explicit-only skill lacks policy.allow_implicit_invocation: false`);
		}
		if (!skill.riskClass) {
			errors.push(`${skill.key}: explicit-only skill lacks side-effect risk classification`);
		}
	}
	for (const skill of report.codexExplicitOnly) {
		if (!skill.claudeExplicitOnly) {
			errors.push(`${skill.key}: Codex explicit-only policy is not mirrored by disable-model-invocation: true`);
		}
	}
	for (const key of RISK_BY_SKILL.keys()) {
		if (!report.explicitOnly.some((skill) => skill.key === key)) {
			errors.push(`${key}: risk classification no longer maps to an explicit-only skill`);
		}
	}
	return errors;
}

function formatMarkdown(report) {
	const counts = new Map();
	for (const skill of report.explicitOnly) {
		counts.set(skill.riskClass, (counts.get(skill.riskClass) || 0) + 1);
	}
	const countLines = [...counts.entries()]
		.sort(([a], [b]) => a.localeCompare(b))
		.map(([risk, count]) => `- ${risk}: ${count}`)
		.join('\n');

	const rows = report.explicitOnly.map((skill) => (
		`| ${skill.key} | ${skill.riskClass} | ${skill.codexAllowImplicit === false ? 'false' : 'missing'} | ${skill.riskNote} |`
	)).join('\n');

	return [
		`Explicit-only skills: ${report.explicitOnly.length}`,
		`Codex explicit-only policies: ${report.codexExplicitOnly.length}`,
		'',
		countLines,
		'',
		'| Skill | Side-effect risk | Codex allow_implicit_invocation | Rationale |',
		'| --- | --- | --- | --- |',
		rows,
	].join('\n');
}

function main() {
	const format = process.argv.includes('--json') ? 'json' : 'markdown';
	const report = collectExplicitInvocationPolicy();
	const errors = policyErrors(report);

	if (format === 'json') {
		console.log(JSON.stringify({ ...report, errors }, null, 2));
	} else {
		console.log(formatMarkdown(report));
	}

	if (errors.length) {
		console.error('\nPolicy errors:');
		for (const error of errors) console.error(`- ${error}`);
		process.exit(1);
	}
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
