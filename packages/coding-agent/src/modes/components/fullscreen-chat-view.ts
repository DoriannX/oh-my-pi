import {
	type Component,
	type Container,
	Ellipsis,
	matchesKey,
	type OverlayFocusOwner,
	parseSgrMouse,
	ScrollView,
	type SgrMouseEvent,
} from "@oh-my-pi/pi-tui";

/**
 * Persistent alternate-screen chat surface.
 *
 * The regular OMP root remains the source of truth for every existing
 * transcript, status, hook, and editor component. This view only gives those
 * components a viewport: history scrolls independently while the live dock
 * stays fixed at the bottom of the terminal.
 */
export class FullscreenChatView implements Component, OverlayFocusOwner {
	#scrollView = new ScrollView([], { height: 1, scrollbar: "auto", ellipsis: Ellipsis.Omit });
	#followTail = true;
	#viewportHeight = 1;
	#width = 1;
	#draggingScrollbar = false;
	/**
	 * Whether the transcript overflowed last frame, so the scrollbar column was
	 * reserved. Reused as this frame's first guess: rendering the transcript once
	 * to measure it and again at the narrower width doubled the per-frame cost of
	 * every scroll, and the guess only misses on the frame the state flips.
	 */
	#scrollbarReserved = false;
	/** Per-width memo of the flattened transcript, keyed on component array identity. */
	#transcriptCache: { width: number; parts: readonly (readonly string[])[]; flat: string[] } | undefined;
	/** Line array last handed to the scroll view, to skip its defensive copy. */
	#scrollViewLines: readonly string[] | undefined;

	constructor(
		private readonly transcriptComponents: readonly Component[],
		private readonly dockComponents: readonly Component[],
		private readonly editorContainer: Container,
		private readonly terminalRows: () => number,
		/** Read per notch so `/settings` changes apply without recreating the view. */
		private readonly wheelScrollLines: () => number = () => 3,
	) {}

	/** Lets the normal editor slot keep keyboard focus while this overlay owns the screen. */
	ownsOverlayFocusTarget(component: Component): boolean {
		return this.editorContainer.children.includes(component);
	}

	/** True when a viewport navigation key or mouse gesture changed the scroll position. */
	handleViewportInput(data: string): boolean {
		const mouse = parseSgrMouse(data);
		if (mouse) return this.#handleMouse(mouse);

		if (!this.#handleViewportKey(data)) return false;
		this.#followTail = this.#scrollView.getScrollOffset() === this.#scrollView.getMaxScrollOffset();
		return true;
	}

	invalidate(): void {
		for (const component of this.transcriptComponents) component.invalidate?.();
		for (const component of this.dockComponents) component.invalidate?.();
	}

	render(width: number): readonly string[] {
		this.#width = Math.max(1, width);
		const terminalRows = Math.max(1, this.terminalRows());
		const dockLines = this.#renderDock(this.#width, terminalRows);
		this.#viewportHeight = Math.max(1, terminalRows - dockLines.length);

		// The scrollbar consumes the last terminal column, and each component must
		// wrap its own content at that reduced width rather than have ScrollView
		// cut a rendered line short. Start from the previous frame's answer so a
		// steady-state scroll renders the transcript once; correct it on the one
		// frame where overflow appears or disappears.
		let transcriptLines = this.#transcriptLines(this.#scrollbarReserved ? Math.max(1, this.#width - 1) : this.#width);
		if (transcriptLines.length > this.#viewportHeight !== this.#scrollbarReserved) {
			this.#scrollbarReserved = transcriptLines.length > this.#viewportHeight;
			transcriptLines = this.#transcriptLines(this.#scrollbarReserved ? Math.max(1, this.#width - 1) : this.#width);
		}

		this.#scrollView.setHeight(this.#viewportHeight);
		// setLines copies defensively; the memo hands back the same array while the
		// transcript is unchanged, so a scroll-only frame skips that copy entirely.
		if (transcriptLines !== this.#scrollViewLines) {
			this.#scrollView.setLines(transcriptLines);
			this.#scrollViewLines = transcriptLines;
		}
		if (this.#followTail) this.#scrollView.scrollToBottom();

		const transcriptViewport = this.#scrollView.render(this.#width);
		return [...transcriptViewport, ...dockLines];
	}

	/**
	 * Flattened transcript for one width. Components own their render caches and
	 * return the same array reference while unchanged (a component that mutates
	 * its array in place must implement RenderStablePrefix), so array identity is
	 * the change signal: the flat copy is rebuilt only when a block really moved.
	 */
	#transcriptLines(width: number): string[] {
		const parts = this.transcriptComponents.map(component => component.render(width));
		const cached = this.#transcriptCache;
		if (cached !== undefined && cached.width === width && cached.parts.length === parts.length) {
			let unchanged = true;
			for (let index = 0; index < parts.length; index++) {
				if (parts[index] !== cached.parts[index]) {
					unchanged = false;
					break;
				}
			}
			if (unchanged) return cached.flat;
		}
		const flat: string[] = [];
		for (const part of parts) flat.push(...part);
		this.#transcriptCache = { width, parts, flat };
		return flat;
	}

	#renderComponents(components: readonly Component[], width: number): string[] {
		const lines: string[] = [];
		for (const component of components) lines.push(...component.render(width));
		return lines;
	}

