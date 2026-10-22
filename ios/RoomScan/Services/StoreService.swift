import Foundation
import Observation
import StoreKit
import Supabase

/// StoreKit 2: loads products, handles purchases, and forwards the signed transaction
/// to the `verify-apple-transaction` edge function which updates the org subscription.
@Observable
@MainActor
final class StoreService {
    var products: [Product] = []
    var isLoading = false
    var purchaseInProgress = false
    var lastError: String?

    private var updatesTask: Task<Void, Never>?

    func start() async {
        await loadProducts()
        updatesTask?.cancel()
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: Config.Products.all)
                .sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
        }
    }

    var subscriptions: [Product] { products.filter { $0.type == .autoRenewable } }
    var consumables: [Product] { products.filter { $0.type == .consumable } }

    /// Returns true when the purchase completed and was recorded server-side.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification)
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Re-sends current entitlements to the server (e.g. after reinstall or on a new device).
    func restore() async {
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription }
        for await result in Transaction.currentEntitlements {
            await handle(result)
        }
    }

    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let tx) = result else {
            lastError = "Transaction could not be verified by StoreKit."
            return false
        }
        let ok = await verifyOnServer(jws: result.jwsRepresentation)
        if ok { await tx.finish() }
        return ok
    }

    private func verifyOnServer(jws: String) async -> Bool {
        if DemoStore.isActive {
            // Local StoreKit test purchase in demo mode: grant locally, nothing goes to a server.
            DemoStore.shared.subscribed = true
            DemoStore.shared.save()
            return true
        }
        struct Body: Encodable { let signedTransaction: String }
        struct Reply: Decodable { let ok: Bool? ; let error: String? }
        do {
            let reply: Reply = try await supabase.functions.invoke(
                "verify-apple-transaction",
                options: FunctionInvokeOptions(body: Body(signedTransaction: jws))
            )
            if reply.ok == true { return true }
            lastError = reply.error ?? "Server rejected the purchase."
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
