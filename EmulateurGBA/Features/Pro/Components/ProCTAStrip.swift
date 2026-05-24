//
//  ProCTAStrip.swift
//  EmulateurGBA
//
//  Complete purchase CTA surface: Lifetime primary button + Monthly
//  secondary + Not Now + (optional) Restore. Renders all 5 purchase
//  states from ProManager.purchaseState.
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

    // MARK: - Idle (default buy state)

    private var idleButtons: some View {
        VStack(spacing: 10) {
            // Primary: lifetime with gold gradient pill.
            if let product = proManager.lifetimeProduct {
                Button {
                    Task { await proManager.purchaseLifetime() }
                } label: {
                    Text(String(format: NSLocalizedString("pro.forever", comment: ""),
                                product.displayPrice))
                        .font(.headline)
                        .foregroundStyle(ProPalette.ctaTextDark)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 12 : 16)
                        .background(ProPalette.ctaGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: ProPalette.gold.opacity(0.3), radius: 12)
                }
                .buttonStyle(.plain)
            }

            // Secondary: monthly as a text link.
            if let monthly = proManager.monthlyProduct {
                Button {
                    Task { await proManager.purchaseMonthly() }
                } label: {
                    Text(String(format: NSLocalizedString("pro.monthly", comment: ""),
                                monthly.displayPrice))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Products-failed-to-load path (distinct from Restore — this is a
            // retry for the StoreKit fetch, not a purchase recovery flow).
            if proManager.lifetimeProduct == nil && proManager.monthlyProduct == nil {
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
                    .padding(.vertical, compact ? 8 : 14)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .padding(.horizontal, compact ? 20 : 28)
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
            Button {
                Task { await proManager.purchaseLifetime() }
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
