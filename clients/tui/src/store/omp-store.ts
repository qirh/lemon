/**
 * omp delegate sessions as this operator client knows them.
 *
 * Fed by `omp.sessions.list` (on connect, reconnect, panel open and refresh)
 * and by live `omp.session` events, upserted by Lemon invocation id. The
 * daemon is authoritative: a list reply replaces what it covers, and a late
 * event never rewinds a newer snapshot. Ended sessions stay visible after they
 * exit (they are resumable history), but the store is bounded so a long-lived
 * client does not accumulate every invocation it ever saw.
 */

import {
	isOmpSessionBusy,
	isOmpSessionEnded,
	type OmpSession,
	type OmpStatus,
} from "../protocol/omp.ts";
import { Emitter } from "./events.ts";

/** At most this many sessions are kept; ended ones are evicted first, oldest first. */
export const OMP_STORE_LIMIT = 50;

interface OmpStoreEvents {
	changed: { revision: number };
}

export class OmpStore {
	readonly events = new Emitter<OmpStoreEvents>();
	readonly #sessions = new Map<string, OmpSession>();
	#status: OmpStatus | undefined;
	#revision = 0;
	#ordered: { revision: number; sessions: readonly OmpSession[] } | undefined;

	/** Bumps on every change; renderers cache against it. */
	get revision(): number {
		return this.#revision;
	}

	/** The last `omp.status` reply, if one was read. */
	get status(): OmpStatus | undefined {
		return this.#status;
	}

	get size(): number {
		return this.#sessions.size;
	}

	get(id: string): OmpSession | undefined {
		return this.#sessions.get(id);
	}

	/** Live sessions first, then ended ones; newest activity first within each. */
	sessions(): readonly OmpSession[] {
		if (this.#ordered?.revision === this.#revision) return this.#ordered.sessions;
		const sessions = [...this.#sessions.values()].sort(
			(a, b) =>
				Number(isOmpSessionEnded(a)) - Number(isOmpSessionEnded(b)) || recency(b) - recency(a),
		);
		this.#ordered = { revision: this.#revision, sessions };
		return sessions;
	}

	/** Sessions whose process is starting or working now. */
	busyCount(): number {
		let busy = 0;
		for (const session of this.#sessions.values()) if (isOmpSessionBusy(session)) busy += 1;
		return busy;
	}

	setStatus(status: OmpStatus): void {
		this.#status = status;
		this.#changed();
	}

	/**
	 * Upsert one snapshot. Returns false when it was older than what the store
	 * already holds (an event that raced a newer list reply or mutation receipt).
	 */
	upsert(session: OmpSession): boolean {
		if (!this.#accept(session)) return false;
		this.#prune();
		this.#changed();
		return true;
	}

	/**
	 * Apply an `omp.sessions.list` reply. A complete reply (fewer rows than were
	 * asked for) is authoritative about which live sessions exist: a live row it
	 * omits no longer has a process the daemon knows about and is dropped.
	 * Ended rows are kept either way.
	 */
	applyList(sessions: readonly OmpSession[], complete: boolean): void {
		const listed = new Set<string>();
		for (const session of sessions) {
			listed.add(session.id);
			this.#accept(session);
		}
		if (complete) {
			for (const [id, session] of this.#sessions) {
				if (!listed.has(id) && !isOmpSessionEnded(session)) this.#sessions.delete(id);
			}
		}
		this.#prune();
		this.#changed();
	}

	#accept(session: OmpSession): boolean {
		const previous = this.#sessions.get(session.id);
		if (
			previous?.updatedAt != null &&
			session.updatedAt != null &&
			session.updatedAt < previous.updatedAt
		) {
			return false;
		}
		this.#sessions.set(session.id, session);
		return true;
	}

	#prune(): void {
		while (this.#sessions.size > OMP_STORE_LIMIT) {
			let victim: OmpSession | undefined;
			for (const session of this.#sessions.values()) {
				const better =
					!victim ||
					(isOmpSessionEnded(session) && !isOmpSessionEnded(victim)) ||
					(isOmpSessionEnded(session) === isOmpSessionEnded(victim) &&
						recency(session) < recency(victim));
				if (better) victim = session;
			}
			if (!victim) return;
			this.#sessions.delete(victim.id);
		}
	}

	#changed(): void {
		this.#revision += 1;
		this.events.emit("changed", { revision: this.#revision });
	}
}

function recency(session: OmpSession): number {
	return session.updatedAt ?? session.endedAt ?? session.startedAt ?? 0;
}
