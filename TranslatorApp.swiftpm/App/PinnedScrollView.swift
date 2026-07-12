import SwiftUI

/// A ScrollView that stays pinned to the bottom while content streams in,
/// pauses when the user scrolls up to read, and resumes in two friendly
/// ways: automatically when the user scrolls back near the bottom, or via
/// a floating "jump to latest" pill that lights up when new content has
/// arrived while they were reading.
///
/// Drive it with three values:
///  - `bottomID`: the id of the last row (nil when empty),
///  - `contentRevision`: a monotonic counter bumped whenever content at the
///    bottom changes (streaming deltas, new rows, finalization),
///  - `itemCount`: the row count, used to pick an animated scroll for new
///    rows vs an instant snap for in-place growth — per-delta animations
///    retarget each other and look rubbery, while instant snaps read as the
///    text smoothly pushing the view down.
struct PinnedScrollView<ID: Hashable, Content: View>: View {
    let bottomID: ID?
    let contentRevision: Int
    let itemCount: Int
    @ViewBuilder let content: () -> Content

    /// Within this distance of the bottom the view (re)pins itself.
    private static var repinThreshold: CGFloat { 50 }
    /// Beyond this distance a user scroll unpins. The 50–80 pt gap is
    /// hysteresis so the pin state can't flap at a single boundary.
    private static var unpinThreshold: CGFloat { 80 }

    @State private var pinned = true
    @State private var hasUnseenContent = false
    @State private var lastItemCount = 0
    /// Latest scroll geometry, boxed in a reference so per-frame updates
    /// don't invalidate the view; only pin-state flips should re-render.
    @State private var latestMetrics = MetricsBox()
    /// Settle deadline for ANIMATED programmatic scrolls, so their own
    /// offset frames can't be mistaken for a user drag. Instant snaps
    /// don't set it — during heavy streaming a constantly-renewed window
    /// would lock the user out of unpinning entirely.
    @State private var programmaticScrollUntil = Date.distantPast

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                // Whole points: sub-pixel churn during streaming must not
                // spam the action closure.
                ScrollMetrics(
                    contentHeight: geometry.contentSize.height.rounded(),
                    offsetY: geometry.contentOffset.y.rounded(),
                    viewportHeight: geometry.containerSize.height.rounded(),
                    bottomInset: geometry.contentInsets.bottom.rounded()
                )
            } action: { old, new in
                handleMetrics(old: old, new: new, proxy: proxy)
            }
            .onChange(of: contentRevision) {
                let newRow = itemCount != lastItemCount
                lastItemCount = itemCount
                guard bottomID != nil else {
                    // Cleared: reset so the next conversation starts pinned.
                    pinned = true
                    hasUnseenContent = false
                    return
                }
                if pinned {
                    scrollToBottom(proxy, animated: newRow)
                } else {
                    hasUnseenContent = true
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if !pinned, bottomID != nil {
                        jumpToLatestPill(proxy)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.25), value: pinned)
                .animation(.spring(duration: 0.25), value: hasUnseenContent)
            }
        }
    }

    // MARK: - Pin state

    private func handleMetrics(old: ScrollMetrics, new: ScrollMetrics, proxy: ScrollViewProxy) {
        latestMetrics.value = new
        if new.viewportHeight != old.viewportHeight {
            // Keyboard or rotation resized the viewport — never a reason
            // to unpin; if pinned, keep the last row visible above it.
            if pinned { scrollToBottom(proxy, animated: false) }
            return
        }
        if new.distanceFromBottom <= Self.repinThreshold {
            pinned = true
            hasUnseenContent = false
            return
        }
        // Unpin only on a genuine user scroll UP: the offset alone changed
        // (content growth moves contentHeight in the same frame) and it
        // moved away from the bottom (programmatic scrolls only ever move
        // toward it), outside any animated scroll's settle window.
        if pinned,
           new.distanceFromBottom > Self.unpinThreshold,
           new.contentHeight == old.contentHeight,
           new.offsetY < old.offsetY,
           Date() > programmaticScrollUntil {
            pinned = false
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let bottomID else { return }
        if animated {
            programmaticScrollUntil = Date().addingTimeInterval(0.6)
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    // MARK: - Jump-to-latest pill

    private func jumpToLatestPill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            pinned = true
            hasUnseenContent = false
            scrollToBottom(proxy, animated: true)
            // A long animated jump through a LazyVStack's estimated row
            // heights can land short; one instant correction after the
            // animation settles is enough in practice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                if pinned, latestMetrics.value.distanceFromBottom > Self.repinThreshold {
                    scrollToBottom(proxy, animated: false)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                if hasUnseenContent {
                    Text("New")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(hasUnseenContent ? Color.indigo : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.thinMaterial))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .accessibilityLabel(hasUnseenContent ? "New messages, scroll to latest" : "Scroll to latest")
    }
}

private struct ScrollMetrics: Equatable {
    var contentHeight: CGFloat = 0
    var offsetY: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// Points of content still below the visible bottom edge: ~0 when
    /// scrolled fully down, negative during rubber-band overscroll.
    var distanceFromBottom: CGFloat {
        contentHeight + bottomInset - (offsetY + viewportHeight)
    }
}

private final class MetricsBox {
    var value = ScrollMetrics()
}