	#renderDock(width: number, terminalRows: number): string[] {
		const lines = this.#renderComponents(this.dockComponents, width);
		// Keep one transcript row usable even when a transient panel and a tall
		// editor would otherwise consume the whole terminal. The tail contains
		// the editor and footer, which must remain available to type.
		return lines.length < terminalRows ? lines : lines.slice(lines.length - terminalRows + 1);
	}

	#handleViewportKey(data: string): boolean {
		// Keep normal arrows available to the multiline editor. These fullscreen
		// navigation keys mirror upstream Pi's alternate-screen defaults.
		if (matchesKey(data, "pageUp")) {
			this.#scrollView.page(-1);
			return true;
		}
		if (matchesKey(data, "pageDown")) {
			this.#scrollView.page(1);
			return true;
		}
		if (matchesKey(data, "home")) {
			this.#scrollView.scrollToTop();
			return true;
		}
		if (matchesKey(data, "end")) {
			this.#scrollView.scrollToBottom();
			return true;
		}
		return false;
	}

	#handleMouse(event: SgrMouseEvent): boolean {
		if (event.wheel !== null) {
			const lines = this.wheelScrollLines();
			this.#scrollView.scroll(event.wheel * (Number.isFinite(lines) ? Math.max(1, Math.trunc(lines)) : 1));
			this.#followTail = this.#scrollView.getScrollOffset() === this.#scrollView.getMaxScrollOffset();
			return true;
		}

		if (event.release) {
			this.#draggingScrollbar = false;
			// Mouse tracking is enabled for the whole fullscreen surface, so even a
			// release that did not end a scrollbar drag must stay out of the editor.
			return true;
		}

		const scrollbarColumn = this.#width - 1;
		if (event.leftClick && event.col === scrollbarColumn && event.row < this.#viewportHeight) {
			this.#draggingScrollbar = true;
			this.#scrollToPointer(event.row);
			return true;
		}
		if (event.motion && this.#draggingScrollbar) {
			this.#scrollToPointer(event.row);
			return true;
		}
		// Mouse tracking is active while fullscreen owns the TTY. Consume idle
		// motion and clicks so their escape sequences never enter the editor.
		return true;
	}

	#scrollToPointer(row: number): void {
		const max = this.#scrollView.getMaxScrollOffset();
		const denominator = Math.max(1, this.#viewportHeight - 1);
		const ratio = Math.max(0, Math.min(1, row / denominator));
		this.#scrollView.setScrollOffset(Math.round(max * ratio));
		this.#followTail = this.#scrollView.getScrollOffset() === max;
	}
}
