//
//  ProCTAStrip.swift
//  EmulateurGBA
//
//  Complete purchase CTA surface: Lifetime primary + the two subscriptions on
//  ONE subdued line + Not Now + (optional) Restore. Renders all 5 purchase
//  states from ProManager.purchaseState.
//
//  LIFETIME IS THE STAR. It is the plan 42 of 54 buyers chose, and it is the
//  one the brand's whole position rests on: pay once, never again.
//
//  ⚠ THE TWO BUYABLE PLANS SIT SIDE BY SIDE, AND THAT IS A HEIGHT DECISION AS
//  MUCH AS A HIERARCHY ONE. Stacking them as two full-width buttons adds a
//  whole row, which pushed the landscape right column past the screen and
//  portrait into scrolling on SE-class heights. Sharing one row, the second
//  button costs nothing: this block is the height it was when there was one
//  plan and a link. Anyone tempted to stack them should measure first.
//
//  Each button reads PRICE then plan, on ONE line, with the price set larger:
//  the price is what the button is being judged on and the plan is what it
//  buys, so "9,99 €, à vie" puts the decision first. Sizes are .headline
//  against .caption rather than something wider, because the pair has to
//  survive the narrowest column below at a readable scale. The narrowest place this renders is the landscape comparison
//  sheet's third column, 28% of the screen; stacking the buttons there gives
//  each one the full column width instead of half of it, which is what makes
//  a single line viable at all.
//
//  ORIENTATION SPLIT: side by side in portrait, stacked in landscape. That
//  looks backwards and is not. Portrait's single column also carries the hero,
//  the headline, the benefit strip and the footer, so height is what is scarce
//  there. Landscape puts the benefit list in its OWN column, leaving the right
//  one with room to spare, and stacked buttons are both wider and easier to
//  read. Device-checked 2026-08-27.
//
//  No price appears in this file. Every one comes from `Product.displayPrice`,
//  already formatted for the viewer's storefront.
//
//  `compact: true` is the landscape variant: tighter paddings, drops
//  the Restore link (users can restore from Settings).
//
//  Dismiss is a closure (not @Environment(\.dismiss)) so the strip can
//  be embedded outside a sheet context (e.g. onboarding teaser) without
//  silently no-op'ing.
//

import SwiftUI

struct ProCTAStrip: View {
    @ObservedObject private var proManager: ProManager
    let compact: Bool
    let onDismiss: () -> Void

