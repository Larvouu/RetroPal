//
//  ProManager.swift
//  EmulateurGBA
//
//  Single source of truth for Pro status. Three ways in:
//  9.99 one-time (non-consumable), 5.99/year or 0.99/month (auto-renewable,
//  both in the one "Pro" subscription group so a subscriber can move between
//  them without a second subscription).
//
//  Prices are never written down here or in any view. Every surface reads
//  `Product.displayPrice`, which StoreKit returns already formatted and
//  converted for the viewer's storefront, so a price change is an App Store
//  Connect action and touches no code and no string file.
//

import StoreKit
import SwiftUI

private typealias SKTransaction = StoreKit.Transaction

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    static let lifetimeProductID = "com.retropal.pro"
    static let monthlyProductID = "com.retropal.pro.monthly"
    static let yearlyProductID = "com.retropal.pro.yearly"
    private static let allProductIDs: Set<String> = [lifetimeProductID, monthlyProductID, yearlyProductID]

    @AppStorage("isPro") var isPro: Bool = false

    /// The Pro-prompt trigger that opened the current sheet. Set by ProUpgradeView
    /// on appear; read on purchase success for per-trigger conversion analytics.
    var activeTrigger: ProPromptContext?

    /// Available products. Any of the three can be nil: StoreKit returns only
    /// what the storefront actually offers, and a view must render whatever it
    /// got rather than assume all three arrived.
    @Published var lifetimeProduct: Product?
    @Published var monthlyProduct: Product?
    @Published var yearlyProduct: Product?

    @Published var purchaseState: PurchaseState = .idle

    /// Which plan the player last asked for, so a retry asks for the SAME one.
    ///
    /// Kept as the intent rather than as the `Product`, because one of the two
    /// ways a purchase can fail is the product never having loaded, and a retry
    /// has to be able to reach that case and fail the same way rather than
    /// quietly buying something else.
    private var lastAttemptedPlan: Plan = .lifetime

    private var updateListenerTask: Task<Void, Never>?

    /// The three ways in. Named so a retry, and anything else that has to speak
    /// about a plan without holding its `Product`, can.
    enum Plan {
        case lifetime, yearly, monthly
    }

    enum PurchaseState {
        case idle
        case processing
        case pending
        case failed(String)
        case success
    }

    private init() {}

    // MARK: - Setup

    func setup() async {
        await loadProducts()

        #if DEBUG
        if !isPro { await verifyEntitlements() }
        #else
        await verifyEntitlements()
        #endif

        updateListenerTask = Task.detached { [weak self] in
            for await result in SKTransaction.updates {
                guard let self else { return }
                if let transaction = try? result.payloadValue {
                    await self.handleVerified(transaction)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                #if DEBUG
                if self?.isPro != true { await self?.verifyEntitlements() }
                #else
                await self?.verifyEntitlements()
                #endif
            }
        }
    }

    // MARK: - Product Loading

    private func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            for product in products {
                switch product.id {
                case Self.lifetimeProductID: lifetimeProduct = product
                case Self.monthlyProductID: monthlyProduct = product
                case Self.yearlyProductID: yearlyProduct = product
                default: break
                }
            }
        } catch {
            print("[ProManager] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    /// The two messages this file can put on screen, both from the string file.
    ///
    /// They were English literals, in an app that ships in fifteen languages and
    /// on the one screen where money changes hands: a French buyer whose payment
    /// failed was told "Purchase failed. Try again?" in English. Both sentences
    /// already existed, translated, as `pro.unavailable` and `pro.failed`, and
    /// the first was even being used by the CTA strip a few lines away. The
    /// per-plan wording that used to name the monthly and yearly plans goes with
    /// them: those two guards are unreachable from the sheet (each button is
    /// only drawn when its own product loaded), and one translated sentence
    /// beats three English ones.
    private static var unavailableMessage: String {
        NSLocalizedString("pro.unavailable", comment: "")
    }
    private static var failedMessage: String {
        NSLocalizedString("pro.failed", comment: "")
    }

    func purchaseLifetime() async {
        lastAttemptedPlan = .lifetime
        guard let product = lifetimeProduct else {
            purchaseState = .failed(Self.unavailableMessage)
            return
        }
        await doPurchase(product)
    }

    func purchaseMonthly() async {
        lastAttemptedPlan = .monthly
        guard let product = monthlyProduct else {
            purchaseState = .failed(Self.unavailableMessage)
            return
        }
        await doPurchase(product)
    }

    func purchaseYearly() async {
        lastAttemptedPlan = .yearly
        guard let product = yearlyProduct else {
            purchaseState = .failed(Self.unavailableMessage)
            return
        }
        await doPurchase(product)
    }

    /// Buys the plan the player was actually trying to buy when it failed.
    ///
    /// The failure view's button used to call `purchaseLifetime` outright. With
    /// one buyable plan and a monthly link that was nearly true; with two plans
    /// side by side it is not, and "Try again" after a failed yearly purchase
    /// would have put the lifetime product in front of someone who had chosen
    /// the subscription. Apple's own sheet names the product, so nobody would
    /// have been charged unknowingly -- but the button would have changed their
    /// mind for them, which is not what it says it does.
    func retryLastPurchase() async {
        switch lastAttemptedPlan {
        case .lifetime: await purchaseLifetime()
        case .yearly:   await purchaseYearly()
        case .monthly:  await purchaseMonthly()
        }
    }

    /// Legacy: purchases the lifetime product (for backward compat)
    func purchase() async {
        await purchaseLifetime()
    }

    private func doPurchase(_ product: Product) async {
        purchaseState = .processing
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if let transaction = try? verification.payloadValue {
                    await transaction.finish()
                    isPro = true
                    Analytics.signal("pro_purchased", [
                        "trigger": activeTrigger?.analyticsID ?? "unknown",
                        "productType": Self.analyticsType(for: product.id)
                    ])
                    purchaseState = .success
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    purchaseState = .idle
                } else {
                    // A purchase App Store Connect calls successful but whose
                    // signature does not verify. Rare, and it used to leave the
                    // sheet spinning on `.processing` for ever with no way out
                    // but to close it: the one branch here that did nothing at
                    // all. It now says the same thing a declined card says,
                    // because from the buyer's side it is the same thing: it did
                    // not go through, and trying again is the next move.
                    purchaseState = .failed(Self.failedMessage)
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .pending
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(Self.failedMessage)
        }
    }

    // MARK: - Restore

    func restore() async {
        await verifyEntitlements()
        if !isPro {
            try? await AppStore.sync()
            await verifyEntitlements()
        }
    }

    // MARK: - Verification

    func verifyEntitlements() async {
        var foundPro = false
        for await result in SKTransaction.currentEntitlements {
            if let transaction = try? result.payloadValue,
               Self.allProductIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                foundPro = true
                break
            }
        }
        isPro = foundPro
    }

    /// Which plan a purchase was, for the conversion funnel.
    ///
    /// Spelled out rather than left as a ternary: the old two-way form read
    /// "lifetime, else monthly", so adding a third plan would have silently
    /// filed every yearly purchase under monthly and corrupted the one number
    /// the price change exists to move.
    private static func analyticsType(for productID: String) -> String {
        switch productID {
        case lifetimeProductID: return "lifetime"
        case yearlyProductID:   return "yearly"
        case monthlyProductID:  return "monthly"
        default:                return "unknown"
        }
    }

    /// Convenience for non-async contexts
    var product: Product? { lifetimeProduct }

    private func handleVerified(_ transaction: SKTransaction) async {
        if Self.allProductIDs.contains(transaction.productID) {
            isPro = transaction.revocationDate == nil
            await transaction.finish()
        }
    }

    // MARK: - Debug

    #if DEBUG
    func debugTogglePro() { isPro.toggle() }
    #endif

    deinit { updateListenerTask?.cancel() }
}
