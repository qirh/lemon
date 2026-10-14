export interface SessionTreeEntry {
	id: string;
	parentId: string | null;
	type: string;
	role?: string | null;
	/** Bounded preview, never a replacement for chat.history. */
	text?: string | null;
	timestamp?: string | number | null;
	isActive: boolean;
	isLeaf: boolean;
	rewindable: boolean;
}

export interface SessionTreeParams {
	sessionKey: string;
	cwd: string;
	limit?: number;
	offset?: number;
}

export interface SessionTreeResult {
	sessionKey: string;
	sessionId: string;
	leafId: string | null;
	entries: SessionTreeEntry[];
	branches: Array<{ leafId: string; active: boolean }>;
	totalEntries: number;
	offset: number;
	hasMore: boolean;
}

export interface SessionRewindTarget {
	sessionKey: string;
	cwd: string;
	entryId: string;
	restoreFiles: boolean;
	allowPartialRestore: boolean;
}

export interface SessionRewindPreview {
	sessionKey: string;
	sessionId: string;
	entryId: string;
	confirmationToken: string;
	prompt: string;
	discardedMessages: number;
	restorePaths: string[];
	unrestorableTools: string[];
	/** Older daemons omit partial-restoration metadata; absence never grants consent. */
	restoreFiles?: boolean;
	allowPartialRestore?: boolean;
	unrestorableCommands?: string[];
	unrestorableCommandCount?: number;
	canAllowPartialRestore?: boolean;
}

export interface SessionRewindResult {
	sessionKey: string;
	sessionId: string;
	entryId: string;
	prompt: string;
	leafId: string | null;
	restoredPaths: string[];
	restoreFiles: boolean;
	allowPartialRestore: boolean;
	confirmationToken: string;
	partialRestore: boolean;
	unrestorableTools: string[];
	unrestorableCommands: string[];
	unrestorableCommandCount: number;
}
