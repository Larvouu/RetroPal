//
//  ProManager.swift
//  EmulateurGBA
//
//  Single source of truth for Pro status. Hybrid model:
//  $4.99 one-time (non-consumable) OR $0.99/month (auto-renewable subscription).
//

import StoreKit
import SwiftUI

private typealias SKTransaction = StoreKit.Transaction

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    static let lifetimeProductID = "com.retropal.pro"
    static let monthlyProductID = "com.retropal.pro.monthly"
    private static let allProductIDs: Set<String> = [lifetimeProductID, monthlyProductID]

    @AppStorage("isPro") var isPro: Bool = false

    /// Available products. Lifetime first, monthly second.
    @Published var lifetimeProduct: Product?
    @Published var monthlyProduct: Product?

    @Published var purchaseState: PurchaseState = .idle

    private var updateListenerTask: Task<Void, Never>?

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
                default: break
                }
            }
        } catch {
            print("[ProManager] Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    func purchaseLifetime() async {
        guard let product = lifetimeProduct else {
            purchaseState = .failed("Pro unavailable. Check your connection.")
            return
        }
        await doPurchase(product)
    }

    func purchaseMonthly() async {
        guard let product = monthlyProduct else {
            purchaseState = .failed("Monthly plan unavailable. Check your connection.")
            return
        }
        await doPurchase(product)
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
                    purchaseState = .success
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    purchaseState = .idle
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .pending
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed("Purchase failed. Try again?")
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
