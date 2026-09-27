/**
 * Formatter for the edit tool.
 *
 * Displays file edit operations with diff-style output showing
 * additions, deletions, and context lines.
 */

import { extractText, formatPath, truncateLines, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum lines to show in diff output */
const MAX_DIFF_LINES = 12;

/** Maximum characters for old_text preview */
const MAX_PREVIEW_LENGTH = 60;

/**
 * Formats a unified diff text into styled lines.
 *
 * Parses diff output and prefixes each line with appropriate markers:
 * - Lines starting with "-" indicate removals
 * - Lines starting with "+" indicate additions
 * - Lines starting with "@@" are diff headers
 * - Other lines are context
 *
 * @param diffText - The unified diff text to format
 * @returns Array of formatted diff lines, truncated to MAX_DIFF_LINES
 */
export function formatDiff(diffText: string): string[] {
	if (!diffText) {
		return [];
	}

	const lines = diffText.split(/\r?\n/);
	const formattedLines: string[] = [];

	for (const line of lines) {
		// Skip empty lines at the end
		if (line === "" && formattedLines.length > 0) {
			// Keep empty lines within the diff for readability
			formattedLines.push("");
			continue;
		}

		if (line.startsWith("@@")) {
			// Diff header line
			formattedLines.push(line);
		} else if (line.startsWith("-")) {
			// Removal line
			formattedLines.push(line);
		} else if (line.startsWith("+")) {
			// Addition line
			formattedLines.push(line);
		} else if (line.startsWith(" ")) {
			// Context line (already has space prefix)
			formattedLines.push(line);
		} else if (line.length > 0) {
			// Other content - treat as context
			formattedLines.push(`  ${line}`);
		}
	}

	// Remove trailing empty lines
	while (formattedLines.length > 0 && formattedLines[formattedLines.length - 1] === "") {
		formattedLines.pop();
	}

	return truncateLines(formattedLines, MAX_DIFF_LINES);
}

/**
 * Edit tool arguments interface.
 */
interface EditArgs {
	path?: string;
	old_text?: string;
	new_text?: string;
}

/**
 * Formatter for the edit tool.
 *
 * Handles formatting of file edit operations: the target path and match
 * preview for arguments, and the applied diff for results.
 */
export const editFormatter: ToolFormatter = {
	tools: ["edit"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const editArgs = args as unknown as EditArgs;
		const formattedPath = editArgs.path ? formatPath(editArgs.path) : "unknown";
		const details: string[] = [`Path: ${formattedPath}`];

		if (editArgs.old_text) {
			const preview = truncateText(editArgs.old_text.replace(/\n/g, "\\n"), MAX_PREVIEW_LENGTH);
			details.push(`Match: "${preview}"`);
		}

		return {
			summary: formattedPath,
			details,
		};
	},

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const path = args?.path as string | undefined;
		const formattedPath = path ? formatPath(path) : "";
		const obj: Record<string, unknown> =
			result && typeof result === "object" ? (result as Record<string, unknown>) : {};
		const details: Record<string, unknown> =
			obj.details && typeof obj.details === "object"
				? (obj.details as Record<string, unknown>)
				: {};
		const isError = obj.is_error === true;

		if (isError) {
			const errorLines = extractText(result)
				.split(/\r?\n/)
				.filter((line) => line.trim().length > 0);
			return {
				summary: formattedPath ? `\u2717 Failed: ${formattedPath}` : "\u2717 Failed",
				details: truncateLines(errorLines, MAX_DIFF_LINES),
				isError: true,
			};
		}

		// Point at the first changed line when the tool reports it.
		const firstChangedLine = details.first_changed_line;
		const location =
			formattedPath && typeof firstChangedLine === "number"
				? `${formattedPath}:${firstChangedLine}`
				: formattedPath;

		// Prefer the structured diff; the text also carries a status line and
		// any diagnostics.
		const diffText = typeof details.diff === "string" ? details.diff : extractText(result);

		return {
			summary: location ? `\u2713 Applied to ${location}` : "\u2713 Applied",
			details: formatDiff(diffText),
			isError: false,
		};
	},
};
