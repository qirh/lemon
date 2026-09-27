/**
 * Formatter for the grep tool.
 *
 * Provides human-readable formatting of grep tool arguments and results,
 * including match highlighting and file grouping.
 */

import { extractText, formatPath, highlightPattern, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum number of files to show in details view */
const MAX_FILES = 10;

/** Maximum number of matches per file in details view */
const MAX_MATCHES_PER_FILE = 3;

/** Maximum length for content lines */
const MAX_LINE_LENGTH = 120;

/**
 * Represents a single grep match.
 */
interface GrepMatch {
	line: number;
	content: string;
}

/**
 * Lines the grep tool writes around its match rows: the "Found N matches."
 * header, the no-match message, and bracketed limit/truncation notices.
 */
const GREP_TEXT_CHROME = /^(Found \d+ match(es)?\.|No matches found\.|\[.*\])$/;

/**
 * Parses grep tool output into a map grouped by file.
 *
 * Match rows look like "path:line: content". Context rows ("path-line- content"),
 * the "Found N matches." header, and bracketed notices are skipped.
 *
 * @param text - Raw grep output text
 * @returns Map from file path to array of matches
 */
export function parseGrepOutput(text: string): Map<string, GrepMatch[]> {
	const result = new Map<string, GrepMatch[]>();

	if (!text || text.trim() === "") {
		return result;
	}

	for (const line of text.split(/\r?\n/)) {
		if (!line.trim() || GREP_TEXT_CHROME.test(line.trim())) {
			continue;
		}

		const match = line.match(/^(.+?):(\d+):(.*)$/);
		if (!match) {
			continue;
		}

		const [, filePath, lineNumStr, content] = match;
		let fileMatches = result.get(filePath);
		if (!fileMatches) {
			fileMatches = [];
			result.set(filePath, fileMatches);
		}
		fileMatches.push({
			line: parseInt(lineNumStr, 10),
			// The tool separates the line number from the content with one space.
			content: content.startsWith(" ") ? content.slice(1) : content,
		});
	}

	return result;
}

/**
 * Formats a line number with padding for alignment.
 *
 * @param lineNum - The line number to format
 * @param maxWidth - Maximum width for padding (default: 4)
 * @returns Formatted line number string
 */
function formatLineNumber(lineNum: number, maxWidth = 4): string {
	return String(lineNum).padStart(maxWidth, " ");
}

/**
 * Formatter for the grep tool.
 *
 * Formats grep arguments showing the search pattern and scope,
 * and formats results with file grouping and match highlighting.
 */
export const grepFormatter: ToolFormatter = {
	tools: ["grep"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const pattern = args.pattern as string | undefined;
		const path = args.path as string | undefined;
		const glob = args.glob as string | undefined;
		const caseSensitive = args.case_sensitive as boolean | undefined;
		const contextLines = args.context_lines as number | undefined;

		// Build summary
		const parts: string[] = [];

		if (pattern) {
			parts.push(`"${pattern}"`);
		}

		if (path) {
			parts.push(`in ${formatPath(path)}`);
		}

		if (glob) {
			parts.push(`(${glob})`);
		}

		const summary = parts.length > 0 ? parts.join(" ") : "(no pattern)";

		// Build details
		const details: string[] = [];

		if (pattern) {
			details.push(`Pattern: "${pattern}"`);
		}

		if (path) {
			details.push(`Path: ${formatPath(path)}`);
		}

		if (glob) {
			details.push(`Glob: ${glob}`);
		}

		if (caseSensitive !== undefined) {
			details.push(`Case sensitive: ${caseSensitive}`);
		}

		if (contextLines !== undefined) {
			details.push(`Context lines: ${contextLines}`);
		}

		return { summary, details };
	},

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const text = extractText(result);
		const pattern = (args?.pattern as string) || "";

		const obj: Record<string, unknown> =
			result && typeof result === "object" ? (result as Record<string, unknown>) : {};

		if (obj.is_error === true) {
			const errorText = text || "Unknown error";
			return {
				summary: truncateText(errorText, 100),
				details: errorText.split(/\r?\n/),
				isError: true,
			};
		}

		const matches = parseGrepOutput(text);

		// The tool's own count covers matches the (possibly truncated) text omits.
		const resultDetails: Record<string, unknown> =
			obj.details && typeof obj.details === "object"
				? (obj.details as Record<string, unknown>)
				: {};
		let totalMatches = 0;
		if (typeof resultDetails.match_count === "number") {
			totalMatches = resultDetails.match_count;
		} else {
			for (const fileMatches of matches.values()) {
				totalMatches += fileMatches.length;
			}
		}

		if (totalMatches === 0) {
			return {
				summary: "No matches",
				details: ["No matches found"],
			};
		}

		const fileCount = matches.size;

		// Build summary
		const matchWord = totalMatches === 1 ? "match" : "matches";
		const fileWord = fileCount === 1 ? "file" : "files";
		const summary =
			fileCount > 0
				? `${totalMatches} ${matchWord} in ${fileCount} ${fileWord}`
				: `${totalMatches} ${matchWord}`;

		// Build details
		const details: string[] = [];
		const files = Array.from(matches.entries());
		const displayFiles = files.slice(0, MAX_FILES);

		// Default highlight function (uppercase for visibility in plain text)
		const highlightFn = (s: string) => `[${s}]`;

		for (const [filePath, fileMatches] of displayFiles) {
			const formattedPath = formatPath(filePath);
			const matchCount = fileMatches.length;
			const matchLabel = matchCount === 1 ? "match" : "matches";

			// Add file header
			details.push(`${formattedPath} (${matchCount} ${matchLabel})`);

			// Add match lines (limited)
			const displayMatches = fileMatches.slice(0, MAX_MATCHES_PER_FILE);
			for (const match of displayMatches) {
				const lineNumStr = formatLineNumber(match.line);
				let content = match.content;

				// Truncate long lines
				if (content.length > MAX_LINE_LENGTH) {
					content = `${content.slice(0, MAX_LINE_LENGTH - 3)}...`;
				}

				// Highlight pattern in content
				if (pattern) {
					content = highlightPattern(content, pattern, highlightFn);
				}

				details.push(`  ${lineNumStr}| ${content}`);
			}

			// Show truncation indicator for matches
			if (fileMatches.length > MAX_MATCHES_PER_FILE) {
				const remaining = fileMatches.length - MAX_MATCHES_PER_FILE;
				details.push(`  ... (${remaining} more)`);
			}
		}

		// Show truncation indicator for files
		if (files.length > MAX_FILES) {
			const remainingFiles = files.length - MAX_FILES;
			details.push(`... (${remainingFiles} more files)`);
		}

		return { summary, details };
	},
};
