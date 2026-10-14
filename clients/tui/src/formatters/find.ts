/**
 * Formatters for file listing tools (find, ls).
 *
 * Handles formatting of file search and directory listing arguments and results,
 * including file counts, truncation, and listings.
 */

import { extractText, formatPath, truncateLines } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum number of files to show in details */
const MAX_FILES_SHOWN = 10;

/**
 * Lines the find tool writes around its file list: the "Found N matches"
 * header and the empty-result message.
 */
const FIND_TEXT_CHROME =
	/^(Found \d+ match(es)? \(limited to \d+\):|Found \d+ match(es)?:|No files found matching the pattern\.)$/;

/**
 * Lines the ls tool writes around its entry list: the "Directory:" header and
 * the count/empty/truncation footer.
 */
const LS_TEXT_CHROME =
	/^(Directory: .*|\d+ entries|\(empty directory\)|\[Showing \d+ of \d+ entries\. Limit: \d+\])$/;

/**
 * Arguments structure for find tool.
 */
interface FindArgs {
	pattern?: string;
	path?: string;
	type?: string;
	max_depth?: number;
	max_results?: number;
	hidden?: boolean;
}

/**
 * Arguments structure for ls tool.
 */
interface LsArgs {
	path?: string;
	all?: boolean;
	long?: boolean;
	recursive?: boolean;
	max_depth?: number;
	max_entries?: number;
}

/**
 * Reads the structured details object from a tool result.
 *
 * @param result - The raw result from the tool
 * @returns The details object, or an empty object
 */
function resultDetails(result: unknown): Record<string, unknown> {
	if (result && typeof result === "object") {
		const details = (result as { details?: unknown }).details;
		if (details && typeof details === "object") {
			return details as Record<string, unknown>;
		}
	}
	return {};
}

/**
 * Parses listing lines from the result text, dropping the tool's header and
 * footer lines.
 *
 * @param result - The raw result from the tool
 * @param chrome - Pattern matching header/footer lines to drop
 * @returns Array of listed entries
 */
function parseListing(result: unknown, chrome: RegExp): string[] {
	const text = extractText(result);
	if (!text) {
		return [];
	}

	return text
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter((line) => line.length > 0 && !chrome.test(line));
}

/**
 * Builds flags string for ls command display.
 *
 * @param args - The ls arguments
 * @returns Flags string like "-la" or empty string
 */
function buildLsFlags(args: LsArgs): string {
	const flags: string[] = [];

	if (args.all) {
		flags.push("a");
	}
	if (args.long) {
		flags.push("l");
	}
	if (args.recursive) {
		flags.push("R");
	}

	return flags.length > 0 ? `-${flags.join("")}` : "";
}

/**
 * Formatter for find tool.
 *
 * Handles formatting of file search arguments and results.
 */
export const findFormatter: ToolFormatter = {
	tools: ["find"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const findArgs = args as unknown as FindArgs;
		const pattern = findArgs.pattern || "*";
		const path = findArgs.path;

		// Build summary
		const summary = path ? `${pattern} in ${formatPath(path)}` : pattern;

		// Build details
		const details: string[] = [`pattern: ${pattern}`];

		if (path) {
			details.push(`path: ${formatPath(path)}`);
		}
		if (findArgs.type) {
			details.push(`type: ${findArgs.type}`);
		}
		if (findArgs.max_depth !== undefined) {
			details.push(`max_depth: ${findArgs.max_depth}`);
		}
		if (findArgs.max_results !== undefined) {
			details.push(`max_results: ${findArgs.max_results}`);
		}
		if (findArgs.hidden) {
			details.push("hidden: true");
		}

		return {
			summary,
			details,
		};
	},

	formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
		const details = resultDetails(result);

		const files =
			Array.isArray(details.files) && details.files.every((file) => typeof file === "string")
				? (details.files as string[])
				: parseListing(result, FIND_TEXT_CHROME);
		const count = typeof details.count === "number" ? details.count : files.length;
		const truncated = details.truncated === true;

		// Build summary
		let summary: string;
		if (count === 0) {
			summary = "No matches";
		} else {
			summary = `${count} file${count === 1 ? "" : "s"} found`;
			if (truncated) {
				summary += " (limited)";
			}
		}

		return {
			summary,
			details: count > 0 ? truncateLines(files, MAX_FILES_SHOWN) : [],
		};
	},
};

/**
 * Formatter for ls tool.
 *
 * Handles formatting of directory listing arguments and results.
 */
export const lsFormatter: ToolFormatter = {
	tools: ["ls"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const lsArgs = args as unknown as LsArgs;
		const path = lsArgs.path || ".";
		const flags = buildLsFlags(lsArgs);

		// Build summary
		const formattedPath = formatPath(path);
		const summary = flags ? `${formattedPath} ${flags}` : formattedPath;

		// Build details
		const details: string[] = [`path: ${formattedPath}`];

		if (flags) {
			details.push(`flags: ${flags}`);
		}
		if (lsArgs.max_depth !== undefined) {
			details.push(`max_depth: ${lsArgs.max_depth}`);
		}
		if (lsArgs.max_entries !== undefined) {
			details.push(`max_entries: ${lsArgs.max_entries}`);
		}

		return {
			summary,
			details,
		};
	},

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const lsArgs = (args ?? {}) as unknown as LsArgs;
		const formattedPath = formatPath(lsArgs.path || ".");
		const details = resultDetails(result);

		const entries = parseListing(result, LS_TEXT_CHROME);
		const shown =
			typeof details.shown_entries === "number" ? details.shown_entries : entries.length;
		const total = typeof details.total_entries === "number" ? details.total_entries : shown;

		// Build summary
		const countLabel =
			details.truncated === true && total > shown
				? `${shown} of ${total} entries`
				: `${shown} entr${shown === 1 ? "y" : "ies"}`;

		return {
			summary: `${formattedPath} (${countLabel})`,
			details: truncateLines(entries, MAX_FILES_SHOWN),
		};
	},
};

export default [findFormatter, lsFormatter];