    // @MainActor so the `.shared` default argument (ProManager is @MainActor) is
    // evaluated in a main-actor context. All call sites are SwiftUI bodies, which
    // are already on the main actor. Without this it warns under Swift 6.
    @MainActor
    init(proManager: ProManager = .shared,
         compact: Bool = false,
         onDismiss: @escaping () -> Void) {
        self._proManager = ObservedObject(wrappedValue: proManager)
        self.compact = compact
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            switch proManager.purchaseState {
            case .idle:       idleButtons
            case .processing: processingView
            case .pending:    pendingView
            case .failed(let message): failedView(message: message)
            case .success:    successView
            }
        }
    }

    // MARK: - Pieces

    /// The two buyable plans, authored once so the portrait row and the
    /// landscape column cannot drift apart.
    @ViewBuilder
    private var planButtons: some View {
        if let lifetime = proManager.lifetimeProduct {
            planButton(name: NSLocalizedString("pro.lifetime", comment: ""),
                       price: lifetime.displayPrice,
                       isPrimary: true) {
                Task { await proManager.purchaseLifetime() }
            }
        }
        if let yearly = proManager.yearlyProduct {
            planButton(name: NSLocalizedString("pro.yearly", comment: ""),
                       price: yearly.displayPrice,
                       isPrimary: false) {
                Task { await proManager.purchaseYearly() }
            }
        }
    }

    /// One plan: its price then its name, on one line, in a pill.
    ///
    /// `isPrimary` is the whole visual difference. Filled gold gradient for the
    /// plan we stand behind, a gold outline for the other. Both are real
    /// buttons of the same size, so the highlight is a preference and not a
    /// hiding place.
    private func planButton(name: String,
                            price: String,
                            isPrimary: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // The separator is inside `name`, not written here: it is
            // punctuation, and ja / zh-Hant take the ideographic comma rather
            // than a Latin one.
            (Text(price).font(.headline)
             + Text(name).font(.caption))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(isPrimary ? ProPalette.ctaTextDark : ProPalette.gold)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 40 : 44)
            .background {
                if isPrimary {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(ProPalette.ctaGradient)
                        .shadow(color: ProPalette.gold.opacity(0.3), radius: 12)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(ProPalette.gold.opacity(0.55), lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Idle (default buy state)

    private var idleButtons: some View {
        VStack(spacing: 8) {
            if compact {
                VStack(spacing: 8) { planButtons }
            } else {
                HStack(spacing: 10) { planButtons }
            }

            // Monthly is the fallback for someone who goes looking for it, and
            // it stays a link on purpose: a third button would put three equal
            // choices in front of someone who wanted one.
            if let monthly = proManager.monthlyProduct {
                Button {
                    Task { await proManager.purchaseMonthly() }
                } label: {
                    Text(String(format: NSLocalizedString("pro.monthly", comment: ""),
                                monthly.displayPrice))
                        .font(.subheadline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Products-failed-to-load path (distinct from Restore — this is a
            // retry for the StoreKit fetch, not a purchase recovery flow).
            // Checks ALL THREE: with only two named, a storefront that returned
            // just the yearly plan would show the buy button and the "cannot
            // reach the Store" message at the same time.
            if proManager.lifetimeProduct == nil
                && proManager.monthlyProduct == nil
                && proManager.yearlyProduct == nil {
                Text(NSLocalizedString("pro.unavailable", comment: ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(NSLocalizedString("pro.retry", comment: "")) {
                    Task { await proManager.restore() }
                }
                .font(.subheadline)
            }

            // "Not now" — always visible. This is a brand position: Retro Pal
            // never traps users on the paywall.
            //
            // Closure-label form + buttonStyle(.plain) + contentShape is the
            // canonical SwiftUI pattern for a full-pill hit target. The
            // shortcut `Button("text", action:)` form with trailing
            // .padding/.background leaves only the text as the tap target.
            Button(action: onDismiss) {
                Text(NSLocalizedString("pro.notNow", comment: ""))
                    .font(.subheadline.bold())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 0 : 12)
                    .frame(height: compact ? 40 : nil)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Restore: portrait only. Landscape drops it — users who already
            // paid on another device can restore from Settings.
            if !compact {
                Button(NSLocalizedString("pro.restore", comment: "")) {
                    Task { await proManager.restore() }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, compact ? 16 : 28)
    }

    // MARK: - Processing / Pending / Failed / Success

    private var processingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.purple)
            Text(NSLocalizedString("pro.purchasing", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(NSLocalizedString("pro.notNow", comment: ""), action: onDismiss)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, compact ? 8 : 12)
    }

    private var pendingView: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.title2)
                .foregroundStyle(ProPalette.accentGradient)
            Text(NSLocalizedString("pro.waiting", comment: "")).font(.subheadline)
            Text(NSLocalizedString("pro.waitingDetail", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, compact ? 20 : 28)
        }
        .padding(.vertical, compact ? 8 : 12)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Gold pill — full-area hit target (closure label + buttonStyle).
            // Retries the plan that FAILED, not the lifetime one: two plans are
            // buyable from this strip now, and a retry that silently changes
            // which one is being bought is a retry that misnames itself.
            Button {
                Task { await proManager.retryLastPurchase() }
            } label: {
                Text(NSLocalizedString("pro.tryAgain", comment: ""))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 16 : 24)
                    .padding(.vertical, compact ? 8 : 12)
                    .background(ProPalette.ctaGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(NSLocalizedString("pro.notNow", comment: ""), action: onDismiss)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 20 : 28)
    }

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: compact ? 40 : 50))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.4), radius: 12)
            Text(NSLocalizedString("pro.welcome", comment: ""))
                .font(compact ? .headline : .title3.bold())
        }
    }
}
