/**
 * The transcript, as data.
 *
 * View-agnostic on purpose: this is what tests assert on and what a session
 * rebuild (P6 cold-session hydration) replays into components. Nothing here
 * imports pi-tui — a block knows what happened, not how it looks.
 */

import type { AgentAction, AgentActionKind, ImageContent, RunUsage } from "../protocol/types.ts";

export type BlockKind = "user" | "assistant" | "tool" | "reasoning" | "approval" | "notice";

interface BlockBase {
	/** Unique within a session; stable for the block's lifetime. */
	id: string;
	kind: BlockKind;
	/** Wall-clock ms when the block was created. */
	at: number;
}

/** How a prompt reached a busy run (absent: it started its own turn). */
export type UserDelivery = "steer" | "redirect" | "interrupt";

/** What is known about a prompt beyond its text. */
export interface UserDetails {
	/** When it was sent; absent for saved history without a timestamp. */
	sentAt?: number;
	/** Images sent with it (the text names them as `[image: …]`). */
	images?: readonly ImageContent[];
	delivery?: UserDelivery;
}

export interface UserBlock extends BlockBase, UserDetails {
	kind: "user";
	text: string;
}

/** A finished run's own report, attached to its final answer segment. */
export interface TurnSummary {
	durationMs?: number;
	usage?: RunUsage;
	model?: string;
}

export type AssistantStatus = "streaming" | "done" | "error" | "aborted";

export interface AssistantBlock extends BlockBase {
	kind: "assistant";
	runId: string;
	/** Full accumulated text. Never the server's truncated `completed.answer`. */
	text: string;
	status: AssistantStatus;
	/** Set when the run ended badly and the server had something to say. */
	error?: string;
	/** Present on the run's last segment once the daemon reported completion. */
	turn?: TurnSummary;
}

export type ToolPhase = "started" | "updated" | "completed";

export interface ToolBlock extends BlockBase {
	kind: "tool";
	runId: string | undefined;
	/** `action.id` from the protocol; the upsert key. */
	actionId: string;
	toolKind: AgentActionKind | string;
	title: string;
	detail: Record<string, unknown> | undefined;
	phase: ToolPhase;
	/**
	 * Client-observed terminal time, frozen when a live block completes.
	 * Absent for receipts with no observed start; `at` alone is not a duration.
	 */
	completedAt?: number;
	ok: boolean | undefined;
	message: string | undefined;
	/** A saved receipt, not a currently executing call (even if its outcome is unknown). */
	historical?: boolean;
	cancelled?: boolean;
	/** Known execution time; history must never derive this from hydration time. */
	durationMs?: number;
}

/**
 * The model's thinking for one reasoning block of a run. Its own transcript
 * block (not a tool card): `kind: "reasoning"` actions carry the accumulated
 * text, so each phase replaces {@link text} rather than appending to it.
 */
export interface ReasoningBlock extends BlockBase {
	kind: "reasoning";
	runId: string | undefined;
	/** `action.id` from the protocol; the upsert key. */
	actionId: string;
	text: string;
	phase: ToolPhase;
}

export interface ApprovalBlock extends BlockBase {
	kind: "approval";
	approvalId: string;
	tool: string | undefined;
	status: "pending" | "resolved";
	decision?: string;
}

export type NoticeLevel = "info" | "warning" | "error";

/** Token amounts a confirmed context compaction reported. */
export interface CompactionDetails {
	tokensBefore?: number;
	tokensAfter?: number;
}

export interface NoticeBlock extends BlockBase {
	kind: "notice";
	level: NoticeLevel;
	text: string;
	/** Set when the notice records a context compaction. */
	compaction?: CompactionDetails;
}

export type Block =
	| UserBlock
	| AssistantBlock
	| ToolBlock
	| ReasoningBlock
	| ApprovalBlock
	| NoticeBlock;

let blockSeq = 0;

/** Monotonic block id. Prefixed by kind so transcripts read well in dumps. */
export function nextBlockId(kind: BlockKind): string {
	blockSeq += 1;
	return `${kind}-${blockSeq}`;
}

/** Test hook: make ids deterministic across cases. */
export function resetBlockIds(): void {
	blockSeq = 0;
}

/** Normalize a protocol phase string; anything unknown counts as an update. */
export function toToolPhase(phase: string | null | undefined): ToolPhase {
	return phase === "started" || phase === "completed" ? phase : "updated";
}

/** Best-effort human title for a tool action. */
export function toolTitle(action: AgentAction | undefined): string {
	const title = action?.title?.trim();
	if (title) return title;
	const kind = action?.kind?.trim();
	if (kind) return kind;
	return "tool";
}
