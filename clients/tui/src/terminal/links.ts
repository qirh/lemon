import { homedir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import type { ToolBlock } from "../store/transcript-model.ts";
import { toolArgs, toolDetails } from "../ui/tool-view.ts";

/** Encode paths, including spaces and #, without interpreting terminal controls. */
export function fileTarget(path: string, line?: number, cwd = process.cwd()): string | undefined {
	if (!path || /\p{Cc}/u.test(path)) return undefined;
	const location = /^(.*?)(?::(\d+)(?::\d+)?|#L(\d+))$/.exec(path);
	const file = location?.[1] ?? path;
	const at = line ?? Number(location?.[2] ?? location?.[3] ?? 0);
	const expanded = file.startsWith("~/") ? resolve(homedir(), file.slice(2)) : resolve(cwd, file);
	const url = pathToFileURL(expanded);
	if (Number.isSafeInteger(at) && at > 0) url.hash = `L${at}`;
	return url.href;
}

export function hyperlink(label: string, target: string | undefined): string {
	if (!TERMINAL.hyperlinks || !target || /\p{Cc}/u.test(target)) return label;
	return `\x1b]8;;${target}\x07${label}\x1b]8;;\x07`;
}

/** Inline code paths are common in coding replies; don't turn arbitrary code into links. */
export function codeLink(text: string, styled: string): string {
	if (!TERMINAL.hyperlinks || /\s/.test(text)) return styled;
	if (/^https?:\/\//i.test(text)) return hyperlink(styled, text);
	if (
		!/^(?:(?:\.{0,2}\/|~\/)[\w@./-]+|[\w@.-]+(?:\/[\w@.-]+)+|[\w.-]+\.[a-zA-Z\d]+)(?::\d+(?::\d+)?|#L\d+)?$/.test(
			text,
		)
	)
		return styled;
	return hyperlink(styled, fileTarget(text));
}

/** Link the card title, leaving pure formatter strings free of ANSI bytes. */
export function toolLink(label: string, block: ToolBlock): string {
	if (!TERMINAL.hyperlinks) return label;
	const args = toolArgs(block);
	const details = toolDetails(block);
	const path = args.path ?? args.file_path ?? details.path;
	if (typeof path === "string") {
		const line = details.first_changed_line ?? args.offset;
		return hyperlink(label, fileTarget(path, typeof line === "number" ? line : undefined));
	}
	if (typeof args.url === "string" && /^https?:\/\//i.test(args.url))
		return hyperlink(label, args.url);
	return label;
}
